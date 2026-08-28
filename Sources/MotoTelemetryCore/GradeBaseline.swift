import Foundation

/// Removes road grade from the reported wheelie angle.
///
/// A wheelie is measured relative to the ROAD, not to the geoid. Riding up a 4%
/// incline tilts the bike 2.3 degrees before the front wheel leaves the ground, and
/// without a reference that shows up as a permanent offset on every run — flattering
/// uphill, punishing downhill.
///
/// The reference is a slow low-pass over pitch, updated ONLY while the validity gate
/// is open. Freezing it while the gate is shut is the whole trick: with a 25 s time
/// constant, a baseline that kept updating through a 10 s hold would absorb roughly a
/// third of the wheelie into its own reference and quietly report a smaller angle.
/// The gate is shut for the entire duration of a wheelie, so the reference cannot
/// chase the event it is supposed to measure.
///
/// The barometer is deliberately not used for this in v1: the dynamic-pressure
/// coefficient needs a per-mount calibration procedure that does not exist yet, and
/// the gate-open pitch reference is sufficient. The channel is still logged.
public struct GradeBaseline: Stage {
    public struct Input {
        public var pitch: Double
        public var gateOpen: Bool
        public var time: TimeInterval
        /// Diagnostic-only breakdown of why the caller did/didn't allow adaptation.
        /// The caller (Pipeline) computes `gateOpen` as `verdict.isOpen &&
        /// !eventActive && nearLevel`; passing the three parts lets the grade log
        /// name which one blocked an adapt without the baseline re-deriving them.
        /// Purely additive: defaults reproduce the pre-diagnostics call sites.
        public var verdictOpen: Bool?
        public var eventActive: Bool?
        public var nearLevel: Bool?

        public init(pitch: Double, gateOpen: Bool, time: TimeInterval,
                    verdictOpen: Bool? = nil,
                    eventActive: Bool? = nil,
                    nearLevel: Bool? = nil) {
            self.pitch = pitch
            self.gateOpen = gateOpen
            self.time = time
            self.verdictOpen = verdictOpen
            self.eventActive = eventActive
            self.nearLevel = nearLevel
        }
    }

    private let timeConstant: TimeInterval
    private var value: Double?
    private var lastTime: TimeInterval?
    private var gateOpenSamples = 0
    private var diag: DiagnosticEmitter

    /// Current grade estimate, radians. Nil until the gate has ever opened.
    public var grade: Double? { value }
    /// How many gate-open samples have contributed. A baseline built from a handful
    /// of samples is not yet trustworthy, and the caller can see that.
    public var sampleCount: Int { gateOpenSamples }

    public init(config: Config, sink: DiagnosticSink? = nil) {
        self.timeConstant = config.baselineTimeConstant
        self.diag = DiagnosticEmitter(sink: sink, category: "grade")
    }

    /// Returns the grade-corrected pitch for this sample.
    public mutating func process(_ input: Input) -> Double? {
        defer { lastTime = input.time }
        emitDiagnostics(input)

        guard input.gateOpen else {
            // Frozen. Still correct the output using the last known grade.
            return input.pitch - (value ?? 0)
        }

        gateOpenSamples += 1

        guard let current = value, let previous = lastTime else {
            // First gate-open sample seeds the baseline outright: a first-order
            // filter starting from zero would take a minute to reach a real grade.
            value = input.pitch
            return 0
        }

        let dt = max(0, input.time - previous)
        // Standard first-order low-pass in continuous form, so the behaviour does
        // not depend on sample rate.
        let alpha = timeConstant > 0 ? 1 - exp(-dt / timeConstant) : 1
        let updated = current + alpha * (input.pitch - current)
        value = updated
        return input.pitch - updated
    }

    public mutating func reset() {
        value = nil
        lastTime = nil
        gateOpenSamples = 0
    }

    // MARK: - Diagnostics

    /// Emits adapt/freeze transitions with baseline deg, pitch deg, and which of
    /// the three adapt conditions blocked adaptation. The state key is the
    /// adapt/freeze decision plus the blocking condition, so a change in WHY it is
    /// frozen is a transition, not just a heartbeat.
    private mutating func emitDiagnostics(_ input: Input) {
        let adapting = input.gateOpen
        // Name the first blocking condition, in the same order the Pipeline ANDs
        // them. Only meaningful when the caller supplied the breakdown.
        let blocked: String
        if adapting {
            blocked = "none"
        } else if let vo = input.verdictOpen, !vo {
            blocked = "gateClosed"
        } else if let ea = input.eventActive, ea {
            blocked = "eventActive"
        } else if let nl = input.nearLevel, !nl {
            blocked = "notNearLevel"
        } else {
            blocked = "gateClosed"
        }
        let degrees = 180.0 / .pi
        diag.emit(adapting ? "adapt" : "freeze:" + blocked,
                  time: input.time,
                  message: adapting ? "grade adapt" : "grade freeze",
                  values: [
                    "baselineDeg": (value ?? 0) * degrees,
                    "pitchDeg": input.pitch * degrees,
                    "adapting": adapting ? 1 : 0,
                    "gateOpenSamples": Double(gateOpenSamples),
                    "blockGateClosed": (input.verdictOpen.map { $0 ? 0 : 1 }) ?? -1,
                    "blockEventActive": (input.eventActive.map { $0 ? 1 : 0 }) ?? -1,
                    "blockNotNearLevel": (input.nearLevel.map { $0 ? 0 : 1 }) ?? -1,
                  ])
    }
}
