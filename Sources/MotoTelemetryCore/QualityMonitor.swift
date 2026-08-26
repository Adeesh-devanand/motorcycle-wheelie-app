import Foundation

/// Vibration and data-quality monitoring.
///
/// Per the aliasing constraint, every iPhone sensor is capped at 100 Hz while
/// engine excitation lives at 30-200 Hz, so the excitation folds into the signal
/// band and the information is destroyed at sampling. Nothing here filters that
/// away — it cannot be filtered away. The job is to DETECT that the data is
/// corrupted and say so, so the rider fixes the mount instead of trusting a
/// number.

/// Flags describing what is wrong with a session or a run. Absence of flags is a
/// claim, so each one is set only where its evidence is measured.
public struct QualityFlags: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// A saturated IMU sample fell inside a detected event.
    public static let saturatedInEvent      = QualityFlags(rawValue: 1 << 0)
    /// The high-frequency indicator exceeded its threshold.
    public static let highVibration         = QualityFlags(rawValue: 1 << 1)
    /// Recorded in an RPM band the bike's vibration profile marks as aliasing.
    public static let aliasingSuspect       = QualityFlags(rawValue: 1 << 2)
    /// Achieved sample rate fell below 95% of nominal.
    public static let lowRate               = QualityFlags(rawValue: 1 << 3)
    /// A gap longer than the tolerated maximum occurred.
    public static let gapExceeded           = QualityFlags(rawValue: 1 << 4)
    /// Session was repaired after an interrupted write.
    public static let recovered             = QualityFlags(rawValue: 1 << 5)
    /// The backward pass could not run, so only live numbers exist.
    public static let smoothingUnavailable  = QualityFlags(rawValue: 1 << 6)
    /// The filter lost positive-definiteness and fell back to gyro integration.
    public static let estimatorDegraded     = QualityFlags(rawValue: 1 << 7)
    /// Reported uncertainty exceeded the limit, or any of the above applies.
    /// Excluded from personal bests.
    public static let lowConfidence         = QualityFlags(rawValue: 1 << 8)

    /// Flags that disqualify a run from personal bests and leaderboards.
    public static let disqualifying: QualityFlags =
        [.saturatedInEvent, .highVibration, .aliasingSuspect, .lowRate,
         .gapExceeded, .estimatorDegraded, .lowConfidence]

    public var isTrustworthy: Bool { isDisjoint(with: .disqualifying) }
}

/// One-pole high-pass over specific-force magnitude, whose windowed RMS is the
/// vibration indicator — plus a plain standard deviation of that magnitude, which
/// is the detector to use when the bike is stationary.
///
/// Deliberately not an FFT: the core has no Accelerate, and a scalar measure is
/// all that is needed to answer "is this mount shaking hard enough to ruin the
/// data". Identifying WHICH frequency is doing it requires audio at 44.1 kHz and
/// happens offline in `motolog fft`, because at 100 Hz the frequency itself is
/// unrecoverable.
///
/// ## The high-pass has a blind spot, by construction
/// A 20 Hz corner cannot see the worst aliasing cases. Engine excitation at 83 Hz
/// sampled at 100 Hz folds to |83 - 100| = 17 Hz, BELOW the corner, and is
/// attenuated by the very filter meant to catch it; a twin at 6000 rpm folds to
/// DC and is invisible outright. The aliased image lands wherever the arithmetic
/// puts it, so no fixed corner catches every case. This is the same physics that
/// makes aliasing unfixable in the first place, now applying to the detector.
///
/// Two consequences, both deliberate:
/// - When the bike is STATIONARY, use `magnitudeStdDev`. Nothing should be moving,
///   so any variation in |f| is vibration regardless of what frequency it aliased
///   from. This is the detector calibration uses.
/// - While RIDING, real pitch dynamics live at DC-3 Hz and cannot be separated
///   from vibration that aliased into that band. The honest detection channel
///   there is the once-per-bike vibration profile built from AUDIO, which is
///   sampled fast enough not to alias. The high-pass RMS below is a partial
///   signal only: useful, not sufficient.
public struct HighFrequencyIndicator {
    private let alpha: Double
    private let windowDuration: TimeInterval

    private var lastInput: Double?
    private var highPassed: Double = 0
    private var sumOfSquares: Double = 0
    private var magnitudeSum: Double = 0
    private var magnitudeSumOfSquares: Double = 0
    private var count: Int = 0
    private var windowStart: TimeInterval?

    /// Most recent completed window's high-passed RMS, m/s^2. Nil until one
    /// window closes.
    public private(set) var rms: Double?
    /// Largest high-passed RMS seen across all completed windows.
    public private(set) var peakRMS: Double = 0

    public init(cutoff: Double, sampleRate: Double, windowDuration: TimeInterval = 1.0) {
        // Standard one-pole high-pass coefficient.
        let dt = 1.0 / sampleRate
        self.alpha = 1.0 / (1.0 + 2.0 * .pi * cutoff * dt)
        self.windowDuration = windowDuration
    }

    public init(config: Config) {
        self.init(cutoff: config.highFreqCutoff, sampleRate: config.nominalSampleRate)
    }

    /// Feeds one sample. Returns the window's RMS when a window just closed.
    @discardableResult
    public mutating func process(_ sample: IMUSample) -> Double? {
        let magnitude = sample.specificForce.magnitude

        if let previous = lastInput {
            highPassed = alpha * (highPassed + magnitude - previous)
        }
        lastInput = magnitude

        sumOfSquares += highPassed * highPassed
        magnitudeSum += magnitude
        magnitudeSumOfSquares += magnitude * magnitude
        count += 1

        let start = windowStart ?? sample.time
        windowStart = start

        guard sample.time - start >= windowDuration, count > 0 else { return nil }

        let value = (sumOfSquares / Double(count)).squareRoot()
        rms = value
        peakRMS = max(peakRMS, value)
        sumOfSquares = 0
        magnitudeSum = 0
        magnitudeSumOfSquares = 0
        count = 0
        windowStart = sample.time
        return value
    }

    /// High-passed RMS of the window in progress. Subject to the blind spot above.
    public var instantaneousRMS: Double {
        guard count > 0 else { return 0 }
        return (sumOfSquares / Double(count)).squareRoot()
    }

    /// Standard deviation of |specific force| over the window in progress, m/s^2.
    ///
    /// THE stationary detector. On a bike that is not moving, the true |f| is a
    /// constant g, so every bit of spread is vibration — no matter which frequency
    /// it aliased down from, including DC. Frequency-agnostic by construction,
    /// which is exactly what the high-pass cannot be.
    public var magnitudeStdDev: Double {
        guard count > 1 else { return 0 }
        let n = Double(count)
        let mean = magnitudeSum / n
        let variance = max(0, magnitudeSumOfSquares / n - mean * mean)
        return variance.squareRoot()
    }

    public mutating func reset() {
        lastInput = nil
        highPassed = 0
        sumOfSquares = 0
        magnitudeSum = 0
        magnitudeSumOfSquares = 0
        count = 0
        windowStart = nil
        rms = nil
    }
}
