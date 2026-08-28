import Foundation

/// Decides when the accelerometer may be trusted as a gravity reference.
///
/// This single gate closes three bugs at once: acceleration read as pitch,
/// a turn read as lean (centripetal force tilts apparent gravity — the same
/// reason pilots get "the leans" and need an artificial horizon), and braking
/// read as nose-down. Integrate the gyro during anything dynamic; only
/// re-anchor when quasi-static is provable.
public struct ValidityGate: Stage {
    public struct Verdict: Sendable, Equatable, Codable {
        public var isOpen: Bool
        /// How long the underlying condition has held continuously.
        public var heldFor: TimeInterval
        public var reason: Reason

        public init(isOpen: Bool, heldFor: TimeInterval, reason: Reason) {
            self.isOpen = isOpen
            self.heldFor = heldFor
            self.reason = reason
        }
    }

    /// Codable because every stage's output gets logged, not just the final angle:
    /// when a reading is wrong you need to see which stage first went wrong.
    public enum Reason: String, Sendable, Equatable, Codable {
        case open
        case specificForceOutOfBand
        case rotating
        case dwellNotMet
        case saturated
        case noData
    }

    private let config: Config
    private var conditionSince: TimeInterval?
    private var lastTime: TimeInterval?
    private var diag: DiagnosticEmitter
    /// When the band was first violated continuously, or nil while it holds. A
    /// violation shorter than `Config.gateCloseConfirm` never closes the gate — see
    /// that property for why duration rather than amplitude is the discriminator.
    private var violationSince: TimeInterval?

    public init(config: Config, sink: DiagnosticSink? = nil) {
        self.config = config
        self.diag = DiagnosticEmitter(sink: sink, category: "gate")
    }

    public mutating func process(_ sample: IMUSample) -> Verdict? {
        lastTime = sample.time
        let mag = sample.specificForce.magnitude
        let r = sample.rotationRate
        let limit = config.gateMaxRotationRate
        let verdict = evaluate(sample, mag: mag, r: r, limit: limit)
        // On every reason CHANGE emit old->new; same numbers on the 1 Hz
        // heartbeat, and the raw magnitude on EVERY heartbeat — this one log is
        // what proves or disproves why calibration cannot run on an idling bike.
        // `violationHeldFor` says how long the band has been breached, which is what
        // distinguishes a buzz spike from a real closure.
        let degPerSec = 180.0 / .pi
        diag.emit(verdict.reason.rawValue,
                  time: sample.time,
                  message: "gate " + verdict.reason.rawValue,
                  values: [
                    "specificForceMagnitude": mag,
                    "gateSpecificForceLow": config.gateSpecificForceLow,
                    "gateSpecificForceHigh": config.gateSpecificForceHigh,
                    "rotX": r.x * degPerSec,
                    "rotY": r.y * degPerSec,
                    "rotZ": r.z * degPerSec,
                    "gateMaxRotationRate": limit * degPerSec,
                    "heldFor": verdict.heldFor,
                    "gateDwell": config.gateDwell,
                    "violationHeldFor": violationSince.map { sample.time - $0 } ?? 0,
                    "gateCloseConfirm": config.gateCloseConfirm,
                    "saturated": sample.saturated ? 1 : 0,
                  ])
        return verdict
    }

    /// The gate's decision, factored out so instrumentation observes exactly the
    /// verdict returned without duplicating any control flow.
    /// Which band the RAW sample breaches, or nil when it is inside all of them.
    /// The single definition of "this sample looks quasi-static", shared by the
    /// gate's own decision and by `sampleWithinBand(_:)`.
    private func bandViolation(mag: Double, r: Vector3, limit: Double) -> Reason? {
        if mag < config.gateSpecificForceLow || mag > config.gateSpecificForceHigh {
            return .specificForceOutOfBand
        }
        if abs(r.x) >= limit || abs(r.y) >= limit || abs(r.z) >= limit {
            return .rotating
        }
        return nil
    }

    /// Whether THIS sample is individually trustworthy, independently of whether the
    /// gate is open.
    ///
    /// The two are genuinely different questions, and conflating them costs accuracy
    /// either way. `gateCloseConfirm` deliberately lets a violation shorter than
    /// ~60 ms pass without closing the gate, because engine excitation is exactly
    /// that — but such a sample must still never enter an average. One 20 deg/s spike
    /// among 600 quiet samples shifts the bias mean by 0.033 deg/s, most of the
    /// 0.05 deg/s budget, so a consumer accumulating an average asks THIS rather than
    /// `verdict.isOpen`.
    public func sampleWithinBand(_ sample: IMUSample) -> Bool {
        guard !sample.saturated else { return false }
        return bandViolation(mag: sample.specificForce.magnitude,
                             r: sample.rotationRate,
                             limit: config.gateMaxRotationRate) == nil
    }

    private mutating func evaluate(_ sample: IMUSample,
                                   mag: Double,
                                   r: Vector3,
                                   limit: Double) -> Verdict {
        // Saturation closes IMMEDIATELY and is never confirmed away. A clipped rail
        // is non-linear, and non-linearity rectifies AC into DC — which is one of the
        // only two ways vibration can bias an estimate that averaging cannot undo.
        if sample.saturated {
            conditionSince = nil
            violationSince = nil
            return Verdict(isOpen: false, heldFor: 0, reason: .saturated)
        }

        if let violation = bandViolation(mag: mag, r: r, limit: limit) {
            let since = violationSince ?? sample.time
            violationSince = since
            // Only a violation that PERSISTS closes the gate. Anything shorter is
            // engine excitation and is treated as though it never happened, so the
            // dwell keeps running and accumulated calibration survives. The sample
            // itself is still excluded from averages via `sampleWithinBand`.
            if sample.time - since >= config.gateCloseConfirm {
                conditionSince = nil
                return Verdict(isOpen: false, heldFor: 0, reason: violation)
            }
        } else {
            violationSince = nil
        }

        let since = conditionSince ?? sample.time
        conditionSince = since
        let held = sample.time - since

        if held >= config.gateDwell {
            return Verdict(isOpen: true, heldFor: held, reason: .open)
        }
        return Verdict(isOpen: false, heldFor: held, reason: .dwellNotMet)
    }

    /// Restarts the dwell. The violation timer is cleared too: `reset()` means "begin
    /// judging afresh", and a half-elapsed confirmation window carried across it
    /// would let the next single violating sample close the gate immediately.
    public mutating func reset() {
        conditionSince = nil
        violationSince = nil
    }
}
