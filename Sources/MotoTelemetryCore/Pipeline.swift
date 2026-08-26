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
    private let alignment: MountAlignment

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

    public init(config: Config,
                alignment: MountAlignment,
                initialBias: BiasEstimate?,
                gravityAnchor: Vector3? = nil) {
        self.config = config
        self.alignment = alignment
        self.filter = AttitudeESKF(config: config,
                                   alignment: alignment,
                                   initialBias: initialBias,
                                   gravityAnchor: gravityAnchor)
        self.gate = ValidityGate(config: config)
        self.baseline = GradeBaseline(config: config)
        self.vibration = HighFrequencyIndicator(config: config)
        self.delayed = DelayedStateBuffer(config: config)
        self.groundAcceleration = GroundAccelerationEstimator(config: config)
    }

    public mutating func setThermalState(_ state: Int) { thermalState = state }

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

        let verdict = gate.process(imu) ?? ValidityGate.Verdict(isOpen: false,
                                                               heldFor: 0,
                                                               reason: .noData)
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
        let corrected = baseline.process(GradeBaseline.Input(pitch: rawPitch,
                                                            gateOpen: verdict.isOpen,
                                                            time: imu.time)) ?? rawPitch

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

    private mutating func processGNSS(_ fix: GNSSFix) {
        if fix.isSpeedValid { lastSpeed = fix.speed }

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
