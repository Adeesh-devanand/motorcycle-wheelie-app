import Foundation

/// One output record per IMU sample: every stage's result, not just the final angle.
///
/// When a reading is wrong you need to see WHICH stage first went wrong. A single
/// displayed number tells you nothing, and re-deriving intermediate values after the
/// fact is guesswork.
public struct PipelineOutput: Codable, Sendable, Equatable {
    public var time: TimeInterval
    public var attitude: Quaternion
    /// Axis elevation above horizontal, radians, grade-corrected. THE number.
    public var pitch: Double
    /// Raw axis elevation before grade correction, radians.
    public var rawPitch: Double
    public var pitchRate: Double
    public var roll: Double
    public var gyroBias: Vector3
    /// 1-sigma on pitch, radians.
    public var pitchSigma: Double
    public var gateOpen: Bool
    public var gateReason: ValidityGate.Reason
    /// Road grade estimate, radians; nil until the gate has opened once.
    public var grade: Double?
    /// Most recent valid GNSS ground speed, m/s; nil before the first fix.
    public var speed: Double?
    /// Vibration indicator for the window in progress, m/s^2.
    public var vibration: Double
    public var flags: QualityFlags

    public init(time: TimeInterval,
                attitude: Quaternion,
                pitch: Double,
                rawPitch: Double,
                pitchRate: Double,
                roll: Double,
                gyroBias: Vector3,
                pitchSigma: Double,
                gateOpen: Bool,
                gateReason: ValidityGate.Reason,
                grade: Double?,
                speed: Double?,
                vibration: Double,
                flags: QualityFlags) {
        self.time = time
        self.attitude = attitude
        self.pitch = pitch
        self.rawPitch = rawPitch
        self.pitchRate = pitchRate
        self.roll = roll
        self.gyroBias = gyroBias
        self.pitchSigma = pitchSigma
        self.gateOpen = gateOpen
        self.gateReason = gateReason
        self.grade = grade
        self.speed = speed
        self.vibration = vibration
        self.flags = flags
    }

    public var pitchDegrees: Double { pitch * 180 / .pi }
}

/// The live pipeline: sensors in, one record per IMU sample out.
///
/// A value type over an ordered sample sequence, which is what makes replay and live
/// the same code path — and makes app/CLI parity structural rather than something to
/// hope for. Feed it the same samples with the same Config and it produces
/// byte-identical output.
///
/// Ordering inside an IMU sample:
///   1. quality monitor  (saturation, vibration)
///   2. validity gate    (may the accelerometer be trusted right now)
///   3. ESKF             (propagate, then gravity; GNSS applied retroactively)
///   4. grade baseline   (frozen while the gate is shut)
///
/// GNSS samples are buffered rather than applied on arrival, because their fixTime is
/// already in the past.
public struct Pipeline {
    private let config: Config
    /// Bike axes in device axes. Read through to the filter rather than stored:
    /// the filter DERIVES this from measured gravity when no alignment was
    /// supplied, and a stored copy here would silently keep the stale guess.
    private var alignment: MountAlignment { filter.alignment }

    private var filter: AttitudeESKF
    private var gate: ValidityGate
    private var baseline: GradeBaseline
    private var vibration: HighFrequencyIndicator
    private var delayed: DelayedStateBuffer
    private var groundAcceleration: GroundAccelerationEstimator

    private var thermalState: Int = 0
    private var lastSpeed: Double?
    private var flags: QualityFlags = []
    private var lastSpecificForce = Vector3.zero
    private var lastGateOpen = false

    /// Set by the host when an event is in progress, which suppresses GNSS pitch
    /// aiding. Owned outside the filter because the segmenter is downstream.
    public var eventActive = false
    /// Monotonic time an event most recently ended, for the aiding margin.
    public var lastEventEndTime: TimeInterval?

    public private(set) var gnssAidingApplied = 0
    public private(set) var gnssAidingSuppressed = 0

    // MARK: - Diagnostics state
    private var diag: DiagnosticEmitter
    /// Sample-time epoch and running counts for the observed-rate heartbeat.
    private var firstSampleTime: TimeInterval?
    private var samplesSeen: Int = 0
    private var missingVerdictCount: Int = 0
    private var lastSampleTime: TimeInterval?

    public init(config: Config,
                alignment: MountAlignment,
                initialBias: BiasEstimate?,
                gravityAnchor: Vector3? = nil,
                sink: DiagnosticSink? = nil) {
        self.config = config
        self.filter = AttitudeESKF(config: config,
                                   alignment: alignment,
                                   initialBias: initialBias,
                                   gravityAnchor: gravityAnchor,
                                   sink: sink)
        self.gate = ValidityGate(config: config, sink: sink)
        self.baseline = GradeBaseline(config: config, sink: sink)
        self.vibration = HighFrequencyIndicator(config: config)
        self.delayed = DelayedStateBuffer(config: config)
        self.groundAcceleration = GroundAccelerationEstimator(config: config)
        self.diag = DiagnosticEmitter(sink: sink, category: "pipe")
    }

    public mutating func setThermalState(_ state: Int) { thermalState = state }

    /// Re-arms the attitude/alignment anchor — see `AttitudeESKF.requestReanchor()`.
    /// The host calls this when a calibration completes so the pose the rider just
    /// held still becomes the new zero.
    public mutating func requestReanchor() { filter.requestReanchor() }

    /// Returns output on `.imu` samples — the 100 Hz spine. Other cases update
    /// internal state and return nil, per `Stage`'s documented nil convention.
    public mutating func process(_ sample: Sample) -> PipelineOutput? {
        switch sample {
        case .imu(let imu):
            return processIMU(imu)
        case .gnss(let fix):
            processGNSS(fix)
            return nil
        case .baro, .wheelSpeed:
            // Barometer is logged but unused in v1; wheel speed is a reserved slot.
            return nil
        }
    }

    private mutating func processIMU(_ imu: IMUSample) -> PipelineOutput? {
        vibration.process(imu)
        if vibration.instantaneousRMS > config.highFreqRMSThreshold {
            flags.insert(.highVibration)
        }
        if imu.saturated {
            lastSpecificForce = imu.specificForce
        }

        let rawVerdict = gate.process(imu)
        let verdict = rawVerdict ?? ValidityGate.Verdict(isOpen: false,
                                                         heldFor: 0,
                                                         reason: .noData)
        if rawVerdict == nil { missingVerdictCount += 1 }
        filter.propagate(imu, thermalState: thermalState)
        filter.updateWithGravity(imu, verdict: verdict)

        if filter.isDegraded { flags.insert(.estimatorDegraded) }

        lastSpecificForce = imu.specificForce
        lastGateOpen = verdict.isOpen

        // Record the state so a late GNSS fix can be applied where it belongs.
        delayed.record(filter.snapshot(measuredRate: imu.rotationRate,
                                       specificForce: imu.specificForce,
                                       saturated: imu.saturated,
                                       gateOpen: verdict.isOpen,
                                       gateReason: verdict.reason))

        let rawPitch = filter.pitch
        // The baseline exists to remove sustained ROAD GRADE (design §8.6, R8.8), and
        // must never absorb the rider's own sustained pitch. Freezing on gate closure
        // alone is not enough: a phone held steady at a large tilt is quasi-static, so
        // the gate stays OPEN and the 25 s baseline chases the held angle — a held
        // 20 deg decays as 20·e^(-t/25), reading 13 deg after 10 s and under 3 deg
        // after 50 s. Adapt only while genuinely near level and outside an attempt. A
        // real road grade is a few degrees, well inside the band, so R8.8's +/-4 deg
        // absorption is unaffected; this also stops a first gate-open sample taken
        // while already tilted from seeding that tilt as the new zero.
        let nearLevel = abs(rawPitch) < config.eventEntryPitch
        let baselineMayAdapt = verdict.isOpen && !eventActive && nearLevel
        let corrected = baseline.process(GradeBaseline.Input(pitch: rawPitch,
                                                            gateOpen: baselineMayAdapt,
                                                            time: imu.time,
                                                            verdictOpen: verdict.isOpen,
                                                            eventActive: eventActive,
                                                            nearLevel: nearLevel)) ?? rawPitch

        emitPipeDiagnostics(time: imu.time, pitch: corrected, gateOpen: verdict.isOpen)

        return PipelineOutput(time: imu.time,
                              attitude: filter.attitude,
                              pitch: corrected,
                              rawPitch: rawPitch,
                              pitchRate: filter.pitchRate,
                              roll: filter.roll,
                              gyroBias: filter.bias,
                              pitchSigma: filter.pitchSigma,
                              gateOpen: verdict.isOpen,
                              gateReason: verdict.reason,
                              grade: baseline.grade,
                              speed: lastSpeed,
                              vibration: vibration.instantaneousRMS,
                              flags: flags)
    }

    private mutating func processGNSS(_ fix: GNSSFix) {        if fix.isSpeedValid { lastSpeed = fix.speed }

        guard let estimate = groundAcceleration.process(fix) else { return }

        // Suppressed during an event and for a margin afterwards: at 1 Hz this
        // cannot track a 1.2 s ramp, and a Doppler difference straddling onset is
        // meaningless.
        if eventActive {
            gnssAidingSuppressed += 1
            return
        }
        if let end = lastEventEndTime,
           estimate.midTime - end < config.gnssAidingEventMargin {
            gnssAidingSuppressed += 1
            return
        }

        let forward = alignment.forwardInBody.normalized
        let force = lastSpecificForce
        let applied = delayed.applyRetroactively(
            to: &filter,
            fixTime: estimate.midTime,
            thermalState: thermalState
        ) { filter, snapshot in
            let fx = snapshot.specificForce.dot(forward)
            filter.updateWithGNSSPitch(longitudinalForce: fx,
                                       groundAcceleration: estimate.acceleration,
                                       accelerationSigma: estimate.sigma)
        }
        _ = force
        if applied { gnssAidingApplied += 1 }
    }

    // MARK: - Diagnostics

    /// Observed input-rate heartbeat plus low-rate / gap warnings. Rate is
    /// samples-seen over elapsed SAMPLE time, so it reflects what the pipeline
    /// actually received, not a wall clock.
    private mutating func emitPipeDiagnostics(time: TimeInterval, pitch: Double, gateOpen: Bool) {
        samplesSeen += 1
        let epoch = firstSampleTime ?? time
        firstSampleTime = epoch

        // Gap warning: no sample for > 0.5 s of sample time. Checked against the
        // PREVIOUS sample time before we overwrite it.
        if let last = lastSampleTime {
            let gap = time - last
            if gap > 0.5 {
                diag.always(time: time, level: .warn,
                            message: "pipe sample gap",
                            values: ["gap": gap, "limit": 0.5])
            }
        }
        lastSampleTime = time

        let elapsed = time - epoch
        let observedRate = elapsed > 0 ? Double(samplesSeen - 1) / elapsed : 0
        let degrees = 180.0 / .pi

        // Low-rate warning: observed rate below 50 Hz once enough elapsed time
        // exists to measure it (avoid a spurious warn on the first fraction of a
        // second when the estimate is meaningless).
        if elapsed >= 1.0 && observedRate < 50 {
            diag.always(time: time, level: .warn,
                        message: "pipe low input rate",
                        values: ["observedRate": observedRate, "limit": 50])
        }

        diag.emit("pipe", time: time,
                  message: "pipe heartbeat",
                  values: [
                    "observedRate": observedRate,
                    "pitchDeg": pitch * degrees,
                    "gateOpen": gateOpen ? 1 : 0,
                    "missingVerdictCount": Double(missingVerdictCount),
                    "samplesSeen": Double(samplesSeen),
                  ])
    }

    // MARK: - Introspection
    public var currentFlags: QualityFlags { flags }
    public var lateFixesDiscarded: Int { delayed.discardedTooOld }
    public var gradeEstimate: Double? { baseline.grade }
    public var biasEstimate: Vector3 { filter.bias }
    public var isDegraded: Bool { filter.isDegraded }

    public mutating func insertFlag(_ flag: QualityFlags) { flags.insert(flag) }
}

/// Convenience: run a whole source through the pipeline and collect every record.
/// Used by the CLI, the tests, and the smoother's forward pass.
public func runPipeline<S: MeasurementSource>(source: inout S,
                                             pipeline: inout Pipeline) -> [PipelineOutput] {
    var out: [PipelineOutput] = []
    while let sample = source.next() {
        if let record = pipeline.process(sample) { out.append(record) }
    }
    return out
}
