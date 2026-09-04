import Foundation

/// Gyro bias calibration — the dominant error term in the whole system.
///
/// Gyro integration over a 5-30 s event drifts only 0.03-0.08 deg, so the error
/// budget is almost entirely the two initial conditions: pitch at onset and BIAS
/// at onset. Bias to +/-0.5 deg/s gives 5 deg of error over a 10 s hold;
/// +/-0.05 deg/s gives 0.5 deg. Accuracy is decided during the boring
/// straight-line run-up, not during the wheelie.
///
/// Self-heating then walks bias ~0.1 deg/s over 30 min, which is a whole degree
/// over a 10 s hold, so a single zeroing at boot is not enough: age is tracked
/// and confidence decays with it. Every traffic light is a free re-zero.

public enum Axis: String, Codable, Sendable, CaseIterable {
    case x, y, z
}

/// The output of one successful zeroing.
public struct BiasEstimate: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    /// Estimated gyro bias, rad/s, body frame.
    public var bias: Vector3
    /// Standard error of the mean per axis, rad/s. This is the number that
    /// decides whether the estimate is usable.
    public var sigma: Vector3
    public var sampleCount: Int
    /// Monotonic time of completion — used for age, because wall clock jumps.
    public var monotonicTime: TimeInterval
    /// Wall clock of completion — used for display only.
    public var wallClock: Date
    public var bikeProfileID: UUID
    /// ProcessInfo.ThermalState raw value at capture, for drift projection.
    public var thermalStateAtCapture: Int
    /// Mean specific force over the SAME window, m/s^2 — the gravity anchor.
    ///
    /// Specific force points ALONG gravity (a level bike at rest reads `(0,0,-g)`),
    /// so this is gravity's direction in DEVICE axes, scaled by g. It is the second
    /// product of a calibration and the input the swipe alignment consumes: gravity
    /// fixes two of the three axes and the swipe supplies the third.
    ///
    /// Optional so estimates persisted before this existed still decode. `nil` means
    /// "this calibration predates gravity capture", which a caller must treat as
    /// "cannot build an alignment" rather than substituting a guess — there is no
    /// preset to fall back to, by design.
    public var measuredGravity: Vector3?

    public init(id: UUID = UUID(),
                bias: Vector3,
                sigma: Vector3,
                sampleCount: Int,
                monotonicTime: TimeInterval,
                wallClock: Date = Date(),
                bikeProfileID: UUID,
                thermalStateAtCapture: Int = 0,
                measuredGravity: Vector3? = nil) {
        self.measuredGravity = measuredGravity
        self.id = id
        self.bias = bias
        self.sigma = sigma
        self.sampleCount = sampleCount
        self.monotonicTime = monotonicTime
        self.wallClock = wallClock
        self.bikeProfileID = bikeProfileID
        self.thermalStateAtCapture = thermalStateAtCapture
    }

    /// Worst per-axis sigma, rad/s.
    public var worstSigma: Double { max(sigma.x, max(sigma.y, sigma.z)) }

    /// Projected 1-sigma bias uncertainty after `age` seconds, accounting for
    /// random-walk drift scaled by thermal state.
    ///
    /// This is the arithmetic behind "bias goes stale": the value grows without
    /// anyone touching the phone, so reported confidence must decay with it.
    public func projectedSigma(age: TimeInterval, config: Config) -> Double {
        let scale = config.thermalBiasNoiseScale.indices.contains(thermalStateAtCapture)
            ? config.thermalBiasNoiseScale[thermalStateAtCapture]
            : config.thermalBiasNoiseScale.last ?? 1.0
        let walk = config.gyroBiasInstability * config.gyroBiasInstability
                 * max(0, age) * scale
        return (worstSigma * worstSigma + walk).squareRoot()
    }

    /// Projected 1-sigma PITCH error, radians, for a hold of `holdDuration`
    /// seconds performed `age` seconds after this zeroing. Bias error integrates
    /// linearly into angle, which is why a stale bias is expensive on a long hold
    /// and cheap on a short one.
    public func projectedPitchSigma(age: TimeInterval,
                                    holdDuration: TimeInterval,
                                    config: Config) -> Double {
        projectedSigma(age: age, config: config) * max(0, holdDuration)
    }
}


/// Why a zeroing attempt failed.
public enum CalibrationFailure: Sendable, Equatable {
    /// The estimate was too noisy to use. The axis is named so the UI can say
    /// something actionable instead of "calibration failed".
    case sigmaTooHigh(axis: Axis, sigma: Double, limit: Double)
    /// The mount is shaking hard enough to poison the estimate. The fix is
    /// mechanical, never a software setting.
    case vibrationTooHigh(rms: Double, limit: Double)
    /// The validity gate never opened long enough within the attempt window.
    case gateNeverOpened(lastReason: ValidityGate.Reason)

    public var message: String {
        switch self {
        case .sigmaTooHigh(let axis, let sigma, let limit):
            return String(format: "Gyro %@ axis too noisy: %.4f deg/s (limit %.4f). "
                          + "Hold the bike still.",
                          axis.rawValue.uppercased(),
                          sigma * 180 / .pi, limit * 180 / .pi)
        case .vibrationTooHigh(let rms, let limit):
            return String(format: "Too much vibration: %.2f m/s^2 (limit %.2f). "
                          + "Isolate the mount or switch the engine off.",
                          rms, limit)
        case .gateNeverOpened(let reason):
            switch reason {
            case .specificForceOutOfBand:
                return "Bike is not level and still."
            case .rotating:
                return "Bike is still moving."
            case .vibrating:
                return "Too much vibration — switch the engine off."
            case .saturated:
                return "Sensor saturated — vibration is off the scale."
            case .dwellNotMet, .noData, .open:
                return "Could not hold still long enough."
            }
        }
    }
}

/// Accumulates a bias estimate from stationary samples.
///
/// Gated on `ValidityGate`, so it collects only while quasi-static is PROVABLE:
/// specific force within 0.97-1.03 g, every gyro axis below 3 deg/s, held for the
/// dwell. Any gate closure resets progress and reports the gate's own reason, so
/// the UI can say why rather than spinning forever.
public struct BiasEstimator: Stage {
    public typealias Input = IMUSample

    public enum Progress: Sendable, Equatable {
        /// Collecting; `elapsed` of `required` seconds of continuous quiet, and
        /// `samples` of `requiredSamples` admitted samples. Completion needs BOTH, so
        /// both are carried: `elapsed` credits up to 3x nominal per admitted sample, so
        /// on a gate that admits sparsely it reaches `required` well before the sample
        /// floor is met. Reporting time alone made the UI read "104%", and clamping it
        /// alone made the bar sit at 100% for ~50 s on an idling bike.
        case collecting(elapsed: TimeInterval, required: TimeInterval,
                        samples: Int, requiredSamples: Int)
        /// Progress was reset by a gate closure. Carries the reason.
        case rejected(ValidityGate.Reason)
        case done(BiasEstimate)
        case failed(CalibrationFailure)

        public var fraction: Double {
            switch self {
            case .collecting(let elapsed, let required, let samples, let requiredSamples):
                // The LESSER of the two ratios, because completion needs both. Reporting
                // only the time ratio overstates progress whenever the gate admits
                // sparsely — and since it is clamped, it parks at 100% while the sample
                // floor is still filling, which reads as a hang.
                let byTime = required > 0 ? elapsed / required : 0
                let bySamples = requiredSamples > 0
                    ? Double(samples) / Double(requiredSamples) : 0
                return min(1, max(0, min(byTime, bySamples)))
            case .done:     return 1
            default:        return 0
            }
        }
    }

    private let config: Config
    private let bikeProfileID: UUID
    private let thermalState: Int

    private var gate: ValidityGate
    private var vibration: HighFrequencyIndicator

    // Welford accumulators, per axis.
    private var n: Int = 0
    private var mean = Vector3.zero
    private var m2 = Vector3.zero
    /// Running mean of specific force over the SAME admitted samples that build the
    /// bias mean. The rider is already holding the bike still to measure `b`; the
    /// gravity direction is then free, and taking it from the same window means the
    /// two can never disagree about which instant "still" referred to.
    ///
    /// A plain mean is sufficient here where it would not be for `b`: gravity is a
    /// 1 g DC vector, so averaging attacks the vibration riding on it, and the gate's
    /// `.vibrating` condition has already rejected the samples where that vibration
    /// is large enough to have tilted the direction.
    private var forceMean = Vector3.zero

    private var firstSampleTime: TimeInterval?
    private var attemptStart: TimeInterval?
    private var lastReason: ValidityGate.Reason = .noData
    private var finished = false
    /// When the gate's underlying condition was first VIOLATED continuously, or nil
    /// while it holds. Drives the grace period — see `Config.biasGateGracePeriod`.
    /// `.dwellNotMet` does not count as a violation and clears this.
    private var gateClosedSince: TimeInterval?
    /// Held-still time actually accumulated, excluding paused gaps. This, not wall
    /// sample time, is compared against `config.biasCalibrationDuration`.
    private var accumulatedDuration: TimeInterval = 0
    /// Time of the last accumulated sample, for the duration increment. Nil while
    /// paused so a gap is never billed as quiet.
    private var lastAccumulateTime: TimeInterval?

    /// Heartbeat emitter for the `.collecting` phase. Milestones (reset, finish,
    /// failed, rejected-reason changes) are emitted via `diag.always` so they are
    /// never coalesced away by the heartbeat cadence.
    private var diag: DiagnosticEmitter
    /// Last rejection reason we logged, so a change in it emits exactly once.
    private var lastLoggedRejection: ValidityGate.Reason?

    public init(config: Config,
                bikeProfileID: UUID,
                thermalState: Int = 0,
                sink: DiagnosticSink? = nil) {
        self.config = config
        self.bikeProfileID = bikeProfileID
        self.thermalState = thermalState
        // Calibration's gate runs on the WIDER specific-force band AND the wider
        // rotation ceiling. See `Config.calibrationSpecificForceLow` for the band
        // argument: it is an accelerometer proxy for stillness here and never enters the
        // gyro mean, so widening it costs the estimate under 0.001 deg/s — whereas
        // widening the estimator's copy would let 0.3 g of thrust pass as "at rest" and
        // feed 16.7 deg of phantom tilt into the ESKF's gravity update.
        //
        // The rotation ceiling is now split too. It DOES enter the gyro mean, but
        // `biasSigmaLimit` is the real backstop there (28x margin measured), whereas the
        // estimator cannot afford a wider limit at all: the same verdict gates its
        // gravity update, and 5 deg/s kept the gate open into the start of a lift and
        // pinned the reported angle at zero until it snapped. Dwell stays shared.
        var gateConfig = config
        gateConfig.gateSpecificForceLow = config.calibrationSpecificForceLow
        gateConfig.gateSpecificForceHigh = config.calibrationSpecificForceHigh
        gateConfig.gateMaxRotationRate = config.calibrationMaxRotationRate
        self.gate = ValidityGate(config: gateConfig)
        self.vibration = HighFrequencyIndicator(config: config)
        self.diag = DiagnosticEmitter(sink: sink, category: "bias")
    }

    public mutating func process(_ sample: IMUSample) -> Progress? {
        guard !finished else { return nil }

        if attemptStart == nil { attemptStart = sample.time }
        vibration.process(sample)

        // A saturated sample never enters a bias estimate.
        guard !sample.saturated else {
            resetAccumulation(reason: "saturated", at: sample.time)
            lastReason = .saturated
            emitRejection(.saturated, at: sample.time)
            return checkAttemptWindow(at: sample.time)
                ?? .rejected(.saturated)
        }

        guard let verdict = gate.process(sample) else { return nil }

        guard verdict.isOpen else {
            lastReason = verdict.reason
            emitRejection(verdict.reason, at: sample.time)

            // A dropout no longer destroys progress outright. Previously ANY single
            // closed sample called `resetAccumulation()`, so one 10 ms blip — 0.2 deg
            // of rotation, one lip in the driveway — discarded every sample collected
            // so far and reset the dwell with it. On a running bike that fired
            // continuously and the required 8 s of unbroken quiet never assembled:
            // this is the "stuck at 0%" a rider actually sees. Progress is PAUSED
            // here instead, and discarded only once the condition has been violated
            // for longer than the grace period, i.e. long enough that the bike may
            // genuinely have moved or been re-oriented.
            //
            // `.dwellNotMet` is deliberately NOT treated as a violation: it means the
            // condition is satisfied right now and has simply not held for the dwell
            // yet. Counting it would make the grace period useless, because the
            // gate's own 0.5 s dwell always outlasts it — every violation is followed
            // by a dwell, so progress would still be wiped every time.
            if verdict.reason == .dwellNotMet {
                gateClosedSince = nil
            } else {
                let violatedSince = gateClosedSince ?? sample.time
                gateClosedSince = violatedSince
                if n > 0, sample.time - violatedSince >= config.biasGateGracePeriod {
                    resetAccumulation(reason: verdict.reason.rawValue, at: sample.time)
                }
            }
            // Nothing accumulates while the gate is shut, so the next open sample
            // must not bill the gap as held-still time.
            lastAccumulateTime = nil

            if let window = checkAttemptWindow(at: sample.time) {
                if case .failed(let f) = window { emitFailed(f, at: sample.time) }
                return window
            }
            return .rejected(verdict.reason)
        }

        gateClosedSince = nil

        // Vibration is MEASURED and logged here, never used to fail a zeroing.
        //
        // The two hard-fail branches that used to live here (one on the closed path,
        // one here on the open path) made calibrating on a running bike impossible
        // and mid-ride recalibration impossible outright, and the reasoning behind
        // them does not survive inspection. The estimate is the MEAN of the gyro, and
        // averaging is precisely the operation that removes zero-mean vibration; what
        // survives is the standard error, `std/sqrt(n)`, which `biasSigmaLimit`
        // already bounds directly. Only two mechanisms turn vibration into a DC error
        // that a mean cannot reject — SATURATION, whose non-linear rail rectifies AC
        // into DC and which is still a hard reject on its own flag above, and
        // ALIASING, which a spread test cannot detect at all (as the old comment here
        // conceded). So the check never guarded the case that can hurt, and blocked
        // the case that cannot.
        let spread = vibration.magnitudeStdDev

        // A sample can sit inside an OPEN gate and still be untrustworthy: the gate
        // deliberately does not close on a violation shorter than
        // `config.gateCloseConfirm`, because engine excitation is exactly that. Such
        // a sample must not enter the mean — one 20 deg/s spike among 600 quiet
        // samples moves the bias by 0.033 deg/s, most of the whole budget. Skipping
        // it is a one-sample PAUSE, not a discard: accumulated progress survives.
        guard gate.sampleWithinBand(sample) else {
            lastAccumulateTime = nil
            return .collecting(elapsed: accumulatedDuration,
                               required: config.biasCalibrationDuration,
                               samples: n,
                               requiredSamples: requiredSampleCount)
        }

        // A gap far larger than a nominal interval is not a pause, it is a
        // DISCONTINUITY: the sensor stream died — the rider left the Live tab, the
        // consuming Task was cancelled, the session restarted — and the pre-gap
        // partial estimate can no longer be assumed to describe the same still bike
        // at the same temperature in the same pose. A device log has a 19 s gap
        // straddled by one accumulation window. The 30-nominal-interval threshold
        // (300 ms at 100 Hz) is far past any real scheduling jitter and far below any
        // genuine dropout, and deliberately larger than `biasGateGracePeriod`: a gap
        // this size means missing SAMPLES, which is a different thing from a gate
        // closure. Begin the window afresh from this sample rather than pooling
        // across the dead stream.
        if let previous = lastAccumulateTime, sample.time - previous > discontinuityGap {
            resetAccumulation(reason: "streamGap", at: sample.time)
            accumulate(sample.rotationRate)
            accumulateForce(sample.specificForce)
            firstSampleTime = sample.time
            lastAccumulateTime = sample.time
            return .collecting(elapsed: 0, required: config.biasCalibrationDuration,
                               samples: n, requiredSamples: requiredSampleCount)
        }

        accumulate(sample.rotationRate)
        accumulateForce(sample.specificForce)
        if firstSampleTime == nil { firstSampleTime = sample.time }
        // Held-still time EXCLUDING paused gaps. Using wall sample time here would
        // let a long dropout be billed as quiet: with progress now surviving a brief
        // closure, `sample.time - firstSampleTime` would count the gap toward the
        // 8 s and complete a zeroing built from fewer samples than it claims.
        if let previous = lastAccumulateTime {
            // The credited interval is CAPPED. Billing the raw gap lets a STALL count
            // as held-still time: if the sensor stops for 300 ms and resumes in band,
            // that 300 ms is credited even though nothing was collected. A device log
            // caught this completing an "8 s" zeroing from 25 samples (sqrtN=5, SEM
            // 0.08 deg/s) across a session restart — precisely the quietly-wrong
            // estimate this type exists to prevent.
            let nominalInterval = config.nominalSampleRate > 0
                ? 1 / config.nominalSampleRate
                : 0.01
            accumulatedDuration += min(max(0, sample.time - previous), nominalInterval * 3)
        }
        lastAccumulateTime = sample.time
        let elapsed = accumulatedDuration

        // Completion requires BOTH enough held-still TIME and enough SAMPLES. Time
        // alone is forgeable by a stalled stream even with the cap above; sample count
        // alone would accept a dense burst that spans no real duration. And n is the
        // quantity the reported uncertainty actually depends on, since the standard
        // error falls as 1/sqrt(n) — a 25-sample zeroing has sqrt(n) of 5 rather than
        // 28, so it reports four to five times the uncertainty of a real one.
        let requiredSamples = requiredSampleCount
        guard elapsed >= config.biasCalibrationDuration, n >= requiredSamples else {
            // Heartbeat the collecting phase at 1 Hz: n / elapsed / required, plus
            // vibration.magnitudeStdDev against its threshold on EVERY heartbeat.
            diag.emit("collecting", time: sample.time,
                      message: "bias collecting",
                      values: [
                        "n": Double(n),
                        "elapsed": elapsed,
                        "required": config.biasCalibrationDuration,
                        "vibrationStdDev": spread,
                        "calibrationVibrationThreshold": config.calibrationVibrationThreshold,
                      ])
            return .collecting(elapsed: elapsed,
                               required: config.biasCalibrationDuration,
                               samples: n,
                               requiredSamples: requiredSamples)
        }

        finished = true
        return finish(at: sample.time)
    }

    private mutating func checkAttemptWindow(at time: TimeInterval) -> Progress? {
        guard let start = attemptStart,
              time - start >= config.biasAttemptWindow else { return nil }
        finished = true
        return .failed(.gateNeverOpened(lastReason: lastReason))
    }

    /// Inter-sample gap beyond which the stream is treated as having DIED rather
    /// than paused — 30 nominal intervals, i.e. 300 ms at 100 Hz.
    private var discontinuityGap: TimeInterval {
        config.nominalSampleRate > 0 ? 30.0 / config.nominalSampleRate : 0.3
    }

    /// Sample floor for completion: half the nominal count for the configured
    /// duration (8 s x 100 Hz x 0.5 = 400). Half, not all, because `elapsed` already
    /// bounds real held-still time and some sample loss is tolerable; the floor exists
    /// so a stalled stream cannot bill time it never sampled. Also reported in
    /// `Progress.collecting` so the UI can show the binding constraint.
    private var requiredSampleCount: Int {
        Int(config.biasCalibrationDuration * config.nominalSampleRate * 0.5)
    }

    private mutating func accumulate(_ v: Vector3) {        n += 1
        let delta = v - mean
        mean = mean + delta / Double(n)
        let delta2 = v - mean
        m2 = m2 + Vector3(delta.x * delta2.x, delta.y * delta2.y, delta.z * delta2.z)
    }

    /// Called with the SAME sample that fed `accumulate`, so the two means always
    /// describe the same window. Split into its own function only because the rate
    /// needs Welford's variance and gravity does not.
    private mutating func accumulateForce(_ f: Vector3) {
        forceMean = forceMean + (f - forceMean) / Double(max(1, n))
    }

    private mutating func resetAccumulation(reason: String = "reset",
                                            at time: TimeInterval = 0) {
        // Log EVERY resetAccumulation with n discarded, elapsedBeforeReset, reason.
        // Only meaningful when something was actually accumulated.
        if n > 0 {
            let elapsedBeforeReset = firstSampleTime.map { time - $0 } ?? 0
            diag.always(time: time, level: .debug,
                        message: "bias reset accumulation",
                        values: [
                            "nDiscarded": Double(n),
                            "elapsedBeforeReset": elapsedBeforeReset,
                        ])
        }
        n = 0
        mean = .zero
        m2 = .zero
        forceMean = .zero
        firstSampleTime = nil
        accumulatedDuration = 0
        lastAccumulateTime = nil
        gate.reset()
    }

    private mutating func finish(at time: TimeInterval) -> Progress {
        guard n > 1 else {
            emitFailed(.gateNeverOpened(lastReason: lastReason), at: time)
            return .failed(.gateNeverOpened(lastReason: lastReason))
        }
        // Sample standard deviation, then the standard error of the mean. The
        // MEAN is the estimate, so its uncertainty is what matters, and it falls
        // as 1/sqrt(n) — which is why the duration is specified in seconds of
        // held-still rather than in samples.
        let variance = m2 / Double(n - 1)
        let root = Double(n).squareRoot()
        let sigma = Vector3(variance.x.squareRoot() / root,
                            variance.y.squareRoot() / root,
                            variance.z.squareRoot() / root)

        // PER AXIS: raw sample standard deviation, standard error of the mean, and
        // mean bias — all in deg/s — plus n, sqrt(n), biasSigmaLimit. Reported
        // sigma is the SEM; keeping the raw std and n separate is what tells the
        // sensor noise floor apart from real motion behind a "gyro too noisy"
        // failure. Emitted BEFORE the sigma threshold check so a failing axis is
        // still fully described.
        let degrees = 180.0 / .pi
        let rawStd = Vector3(variance.x.squareRoot(),
                             variance.y.squareRoot(),
                             variance.z.squareRoot())
        diag.always(time: time, level: .info,
                    message: "bias finish",
                    values: [
                        "n": Double(n),
                        "sqrtN": root,
                        "biasSigmaLimit": config.biasSigmaLimit * degrees,
                        "rawStdX": rawStd.x * degrees,
                        "rawStdY": rawStd.y * degrees,
                        "rawStdZ": rawStd.z * degrees,
                        "semX": sigma.x * degrees,
                        "semY": sigma.y * degrees,
                        "semZ": sigma.z * degrees,
                        "meanBiasX": mean.x * degrees,
                        "meanBiasY": mean.y * degrees,
                        "meanBiasZ": mean.z * degrees,
                    ])

        let limit = config.biasSigmaLimit
        for (axis, value) in [(Axis.x, sigma.x), (.y, sigma.y), (.z, sigma.z)] {
            if value > limit {
                emitFailed(.sigmaTooHigh(axis: axis, sigma: value, limit: limit), at: time)
                return .failed(.sigmaTooHigh(axis: axis, sigma: value, limit: limit))
            }
        }

        let estimate = BiasEstimate(bias: mean,
                                    sigma: sigma,
                                    sampleCount: n,
                                    monotonicTime: time,
                                    bikeProfileID: bikeProfileID,
                                    thermalStateAtCapture: thermalState,
                                    measuredGravity: forceMean)
        return .done(estimate)
    }

    // MARK: - Diagnostics helpers

    /// Emit each `.rejected` reason CHANGE exactly once. Numbers are the gate's,
    /// available on the gate channel; here the categorical reason is the signal.
    private mutating func emitRejection(_ reason: ValidityGate.Reason,
                                        at time: TimeInterval) {
        guard reason != lastLoggedRejection else { return }
        lastLoggedRejection = reason
        diag.always(time: time, level: .debug,
                    message: "bias rejected " + reason.rawValue,
                    values: ["reason": 1])
    }

    /// Emit a `.failed` with the failure's numbers at error level.
    private func emitFailed(_ failure: CalibrationFailure, at time: TimeInterval) {
        let degrees = 180.0 / .pi
        switch failure {
        case .sigmaTooHigh(let axis, let sigma, let limit):
            diag.always(time: time, level: .error,
                        message: "bias failed sigmaTooHigh",
                        values: [
                            "axis": Double(Axis.allCases.firstIndex(of: axis) ?? -1),
                            "sigmaDegPerSec": sigma * degrees,
                            "limitDegPerSec": limit * degrees,
                        ])
        case .vibrationTooHigh(let rms, let limit):
            diag.always(time: time, level: .error,
                        message: "bias failed vibrationTooHigh",
                        values: ["rms": rms, "limit": limit])
        case .gateNeverOpened(let reason):
            diag.always(time: time, level: .error,
                        message: "bias failed gateNeverOpened " + reason.rawValue,
                        values: ["lastReason": 1])
        }
    }

    /// Abandon and restart, e.g. the rider tapped retry.
    public mutating func restart() {
        resetAccumulation()
        vibration.reset()
        attemptStart = nil
        lastReason = .noData
        finished = false
        gateClosedSince = nil
    }
}

