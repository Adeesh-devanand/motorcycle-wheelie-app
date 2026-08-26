import Foundation

/// The output of the cue engine: a pure decision that the renderer maps to sound.
/// Returning a value (rather than producing audio directly) is what lets CLI replay
/// print a cue timeline and tests run with no audio hardware.
public struct CueState: Codable, Sendable, Equatable {
    public enum Tone: String, Codable, Sendable, Equatable {
        /// No cue active.
        case silent
        /// Approaching the target's upper bound — frequency rises with urgency.
        case approach
        /// Pitch rate exceeds loopOutPitchRate — distinct timbre, preempts approach.
        /// Must be a different waveform/envelope, not merely a higher pitch.
        case loopOut
    }

    public var tone: Tone
    /// 0…1 urgency; renderer maps to frequency and amplitude envelope.
    public var urgency: Double
    /// Seconds to the target's upper bound, nil when not closing or already past.
    public var timeToThreshold: TimeInterval?

    public init(tone: Tone = .silent, urgency: Double = 0, timeToThreshold: TimeInterval? = nil) {
        self.tone = tone
        self.urgency = urgency
        self.timeToThreshold = timeToThreshold
    }
}

/// Pure decision engine for the predictive audio cue. Produces a CueState per sample;
/// it does NOT produce sound — that separation is what makes the pipeline testable
/// and replayable offline.
///
/// Logic (design §12):
///   1. ttt from AxisElevation.timeToThreshold against upper bound — nil means
///      not closing (slow creep stays silent, which is the desired UX).
///   2. Lead L = timeToThresholdWarn + audioLatencyCompensation (overrideable).
///   3. .approach when ttt ≤ L with urgency = 1 - ttt/L.
///   4. pitchRate > loopOutPitchRate → .loopOut PREEMPTS .approach.
///   5. Hysteresis: sounding tone persists until its trigger condition has been
///      false for cueReleaseTime — without this the tone chatters on/off at the
///      boundary crossing frequency, which is unusable at speed.
public struct CueEngine {
    /// Configuration parameters taken as init args (not from Config directly)
    /// so this type stays pure and independently testable.
    private let timeToThresholdWarn: TimeInterval
    private let audioLatencyCompensation: TimeInterval
    private let loopOutPitchRate: Double       // rad/s
    private let cueReleaseTime: TimeInterval
    private let angleTargetUpper: Double       // rad — the cue fires on this bound

    // Hysteresis tracking
    private var currentTone: CueState.Tone = .silent
    private var conditionFalseSince: TimeInterval?
    private var lastSampleTime: TimeInterval = 0

    /// The computed lead time: timeToThresholdWarn + latency compensation.
    public var leadTime: TimeInterval {
        timeToThresholdWarn + audioLatencyCompensation
    }

    /// - Parameters:
    ///   - angleTargetUpper: Upper bound of the angle target range (radians).
    ///   - timeToThresholdWarn: Base warning time before threshold (default 0.4 s).
    ///   - audioLatencyCompensation: Added to warning time to compensate output
    ///     latency (default 0.05 s, overridden by measured route latency).
    ///   - loopOutPitchRate: Pitch rate threshold for loop-out warning (rad/s, default 60°/s).
    ///   - cueReleaseTime: How long a tone persists after its condition goes false (default 0.15 s).
    public init(
        angleTargetUpper: Double,
        timeToThresholdWarn: TimeInterval = 0.4,
        audioLatencyCompensation: TimeInterval = 0.05,
        loopOutPitchRate: Double = 60.0 * .pi / 180.0,
        cueReleaseTime: TimeInterval = 0.15
    ) {
        self.angleTargetUpper = angleTargetUpper
        self.timeToThresholdWarn = timeToThresholdWarn
        self.audioLatencyCompensation = audioLatencyCompensation
        self.loopOutPitchRate = loopOutPitchRate
        self.cueReleaseTime = cueReleaseTime
    }

    /// Process one sample and return the cue decision.
    ///
    /// - Parameters:
    ///   - pitch: Current pitch angle in radians.
    ///   - pitchRate: Current pitch rate in rad/s (positive = nose rising).
    ///   - time: Monotonic sample timestamp.
    /// - Returns: The cue state to be rendered (or logged).
    public mutating func process(pitch: Double, pitchRate: Double, time: TimeInterval) -> CueState {
        lastSampleTime = time

        let L = leadTime

        // Step 4: loopOut preempts everything — checked first.
        let loopOutActive = pitchRate > loopOutPitchRate

        // Step 1–3: approach via time-to-threshold.
        let ttt = AxisElevation.timeToThreshold(
            current: pitch, rate: pitchRate, target: angleTargetUpper
        )
        let approachActive = ttt.map { $0 <= L } ?? false

        // Determine the instantaneous desired tone (before hysteresis).
        let desiredTone: CueState.Tone
        if loopOutActive {
            desiredTone = .loopOut
        } else if approachActive {
            desiredTone = .approach
        } else {
            desiredTone = .silent
        }

        // Step 5: hysteresis — a sounding tone persists until its condition
        // has been FALSE for cueReleaseTime continuously.
        let outputTone: CueState.Tone
        if desiredTone != .silent {
            // Condition is active — reset hysteresis, adopt the desired tone.
            conditionFalseSince = nil
            currentTone = desiredTone
            outputTone = desiredTone
        } else if currentTone != .silent {
            // Was sounding but condition just went false — start or continue holdoff.
            if let falseSince = conditionFalseSince {
                if time - falseSince >= cueReleaseTime {
                    // Held off long enough — release.
                    currentTone = .silent
                    conditionFalseSince = nil
                    outputTone = .silent
                } else {
                    // Still within holdoff — keep the old tone.
                    outputTone = currentTone
                }
            } else {
                // First sample where condition went false.
                conditionFalseSince = time
                outputTone = currentTone
            }
        } else {
            outputTone = .silent
        }

        // Compute urgency for approach (0 for loopOut/silent, or based on ttt).
        let urgency: Double
        switch outputTone {
        case .approach:
            if let t = ttt {
                urgency = max(0, min(1, 1.0 - t / L))
            } else {
                urgency = 1.0
            }
        case .loopOut:
            urgency = 1.0
        case .silent:
            urgency = 0
        }

        return CueState(tone: outputTone, urgency: urgency, timeToThreshold: ttt)
    }
}
