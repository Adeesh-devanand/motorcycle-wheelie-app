import Foundation

/// One structured diagnostic record. Carries the SAMPLE's time, never a wall
/// clock — the core is a pure function over a time-ordered stream, so a log line
/// must be reproducible bit-for-bit on replay. See the logging contract.
public struct DiagnosticEvent: Sendable {
    public enum Level: String, Sendable, Codable { case trace, debug, info, warn, error }
    public var time: TimeInterval          // sample time, monotonic; NEVER Date()
    public var level: Level
    public var category: String            // "gate","bias","eskf","pipe","event","grade","caltrack","sensor","cal","rec","live","app","audio"
    public var message: String             // short + STABLE (greppable); numbers go in `values`
    public var values: [String: Double]    // the measured value AND the threshold it was compared against
    public init(time: TimeInterval, level: Level, category: String,
                message: String, values: [String: Double]) {
        self.time = time
        self.level = level
        self.category = category
        self.message = message
        self.values = values
    }
}

/// The sink seam. Agent A creates it; the app-side sink (agent B) implements it
/// as a file writer, and every core stage takes `sink: DiagnosticSink? = nil` as
/// a defaulted init parameter so all existing call sites stay silent and compile
/// untouched.
public protocol DiagnosticSink: AnyObject, Sendable {
    func emit(_ event: DiagnosticEvent)
}

/// The default: emit nowhere. Used wherever no sink was supplied, so a stage
/// never needs to branch on the presence of a sink.
public final class NoopDiagnosticSink: DiagnosticSink {
    public init() {}
    public func emit(_ event: DiagnosticEvent) {}
}

/// Centralises the one rate-discipline rule the whole package obeys:
///
/// > Emit on **transition** (the categorical outcome changed), plus a **1 Hz
/// > heartbeat** carrying the current numeric values.
///
/// A value type so a stage can hold one per channel without reference-sharing
/// surprises, and so a stage with a nil sink stays a no-op with no allocation.
/// The heartbeat interval is tracked off SAMPLE TIME, never a wall clock, so
/// replay reproduces exactly the same log the rider's device produced.
///
/// Usage inside a stage's `process`:
///
///     emitter.event(state, time: t, level: .info, message: "gate open",
///                   values: [...]) { $0 == $1 }
///
/// `event` fires the sink when EITHER the discriminator changed since the last
/// emitted event OR at least `heartbeatInterval` of sample time has elapsed. The
/// discriminator is compared with the caller-supplied `equal` closure so a stage
/// can key transitions off just the categorical part (e.g. a reason enum) while
/// still carrying live numbers in `values`.
public struct DiagnosticEmitter: Sendable {
    /// nil means "logging off": every call is a cheap no-op.
    public let sink: DiagnosticSink?
    public let category: String
    /// Sample-time seconds between heartbeats while the discriminator is unchanged.
    public let heartbeatInterval: TimeInterval

    /// The last discriminator we emitted for, and the sample time we emitted it at.
    /// Both nil until the first emission.
    private var lastKey: String?
    private var lastEmitTime: TimeInterval?

    public init(sink: DiagnosticSink?,
                category: String,
                heartbeatInterval: TimeInterval = 1.0) {
        self.sink = sink
        self.category = category
        self.heartbeatInterval = heartbeatInterval
    }

    /// Emit iff the discriminator changed OR a heartbeat interval of sample time
    /// has elapsed. `key` is the categorical discriminator as a stable string;
    /// pass the reason/state name, NOT the numbers (numbers live in `values` and
    /// never gate emission). Returns true when an event was emitted.
    @discardableResult
    public mutating func emit(_ key: String,
                              time: TimeInterval,
                              level: DiagnosticEvent.Level = .info,
                              message: String,
                              values: [String: Double]) -> Bool {
        guard let sink else { return false }

        let changed = (key != lastKey)
        let heartbeatDue: Bool = {
            guard let last = lastEmitTime else { return true }
            return time - last >= heartbeatInterval
        }()

        guard changed || heartbeatDue else { return false }

        sink.emit(DiagnosticEvent(time: time, level: level, category: category,
                                  message: message, values: values))
        lastKey = key
        lastEmitTime = time
        return true
    }

    /// Force an event out regardless of transition/heartbeat state — for one-shot
    /// milestones (anchor acquired, calibration finished/failed) that must never
    /// be coalesced away. Does not disturb the heartbeat cadence of the ongoing
    /// channel, so a subsequent `emit` still heartbeats on its own schedule.
    public func always(time: TimeInterval,
                       level: DiagnosticEvent.Level = .info,
                       message: String,
                       values: [String: Double]) {
        sink?.emit(DiagnosticEvent(time: time, level: level, category: category,
                                   message: message, values: values))
    }
}
