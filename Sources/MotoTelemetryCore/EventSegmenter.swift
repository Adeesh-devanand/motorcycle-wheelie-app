import Foundation

/// Detects wheelie events via a 4-state hysteresis machine with interpolated boundaries.
///
/// The hysteresis (8° entry, 5° exit) prevents chattering at boundary, and the
/// dwell requirements prevent false triggers from bumps. Boundaries are linearly
/// interpolated between the two bracketing samples so onset/end times are not
/// quantized to the sample clock — which matters when computing sub-second durations.
public struct EventSegmenter {
    public enum State: Sendable, Equatable {
        case idle
        case arming
        case active
        case disarming
    }

    public enum Confidence: Sendable, Equatable {
        /// Pitch rate exceeded eventEntryPitchRate during arming — a sharp lift.
        case confident
        /// Pitch crossed the threshold but rate never exceeded the confidence
        /// signal. A slow deliberate lift still registers; the weaker label tells
        /// downstream that GNSS cross-check should be weighted more heavily.
        case weak
    }

    public struct Transition: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case onset(TimeInterval)
            case end(TimeInterval)
            case discarded(duration: TimeInterval)
        }
        public var kind: Kind
        public var confidence: Confidence
    }

    private let entryPitch: Double
    private let exitPitch: Double
    private let entryDwell: TimeInterval
    private let exitDwell: TimeInterval
    private let minDuration: TimeInterval
    private let entryPitchRate: Double

    /// When true, events shorter than minDuration are emitted rather than discarded.
    public var debugBypassMinDuration: Bool

    public private(set) var state: State = .idle

    // Arming state
    private var armingStartTime: TimeInterval = 0
    private var sawHighRate: Bool = false
    /// The interpolated time the threshold was actually crossed, computed at
    /// the moment pitch first exceeds entryPitch using the two bracketing samples.
    private var interpolatedOnsetTime: TimeInterval = 0

    // Active state
    private var onsetTime: TimeInterval = 0
    private var confidence: Confidence = .weak

    // Disarming state
    private var disarmingStartTime: TimeInterval = 0
    /// The interpolated time pitch crossed below exitPitch, computed when
    /// entering the disarming state.
    private var interpolatedEndTime: TimeInterval = 0

    // Previous sample for interpolation
    private var prevPitch: Double?
    private var prevTime: TimeInterval?

    public init(config: Config = Config(), debugBypassMinDuration: Bool = false) {
        self.entryPitch = config.eventEntryPitch
        self.exitPitch = config.eventExitPitch
        self.entryDwell = config.eventEntryDwell
        self.exitDwell = config.eventExitDwell
        self.minDuration = config.eventMinDuration
        self.entryPitchRate = config.eventEntryPitchRate
        self.debugBypassMinDuration = debugBypassMinDuration
    }

    /// Feed one pipeline output sample. Returns a transition when a boundary is
    /// crossed and confirmed; nil otherwise.
    public mutating func process(time: TimeInterval, pitch: Double, pitchRate: Double) -> Transition? {
        defer {
            prevPitch = pitch
            prevTime = time
        }

        switch state {
        case .idle:
            return processIdle(time: time, pitch: pitch, pitchRate: pitchRate)
        case .arming:
            return processArming(time: time, pitch: pitch, pitchRate: pitchRate)
        case .active:
            return processActive(time: time, pitch: pitch, pitchRate: pitchRate)
        case .disarming:
            return processDisarming(time: time, pitch: pitch, pitchRate: pitchRate)
        }
    }

    // MARK: - State handlers

    private mutating func processIdle(time: TimeInterval, pitch: Double, pitchRate: Double) -> Transition? {
        if pitch > entryPitch {
            state = .arming
            armingStartTime = time
            sawHighRate = pitchRate > entryPitchRate
            // Interpolate the crossing between the previous sample and this one —
            // this is the true onset time if dwell is subsequently met.
            interpolatedOnsetTime = interpolatedCrossingTime(threshold: entryPitch,
                                                             currentTime: time,
                                                             currentPitch: pitch)
        }
        return nil
    }

    private mutating func processArming(time: TimeInterval, pitch: Double, pitchRate: Double) -> Transition? {
        if pitchRate > entryPitchRate {
            sawHighRate = true
        }

        if pitch <= entryPitch {
            // Dropped below entry before dwell was met — reset.
            state = .idle
            return nil
        }

        if time - armingStartTime >= entryDwell {
            // Dwell met: transition to active. Onset was interpolated at the
            // moment pitch first crossed entryPitch (stored in processIdle).
            state = .active
            confidence = sawHighRate ? .confident : .weak
            onsetTime = interpolatedOnsetTime
            return .init(kind: .onset(onsetTime), confidence: confidence)
        }
        return nil
    }

    private mutating func processActive(time: TimeInterval, pitch: Double, pitchRate: Double) -> Transition? {
        if pitch < exitPitch {
            state = .disarming
            disarmingStartTime = time
            // Interpolate the exit crossing between previous sample and this one.
            interpolatedEndTime = interpolatedCrossingTime(threshold: exitPitch,
                                                           currentTime: time,
                                                           currentPitch: pitch)
        }
        return nil
    }

    private mutating func processDisarming(time: TimeInterval, pitch: Double, pitchRate: Double) -> Transition? {
        if pitch >= exitPitch {
            // Jitter: pitch rose back above exit — return to active.
            state = .active
            return nil
        }

        if time - disarmingStartTime >= exitDwell {
            // Exit dwell met: event ends. The end time was interpolated at the
            // first crossing below exitPitch (stored when entering disarming).
            let endTime = interpolatedEndTime
            state = .idle

            let duration = endTime - onsetTime
            if duration < minDuration && !debugBypassMinDuration {
                return .init(kind: .discarded(duration: duration), confidence: confidence)
            }
            return .init(kind: .end(endTime), confidence: confidence)
        }
        return nil
    }

    // MARK: - Interpolation

    /// Interpolates the time at which pitch crossed the threshold, using the
    /// previous and current samples as brackets. Falls back to `currentTime`
    /// when no previous sample exists (first sample edge case).
    private func interpolatedCrossingTime(threshold: Double,
                                          currentTime: TimeInterval,
                                          currentPitch: Double) -> TimeInterval {
        guard let pPitch = prevPitch, let pTime = prevTime else {
            return currentTime
        }
        let dPitch = currentPitch - pPitch
        // Avoid division by zero on flat segments — snap to current time.
        guard abs(dPitch) > 1e-15 else { return currentTime }
        let u = (threshold - pPitch) / dPitch
        let clamped = min(max(u, 0), 1)
        return pTime + clamped * (currentTime - pTime)
    }
}
