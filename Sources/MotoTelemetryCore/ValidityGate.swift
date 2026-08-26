import Foundation

/// Decides when the accelerometer may be trusted as a gravity reference.
///
/// This single gate closes three bugs at once: acceleration read as pitch,
/// a turn read as lean (centripetal force tilts apparent gravity — the same
/// reason pilots get "the leans" and need an artificial horizon), and braking
/// read as nose-down. Integrate the gyro during anything dynamic; only
/// re-anchor when quasi-static is provable.
public struct ValidityGate: Stage {
    public struct Verdict: Sendable, Equatable {
        public var isOpen: Bool
        /// How long the underlying condition has held continuously.
        public var heldFor: TimeInterval
        public var reason: Reason
    }

    public enum Reason: String, Sendable, Equatable {
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

    public init(config: Config) { self.config = config }

    public mutating func process(_ sample: IMUSample) -> Verdict? {
        lastTime = sample.time

        if sample.saturated {
            conditionSince = nil
            return Verdict(isOpen: false, heldFor: 0, reason: .saturated)
        }

        let mag = sample.specificForce.magnitude
        guard mag >= config.gateSpecificForceLow, mag <= config.gateSpecificForceHigh else {
            conditionSince = nil
            return Verdict(isOpen: false, heldFor: 0, reason: .specificForceOutOfBand)
        }

        let r = sample.rotationRate
        let limit = config.gateMaxRotationRate
        guard abs(r.x) < limit, abs(r.y) < limit, abs(r.z) < limit else {
            conditionSince = nil
            return Verdict(isOpen: false, heldFor: 0, reason: .rotating)
        }

        let since = conditionSince ?? sample.time
        conditionSince = since
        let held = sample.time - since

        if held >= config.gateDwell {
            return Verdict(isOpen: true, heldFor: held, reason: .open)
        }
        return Verdict(isOpen: false, heldFor: held, reason: .dwellNotMet)
    }

    public mutating func reset() { conditionSince = nil }
}
