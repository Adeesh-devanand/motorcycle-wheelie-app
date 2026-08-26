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

    public init(config: Config,
                bikeProfileID: UUID,
                thermalState: Int = 0) {
        self.config = config
        self.bikeProfileID = bikeProfileID
        self.thermalState = thermalState
        self.gate = ValidityGate(config: config)
        self.vibration = HighFrequencyIndicator(config: config)
    }

    public mutating func process(_ sample: IMUSample) -> Progress? {
        guard !finished else { return nil }

        if attemptStart == nil { attemptStart = sample.time }
        vibration.process(sample)

        // A saturated sample never enters a bias estimate.
        guard !sample.saturated else {
            resetAccumulation()
            lastReason = .saturated
            return checkAttemptWindow(at: sample.time)
                ?? .rejected(.saturated)
        }

        guard let verdict = gate.process(sample) else { return nil }

        guard verdict.isOpen else {
            if n > 0 { resetAccumulation() }
            lastReason = verdict.reason

            // Explain the rejection when vibration is what caused it. The gate is
            // instantaneous and its band is +/-0.03 g, so a buzzing mount trips
            // `specificForceOutOfBand` long before any RMS threshold could fire.
            // Without this branch the rider is told the bike is not level and
            // still, which is true and useless.
            if verdict.reason == .specificForceOutOfBand || verdict.reason == .saturated {
                let spread = vibration.magnitudeStdDev
                if spread > config.calibrationVibrationThreshold {
                    finished = true
                    return .failed(.vibrationTooHigh(
                        rms: spread, limit: config.calibrationVibrationThreshold))
                }
            }

            return checkAttemptWindow(at: sample.time) ?? .rejected(verdict.reason)
        }

        // Also checked while the gate is OPEN: vibration small enough to stay
        // inside the band still biases the mean, and a bias averaged over it is
        // quietly wrong rather than obviously wrong.
        //
        // Uses magnitudeStdDev, not the high-passed RMS. The bike is stationary
        // here, so true |f| is a constant g and all spread is vibration — which
        // makes this detector frequency-agnostic. That matters because the
        // high-pass is blind to exactly the cases we care about: 83 Hz aliases to
        // 17 Hz, below its corner, and 100 Hz aliases to DC.
        let spread = vibration.magnitudeStdDev
        if spread > config.calibrationVibrationThreshold {
            finished = true
            return .failed(.vibrationTooHigh(
                rms: spread, limit: config.calibrationVibrationThreshold))
        }

        accumulate(sample.rotationRate)
        let start = firstSampleTime ?? sample.time
        firstSampleTime = start
        let elapsed = sample.time - start

        guard elapsed >= config.biasCalibrationDuration else {
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

    private mutating func accumulate(_ v: Vector3) {
        n += 1
        let delta = v - mean
        mean = mean + delta / Double(n)
        let delta2 = v - mean
        m2 = m2 + Vector3(delta.x * delta2.x, delta.y * delta2.y, delta.z * delta2.z)
    }

    private mutating func resetAccumulation() {
        n = 0
        mean = .zero
        m2 = .zero
        firstSampleTime = nil
        gate.reset()
    }

    private func finish(at time: TimeInterval) -> Progress {
        guard n > 1 else {
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

        let limit = config.biasSigmaLimit
        for (axis, value) in [(Axis.x, sigma.x), (.y, sigma.y), (.z, sigma.z)] {
            if value > limit {
                return .failed(.sigmaTooHigh(axis: axis, sigma: value, limit: limit))
            }
        }

        return .done(BiasEstimate(bias: mean,
                                  sigma: sigma,
                                  sampleCount: n,
                                  monotonicTime: time,
                                  bikeProfileID: bikeProfileID,
                                  thermalStateAtCapture: thermalState))
    }

    /// Abandon and restart, e.g. the rider tapped retry.
    public mutating func restart() {
        resetAccumulation()
        vibration.reset()
        attemptStart = nil
        lastReason = .noData
        finished = false
    }
}

/// Tracks whether a held estimate is still fresh, and how much confidence it has
/// lost. Pure function of time and thermal state, so replay reproduces exactly
/// the confidence the rider saw.
public struct CalibrationTracker: Sendable {
    private let config: Config
    public private(set) var status: CalibrationStatus

    public init(config: Config, status: CalibrationStatus = .unavailable) {
        self.config = config
        self.status = status
    }

    public mutating func adopt(_ estimate: BiasEstimate) {
        status = .calibrated(estimate)
    }

    public mutating func invalidate(_ reason: CalibrationStaleReason) {
        if let estimate = status.estimate {
            status = .stale(estimate, reason: reason)
        } else {
            status = .unavailable
        }
    }

    /// Re-evaluates freshness at monotonic time `now`. Returns the current status.
    @discardableResult
    public mutating func update(now: TimeInterval,
                               thermalState: Int? = nil) -> CalibrationStatus {
        guard let estimate = status.estimate else { return status }

        if let thermalState, thermalState > estimate.thermalStateAtCapture + 1 {
            status = .stale(estimate, reason: .thermalShift)
            return status
        }
        let age = now - estimate.monotonicTime
        if age > config.biasStaleAfter {
            status = .stale(estimate, reason: .aged)
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
