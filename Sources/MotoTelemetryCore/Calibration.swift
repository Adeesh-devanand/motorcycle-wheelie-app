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

    public init(id: UUID = UUID(),
                bias: Vector3,
                sigma: Vector3,
                sampleCount: Int,
                monotonicTime: TimeInterval,
                wallClock: Date = Date(),
                bikeProfileID: UUID,
                thermalStateAtCapture: Int = 0) {
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

/// Why a previously-good calibration is no longer trusted.
public enum CalibrationStaleReason: String, Codable, Sendable, Equatable {
    case aged
    case bikeProfileChanged
    case thermalShift
    case remounted
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
            case .saturated:
                return "Sensor saturated — vibration is off the scale."
            case .dwellNotMet, .noData, .open:
                return "Could not hold still long enough."
            }
        }
    }
}

/// Calibration state as the core sees it. The app maps this onto the ui spec's
/// `CalibrationState` (unavailable / calibrating / calibrated / stale / failed).
public enum CalibrationStatus: Sendable, Equatable {
    case unavailable
    case calibrating(progress: Double)
    case calibrated(BiasEstimate)
    case stale(BiasEstimate, reason: CalibrationStaleReason)
    case failed(CalibrationFailure)

    public var estimate: BiasEstimate? {
        switch self {
        case .calibrated(let e):    return e
        case .stale(let e, _):      return e
        default:                    return nil
        }
    }

    /// Bias usable for estimation? A stale estimate is still better than none —
    /// it is used, with inflated uncertainty, rather than discarded.
    public var usableBias: Vector3? { estimate?.bias }
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
        /// Collecting; `elapsed` of `required` seconds of continuous quiet.
        case collecting(elapsed: TimeInterval, required: TimeInterval)
        /// Progress was reset by a gate closure. Carries the reason.
        case rejected(ValidityGate.Reason)
        case done(BiasEstimate)
        case failed(CalibrationFailure)

        public var fraction: Double {
            switch self {
            case .collecting(let elapsed, let required):
                return required > 0 ? min(1, max(0, elapsed / required)) : 0
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
        // Calibration's gate runs on the WIDER specific-force band. See
        // `Config.calibrationSpecificForceLow` for the full argument: that band is an
        // accelerometer proxy for stillness here and never enters the gyro mean, so
        // widening it costs the estimate under 0.001 deg/s — whereas widening the
        // estimator's copy would let 0.3 g of thrust pass as "at rest" and feed
        // 16.7 deg of phantom tilt into the ESKF's gravity update. The rotation-rate
        // ceiling and dwell are shared unchanged, and `biasSigmaLimit` remains the
        // real accuracy backstop on the finished mean.
        var gateConfig = config
        gateConfig.gateSpecificForceLow = config.calibrationSpecificForceLow
        gateConfig.gateSpecificForceHigh = config.calibrationSpecificForceHigh
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
                               required: config.biasCalibrationDuration)
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
            firstSampleTime = sample.time
            lastAccumulateTime = sample.time
            return .collecting(elapsed: 0, required: config.biasCalibrationDuration)
        }

        accumulate(sample.rotationRate)
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
        let requiredSamples = Int(config.biasCalibrationDuration
                                  * config.nominalSampleRate * 0.5)
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
                               required: config.biasCalibrationDuration)
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

    private mutating func accumulate(_ v: Vector3) {
        n += 1
        let delta = v - mean
        mean = mean + delta / Double(n)
        let delta2 = v - mean
        m2 = m2 + Vector3(delta.x * delta2.x, delta.y * delta2.y, delta.z * delta2.z)
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
                                    thermalStateAtCapture: thermalState)
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

/// Tracks whether a held estimate is still fresh, and how much confidence it has
/// lost. Pure function of time and thermal state, so replay reproduces exactly
/// the confidence the rider saw.
public struct CalibrationTracker: Sendable {
    private let config: Config
    public private(set) var status: CalibrationStatus
    private var diag: DiagnosticEmitter

    public init(config: Config, status: CalibrationStatus = .unavailable,
                sink: DiagnosticSink? = nil) {
        self.config = config
        self.status = status
        self.diag = DiagnosticEmitter(sink: sink, category: "caltrack")
    }

    public mutating func adopt(_ estimate: BiasEstimate) {
        status = .calibrated(estimate)
        diag.always(time: estimate.monotonicTime, level: .info,
                    message: "caltrack adopt",
                    values: [
                        "biasStaleAfter": config.biasStaleAfter,
                        "thermalStateAtCapture": Double(estimate.thermalStateAtCapture),
                        "sampleCount": Double(estimate.sampleCount),
                    ])
    }

    public mutating func invalidate(_ reason: CalibrationStaleReason) {
        let age = status.estimate?.monotonicTime
        if let estimate = status.estimate {
            status = .stale(estimate, reason: reason)
        } else {
            status = .unavailable
        }
        diag.always(time: age ?? 0, level: .info,
                    message: "caltrack invalidate " + reason.rawValue,
                    values: ["biasStaleAfter": config.biasStaleAfter])
    }

    /// Re-evaluates freshness at monotonic time `now`. Returns the current status.
    @discardableResult
    public mutating func update(now: TimeInterval,
                               thermalState: Int? = nil) -> CalibrationStatus {
        guard let estimate = status.estimate else { return status }

        let wasStale = { if case .stale = status { return true } else { return false } }()

        if let thermalState, thermalState > estimate.thermalStateAtCapture + 1 {
            status = .stale(estimate, reason: .thermalShift)
            if !wasStale {
                diag.always(time: now, level: .info,
                            message: "caltrack stale thermalShift",
                            values: [
                                "age": now - estimate.monotonicTime,
                                "biasStaleAfter": config.biasStaleAfter,
                                "thermalState": Double(thermalState),
                                "thermalStateAtCapture": Double(estimate.thermalStateAtCapture),
                            ])
            }
            return status
        }
        let age = now - estimate.monotonicTime
        if age > config.biasStaleAfter {
            status = .stale(estimate, reason: .aged)
            if !wasStale {
                diag.always(time: now, level: .info,
                            message: "caltrack stale aged",
                            values: [
                                "age": age,
                                "biasStaleAfter": config.biasStaleAfter,
                                "thermalStateAtCapture": Double(estimate.thermalStateAtCapture),
                            ])
            }
        }
        return status
    }

    /// Age in seconds at monotonic time `now`, or nil with no estimate.
    public func age(at now: TimeInterval) -> TimeInterval? {
        guard let estimate = status.estimate else { return nil }
        return now - estimate.monotonicTime
    }

    /// Reported 1-sigma pitch error for a hypothetical hold, used for the
    /// confidence the UI shows. Grows with age, thermal state and hold length.
    public func projectedPitchSigma(at now: TimeInterval,
                                    holdDuration: TimeInterval) -> Double? {
        guard let estimate = status.estimate, let age = age(at: now) else { return nil }
        return estimate.projectedPitchSigma(age: age,
                                            holdDuration: holdDuration,
                                            config: config)
    }
}
