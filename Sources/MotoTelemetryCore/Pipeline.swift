import Foundation

/// One output record per IMU sample: every stage's result, not just the final angle.
///
/// When a reading is wrong you need to see WHICH stage first went wrong. A single
/// displayed number tells you nothing, and re-deriving intermediate values after the
/// fact is guesswork.
public struct PipelineOutput: Codable, Sendable, Equatable {
    public var time: TimeInterval
    public var attitude: Quaternion
    /// Axis elevation above horizontal, radians. THE number.
    public var pitch: Double
    public var pitchRate: Double
    public var roll: Double
    /// The constant bias subtracted from every rotation rate, rad/s.
    public var gyroBias: Vector3
    /// Open-loop 1-sigma on pitch, radians, projected from the AGE of the bias
    /// estimate — not a filter covariance, because there is no filter. See
    /// `CalibrateOnceEstimator.projectedPitchSigma`.
    public var pitchSigma: Double
    /// Describes the included component. nil in legacy records means unknown.
    public var pitchSigmaModel: String? = nil
    public var pitchSigmaValid: Bool? = nil
    /// Most recent valid GNSS ground speed, m/s; nil before the first fix.
    public var speed: Double?
    /// Vibration indicator for the window in progress, m/s^2.
    public var vibration: Double
    public var flags: QualityFlags

    public init(time: TimeInterval,
                attitude: Quaternion,
                pitch: Double,
                pitchRate: Double,
                roll: Double,
                gyroBias: Vector3,
                pitchSigma: Double,
                speed: Double?,
                vibration: Double,
                flags: QualityFlags) {
        self.time = time
        self.attitude = attitude
        self.pitch = pitch
        self.pitchRate = pitchRate
        self.roll = roll
        self.gyroBias = gyroBias
        self.pitchSigma = pitchSigma
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
/// ## What this is, after the beta simplification
/// Raw gyro, debiased by a constant measured once at calibration, integrated as a
/// quaternion, read as an axis elevation:
///
///     rate  = rawGyro - b
///     Q     = Q * exp(rate * dt)
///     pitch = asin(rotate(forwardInBody).z)
///
/// That is the whole live estimator. The accelerometer is not consumed here at all —
/// it is a calibration instrument, read only while a calibration session is active
/// (see `BiasEstimator`), and never recorded.
///
/// ## What was removed, and why it is not coming back by accident
/// The gated ESKF, the RTS smoother, the delayed-state buffer for retroactive GNSS
/// correction, and the grade baseline are all DELETED on this branch, not disabled
/// behind a flag. They were correct and tested and they never ran in the product,
/// which is this project's signature failure mode — eight complete-but-unwired
/// subsystems, and documentation describing a smoother that had no caller. A second
/// estimator kept "just in case" is that pattern with a nicer name. Git holds them:
/// they remain on `main` and `staging/core-pipeline`.
///
/// Three consequences follow directly, and each is visible rather than silent:
///   - **No grade correction.** `GradeBaseline` estimated road grade from gate-open
///     pitch; with no gate there is no estimate, so riding uphill reads as nose-up.
///   - **No drift correction.** Bias is measured once, so thermal walk accumulates
///     (~0.1 deg/s over 30 min; ~5 deg over a 10 s hold at 0.5 deg/s). `pitchSigma`
///     grows with bias age so the UI can say how much to distrust the number, and
///     `JitterBlur` does NOT help — it removes jitter, not drift.
///   - **No GNSS/IMU fusion.** Speed is an independent ~1 Hz display channel.
public struct Pipeline {
    private let config: Config
    /// Bike axes in device axes, from the swipe calibration.
    public let alignment: MountAlignment

    private var estimator: CalibrateOnceEstimator
    private var vibration: HighFrequencyIndicator
    /// Held to project the open-loop sigma, which needs the estimate's AGE.
    private let initialBias: BiasEstimate?

    private var uncertaintyAnchorTime: TimeInterval?
    private var uncertaintyInvalid = false
    private var previousIntegrationTime: TimeInterval?

    private var lastSpeed: Double?
    private var lastSpeedTime: TimeInterval?
    public static let speedFreshnessLimit: TimeInterval = 2.5

    public mutating func clearSpeed() { lastSpeed = nil; lastSpeedTime = nil }
    private var flags: QualityFlags = []
    private var lastSpecificForce = Vector3.zero

    /// Set by the host when an event is in progress. Retained because the segmenter
    /// is downstream and the recorder wants to know, even though nothing in this
    /// pipeline is suppressed by it any more.
    public var eventActive = false

    // MARK: - Diagnostics state
    private var diag: DiagnosticEmitter
    /// Sample-time epoch and running counts for the observed-rate heartbeat.
    private var firstSampleTime: TimeInterval?
    private var samplesSeen: Int = 0
    private var lastSampleTime: TimeInterval?

    public init(config: Config,
                alignment: MountAlignment,
                initialBias: BiasEstimate?,
                gravityAnchor: Vector3? = nil,
                sink: DiagnosticSink? = nil) {
        self.config = config
        self.alignment = alignment
        self.initialBias = initialBias
        self.estimator = CalibrateOnceEstimator(config: config,
                                                alignment: alignment,
                                                bias: initialBias?.bias ?? .zero,
                                                gravityAnchor: gravityAnchor)
        self.vibration = HighFrequencyIndicator(config: config)
        self.diag = DiagnosticEmitter(sink: sink, category: "pipe")
    }

    /// Re-anchors attitude so the pose the rider just held becomes the new zero.
    /// Called when a calibration COMPLETES, which is why it acts immediately rather
    /// than waiting for another quiet sample: the gate already proved the bike still,
    /// so waiting would be waiting for evidence already gathered.
    public mutating func requestReanchor() {
        guard lastSpecificForce.magnitude > 1e-6 else { return }
        estimator.anchor(with: lastSpecificForce)
        uncertaintyAnchorTime = nil
        previousIntegrationTime = nil
        uncertaintyInvalid = false
    }

    /// Establishes the world frame from a calibration's measured gravity vector.
    public mutating func anchor(with specificForce: Vector3) {
        lastSpecificForce = specificForce
        estimator.anchor(with: specificForce)
        uncertaintyAnchorTime = nil
        previousIntegrationTime = nil
        uncertaintyInvalid = false
    }

    /// Returns output on `.imu` samples — the 100 Hz spine. Other cases update
    /// internal state and return nil, per `Stage`'s documented nil convention.
    public mutating func process(_ sample: Sample) -> PipelineOutput? {
        switch sample {
        case .imu(let imu):
            return processIMU(imu)
        case .gnss(let fix):
            // Speed only. Uncoupled from the IMU stream by design: at ~1 Hz it cannot
            // track a 1.2 s pitch ramp, and with no filter to correct there is
            // nothing to fuse it into.
            //
            // ASSIGNED, not conditionally assigned. This was
            // `if let speed = fix.resolvedSpeed { lastSpeed = speed }`, which ignored a
            // nil — so a fix that explicitly reports NO speed solution (CoreLocation
            // sends speed = -1) left the previous reading in place permanently. One
            // valid fix followed by a run of invalid ones held that number for the rest
            // of the session and kept `speed != nil`, i.e. kept claiming the speed was
            // available. A fix saying "I have no speed" is positive evidence, not an
            // absence of evidence, so it clears the value.
            guard fix.fixTime.isFinite, fix.arrivalTime.isFinite else { return nil }
            if let previous = lastSpeedTime, fix.fixTime < previous { return nil }
            lastSpeedTime = fix.fixTime
            let age = fix.arrivalTime - fix.fixTime
            lastSpeed = age >= 0 && age <= Self.speedFreshnessLimit ? fix.resolvedSpeed : nil
            return nil
        case .baro, .wheelSpeed:
            // Neither is consumed by this estimator, but both remain part of the LOG
            // WIRE FORMAT: fixtures and previously-recorded rides contain them, and a
            // Sample that cannot represent them could not decode an old log. Inert
            // here, load-bearing for replay.
            return nil
        }
    }

    private mutating func processIMU(_ imu: IMUSample) -> PipelineOutput? {
        vibration.process(imu)
        if vibration.instantaneousRMS > config.highFreqRMSThreshold {
            flags.insert(.highVibration)
        }
        if imu.saturated, eventActive {
            flags.insert(.saturatedInEvent)
        }
        lastSpecificForce = imu.specificForce

        if let previous = previousIntegrationTime,
           imu.time <= previous || imu.time - previous >= config.maxIntegrationDt {
            uncertaintyInvalid = true
        }
        previousIntegrationTime = imu.time
        estimator.integrate(imu)

        // Publish NOTHING until gravity has tied the world frame down. Before that,
        // integrated attitude is relative to the initial DEVICE frame, which for a
        // crooked mount differs from the world by the whole mount rotation — a device
        // log once showed -89.7 deg reaching the pipeline 16 ms ahead of the anchor,
        // and downstream nothing distinguishes that from a real -89.7 deg.
        guard estimator.isAnchored else {
            emitPipeDiagnostics(time: imu.time, pitch: .nan)
            return nil
        }

        let pitch = estimator.pitch
        emitPipeDiagnostics(time: imu.time, pitch: pitch)

        if uncertaintyAnchorTime == nil { uncertaintyAnchorTime = imu.time }
        let elapsed = max(0, imu.time - (uncertaintyAnchorTime ?? imu.time))
        // Only the calibration mean's sampling uncertainty is evidenced by the
        // existing data. Do not silently assign units to the legacy walk constant.
        let variance = initialBias.flatMap {
            PitchUncertaintyModel.variance(initialVariance: 0, biasSigma: $0.worstSigma,
                rateNoisePSD: 0, biasWalkPSD: 0, calibrationAgeAtAnchor: 0, elapsed: elapsed)
        }
        let sigma = variance?.squareRoot() ?? config.liveSigmaLimit
        let valid = variance != nil && !uncertaintyInvalid
        if !valid { flags.insert(.estimatorDegraded) }
        if sigma >= config.liveSigmaLimit { flags.insert(.lowConfidence) }
        var result = PipelineOutput(time: imu.time,
                              attitude: estimator.attitude,
                              pitch: pitch,
                              pitchRate: estimator.pitchRate,
                              roll: estimator.roll,
                              gyroBias: initialBias?.bias ?? .zero,
                              pitchSigma: sigma,
                              speed: lastSpeedTime.flatMap { time in
                                  let age = imu.time - time
                                  return age >= 0 && age <= Self.speedFreshnessLimit ? lastSpeed : nil
                              },
                              vibration: vibration.instantaneousRMS,
                              flags: flags)
        result.pitchSigmaModel = "calibration-mean-only-v1; excludes anchor, mount, rate noise and thermal drift"
        result.pitchSigmaValid = valid
        return result
    }

    // MARK: - Diagnostics

    /// Observed input-rate heartbeat plus low-rate / gap warnings. Rate is
    /// samples-seen over elapsed SAMPLE time, so it reflects what the pipeline
    /// actually received, not a wall clock.
    private mutating func emitPipeDiagnostics(time: TimeInterval, pitch: Double) {
        samplesSeen += 1
        let epoch = firstSampleTime ?? time
        firstSampleTime = epoch

        // Gap warning: no sample for > Config.maxSampleGap of sample time. Checked
        // against the PREVIOUS sample time before we overwrite it.
        if let last = lastSampleTime {
            let gap = time - last
            if gap > config.maxSampleGap {
                diag.always(time: time, level: .warn,
                            message: "pipe sample gap",
                            values: ["gap": gap, "limit": config.maxSampleGap])
                flags.insert(.gapExceeded)
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
            flags.insert(.lowRate)
        }

        diag.emit("pipe", time: time,
                  message: "pipe heartbeat",
                  values: [
                    "observedRate": observedRate,
                    "pitchDeg": pitch * degrees,
                    "samplesSeen": Double(samplesSeen),
                  ])
    }

    // MARK: - Introspection
    public var currentFlags: QualityFlags { flags }
    public var biasEstimate: Vector3 { initialBias?.bias ?? .zero }
    public var isAnchored: Bool { estimator.isAnchored }

    public mutating func resetQualityFlags() { flags = [] }

    public mutating func insertFlag(_ flag: QualityFlags) { flags.insert(flag) }
}

/// Convenience: run a whole source through the pipeline and collect every record.
/// Used by the CLI and the tests.
public func runPipeline<S: MeasurementSource>(source: inout S,
                                             pipeline: inout Pipeline) -> [PipelineOutput] {
    var out: [PipelineOutput] = []
    while let sample = source.next() {
        if let record = pipeline.process(sample) { out.append(record) }
    }
    return out
}
