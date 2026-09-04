import Foundation

/// Detects wheelie events via a 4-state hysteresis machine with interpolated boundaries.
///
/// The hysteresis prevents chattering at the boundary and the dwell requirements
/// prevent false triggers from bumps. Thresholds are NOT written as literals here on
/// purpose: they come from `Config.eventEntryPitch` / `eventExitPitch` (currently 10°
/// entry, 7° exit) and a previous version of this comment hardcoded "8° entry, 5°
/// exit", which stayed wrong across the change that moved them. Read the Config.
///
/// Boundaries are linearly interpolated between the two bracketing samples so
/// onset/end times are not quantized to the sample clock — which matters when
/// computing sub-second durations.
///
/// ## Two things a caller must do
/// 1. Call `finish()` when the stream ends. An event still open at the last sample
///    is otherwise never emitted, and the rider's longest hold silently vanishes.
/// 2. Feed a contiguous stream, or accept that dwells restart across a gap larger
///    than `Config.maxSampleGap`. A dwell asserts pitch was SUSTAINED; a gap is the
///    absence of evidence for that, so continuing to count it would let one
///    post-gap sample satisfy a dwell that exists to require many.
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
    private let maxSampleGap: TimeInterval

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

    private var diag: DiagnosticEmitter

    public init(config: Config = Config(), debugBypassMinDuration: Bool = false,
                sink: DiagnosticSink? = nil) {
        self.entryPitch = config.eventEntryPitch
        self.exitPitch = config.eventExitPitch
        self.entryDwell = config.eventEntryDwell
        self.exitDwell = config.eventExitDwell
        self.minDuration = config.eventMinDuration
        self.entryPitchRate = config.eventEntryPitchRate
        self.maxSampleGap = config.maxSampleGap
        self.debugBypassMinDuration = debugBypassMinDuration
        self.diag = DiagnosticEmitter(sink: sink, category: "event")
    }

    /// Feed one pipeline output sample. Returns a transition when a boundary is
    /// crossed and confirmed; nil otherwise.
    public mutating func process(time: TimeInterval, pitch: Double, pitchRate: Double) -> Transition? {
        defer {
            prevPitch = pitch
            prevTime = time
        }

        let before = state
        let transition: Transition?
        switch state {
        case .idle:
            transition = processIdle(time: time, pitch: pitch, pitchRate: pitchRate)
        case .arming:
            transition = processArming(time: time, pitch: pitch, pitchRate: pitchRate)
        case .active:
            transition = processActive(time: time, pitch: pitch, pitchRate: pitchRate)
        case .disarming:
            transition = processDisarming(time: time, pitch: pitch, pitchRate: pitchRate)
        }
        emitState(before: before, time: time, pitch: pitch, pitchRate: pitchRate)
        return transition
    }

    /// State-machine transitions with pitch deg, pitchRate deg/s, and the
    /// entry/exit thresholds and dwells being compared against.
    private mutating func emitState(before: State,
                                    time: TimeInterval,
                                    pitch: Double,
                                    pitchRate: Double) {
        let degrees = 180.0 / .pi
        diag.emit(stateName(state),
                  time: time,
                  message: "event " + stateName(state),
                  values: [
                    "pitchDeg": pitch * degrees,
                    "pitchRateDegPerSec": pitchRate * degrees,
                    "entryPitchDeg": entryPitch * degrees,
                    "exitPitchDeg": exitPitch * degrees,
                    "entryPitchRateDegPerSec": entryPitchRate * degrees,
                    "entryDwell": entryDwell,
                    "exitDwell": exitDwell,
                    "minDuration": minDuration,
                    "changed": before == state ? 0 : 1,
                  ])
    }

    private func stateName(_ s: State) -> String {
        switch s {
        case .idle:      return "idle"
        case .arming:    return "arming"
        case .active:    return "active"
        case .disarming: return "disarming"
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

        if isDiscontinuous(at: time) {
            // The stream lost continuity mid-dwell. Without this the jump in sample
            // time would satisfy `time - armingStartTime >= entryDwell` on a single
            // post-gap sample, committing an event off one reading and defeating the
            // debounce entirely. Restart the dwell and re-take the onset from here,
            // since a crossing interpolated across a gap is not a measurement.
            armingStartTime = time
            interpolatedOnsetTime = time
            sawHighRate = pitchRate > entryPitchRate
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

        if isDiscontinuous(at: time) {
            // Same reasoning as the entry dwell, with the opposite failure: a gap
            // would end the event on one post-gap sample, truncating a hold that may
            // still have been in progress across the missing span.
            disarmingStartTime = time
            interpolatedEndTime = time
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

    // MARK: - End of stream

    /// Closes an event that is still open when the sample stream ends, and returns
    /// its transition. Call exactly once, after the last `process(...)`.
    ///
    /// Without this an event open at the final sample is never emitted at all: the
    /// only path that produces `.end`/`.discarded` is the exit dwell elapsing inside
    /// `processDisarming`, which cannot happen if there are no more samples. A ride
    /// stopped while still lofted, or a log that ends mid-wheelie, therefore lost the
    /// event entirely — and since the longest holds are the ones most likely to be
    /// interrupted, the loss was biased toward the rider's best runs.
    ///
    /// The event is closed at the best evidence available:
    /// - `.disarming` — pitch had already dropped below exit, so the interpolated
    ///   crossing is a real measurement; use it.
    /// - `.active` — pitch never came down, so the event is truncated at the last
    ///   sample seen. That understates a hold still in progress, which is the right
    ///   direction to be wrong in.
    /// - `.arming` — no onset was ever emitted, so there is no event to close.
    ///
    /// `minDuration` still applies: a stream ending 200 ms into a lift does not
    /// promote it to a wheelie.
    public mutating func finish() -> Transition? {
        let endTime: TimeInterval
        switch state {
        case .idle, .arming:
            state = .idle
            return nil
        case .disarming:
            endTime = interpolatedEndTime
        case .active:
            guard let last = prevTime else {
                state = .idle
                return nil
            }
            endTime = last
        }

        state = .idle
        let duration = endTime - onsetTime
        if duration < minDuration && !debugBypassMinDuration {
            return .init(kind: .discarded(duration: duration), confidence: confidence)
        }
        return .init(kind: .end(endTime), confidence: confidence)
    }

    // MARK: - Interpolation

    /// Whether the step onto `time` skipped more than `maxSampleGap` of sample time.
    /// True on a real discontinuity only — never on the first sample, where there is
    /// no step to measure.
    private func isDiscontinuous(at time: TimeInterval) -> Bool {
        guard let pTime = prevTime else { return false }
        return time - pTime > maxSampleGap
    }

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
