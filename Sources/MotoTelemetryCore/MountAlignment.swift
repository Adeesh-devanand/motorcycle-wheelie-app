import Foundation

/// Solves the phone-to-bike rotation from two rider gestures, so the phone can be
/// mounted however it fits and a crooked mount costs nothing in accuracy.
///
/// Closed form, no optimiser:
///  1. At rest with the gate open, specific force points along gravity, giving
///     DOWN in device axes.
///  2. One hard straight-line acceleration gives FORWARD, taken as the change in
///     specific force projected off the down axis.
///  3. The third axis is the cross product; Gram-Schmidt makes the set orthonormal.
///
/// The output is the pair of vectors `AxisElevation` already consumes, so nothing
/// downstream needs a rotation matrix or a frame convention of its own.

public struct MountAlignment: Codable, Sendable, Equatable {
    /// Bike forward, expressed in DEVICE axes.
    public var forwardInBody: Vector3
    /// Bike up, expressed in DEVICE axes.
    public var upInBody: Vector3
    /// Bike left, expressed in DEVICE axes. Stored for the roll channel.
    public var leftInBody: Vector3
    /// Radians of non-orthogonality between the raw measured axes, before
    /// Gram-Schmidt fixed it up. Large values mean one of the gestures was poor.
    public var residual: Double
    /// Peak longitudinal acceleration reached during the pull, m/s^2. The quality
    /// of the FORWARD axis is entirely a function of this.
    public var peakPullAcceleration: Double
    public var capturedAt: Date
    public var bikeProfileID: UUID

    public init(forwardInBody: Vector3,
                upInBody: Vector3,
                leftInBody: Vector3,
                residual: Double,
                peakPullAcceleration: Double,
                capturedAt: Date = Date(),
                bikeProfileID: UUID) {
        self.forwardInBody = forwardInBody
        self.upInBody = upInBody
        self.leftInBody = leftInBody
        self.residual = residual
        self.peakPullAcceleration = peakPullAcceleration
        self.capturedAt = capturedAt
        self.bikeProfileID = bikeProfileID
    }

    /// The identity mount: phone axes already aligned with the bike. Used by
    /// tests, replay of pre-alignment logs, and as the assumption of last resort
    /// (which the UI must disclose rather than silently adopt).
    public static func identity(bikeProfileID: UUID = UUID()) -> MountAlignment {
        MountAlignment(forwardInBody: Conventions.bikeForward,
                       upInBody: Conventions.bikeUp,
                       leftInBody: Conventions.bikeLeft,
                       residual: 0,
                       peakPullAcceleration: .infinity,
                       bikeProfileID: bikeProfileID)
    }

    /// Pitch of the bike given a device attitude, using this alignment.
    public func pitch(attitude: Quaternion) -> Double {
        AxisElevation.pitch(attitude: attitude, forwardInBody: forwardInBody)
    }

    /// Roll of the bike given a device attitude, using this alignment.
    public func roll(attitude: Quaternion) -> Double {
        AxisElevation.roll(attitude: attitude,
                           forwardInBody: forwardInBody,
                           upInBody: upInBody)
    }
}

/// Accumulates the two gestures and solves for the alignment.
public struct AlignmentSolver {

    public enum Failure: Error, Sendable, Equatable {
        /// The pull was too gentle to define a forward axis. Below ~0.25 g the
        /// direction is dominated by noise and the solved axis is meaningless.
        case pullTooWeak(peak: Double, required: Double)
        /// The two gestures were not close to perpendicular, so at least one is
        /// wrong — typically a pull taken while still leaning or braking.
        case axesNotPerpendicular(residual: Double, limit: Double)
        case notEnoughRestSamples(count: Int, required: Int)
        case notEnoughPullSamples(count: Int, required: Int)

        public var message: String {
            switch self {
            case .pullTooWeak(let peak, let required):
                return String(format: "Accelerate harder in a straight line: "
                              + "reached %.2f g, need %.2f g.",
                              peak / Conventions.g, required / Conventions.g)
            case .axesNotPerpendicular(let residual, let limit):
                return String(format: "Gestures were %.1f deg from perpendicular "
                              + "(limit %.1f). Pull straight, upright, no braking.",
                              residual * 180 / .pi, limit * 180 / .pi)
            case .notEnoughRestSamples:
                return "Hold the bike still and level for a moment first."
            case .notEnoughPullSamples:
                return "Hold the throttle open a little longer."
            }
        }
    }

    private let config: Config
    private let bikeProfileID: UUID
    private let minimumRestSamples: Int
    private let minimumPullSamples: Int

    private var gate: ValidityGate
    private var restSum = Vector3.zero
    private var restCount = 0

    private var pullSum = Vector3.zero
    private var pullCount = 0
    private var peakDeviation = 0.0

    public init(config: Config,
                bikeProfileID: UUID,
                minimumRestSamples: Int = 100,
                minimumPullSamples: Int = 20) {
        self.config = config
        self.bikeProfileID = bikeProfileID
        self.minimumRestSamples = minimumRestSamples
        self.minimumPullSamples = minimumPullSamples
        self.gate = ValidityGate(config: config)
    }

    /// Gesture (a). Only gate-open, unsaturated samples are admitted, so "at rest
    /// and level" is proven rather than assumed.
    @discardableResult
    public mutating func addRestSample(_ sample: IMUSample) -> Bool {
        guard !sample.saturated, let verdict = gate.process(sample), verdict.isOpen
        else { return false }
        restSum = restSum + sample.specificForce
        restCount += 1
        return true
    }

    /// Gesture (b). Accumulates the deviation from rest, which is the signature of
    /// the acceleration. Saturated samples are excluded — a saturated axis has no
    /// usable direction.
    @discardableResult
    public mutating func addPullSample(_ sample: IMUSample) -> Bool {
        guard !sample.saturated, restCount >= minimumRestSamples else { return false }
        let rest = restSum / Double(restCount)
        let deviation = sample.specificForce - rest
        let magnitude = deviation.magnitude
        // Only samples actually showing acceleration inform the direction.
        guard magnitude > 0.05 * Conventions.g else { return false }
        pullSum = pullSum + deviation
        pullCount += 1
        peakDeviation = max(peakDeviation, magnitude)
        return true
    }

    public var restSampleCount: Int { restCount }
    public var pullSampleCount: Int { pullCount }
    public var peakPullAcceleration: Double { peakDeviation }

    public func solve() -> Result<MountAlignment, Failure> {
        guard restCount >= minimumRestSamples else {
            return .failure(.notEnoughRestSamples(count: restCount,
                                                  required: minimumRestSamples))
        }
        guard pullCount >= minimumPullSamples else {
            return .failure(.notEnoughPullSamples(count: pullCount,
                                                  required: minimumPullSamples))
        }
        guard peakDeviation >= config.alignmentMinPullAccel else {
            return .failure(.pullTooWeak(peak: peakDeviation,
                                         required: config.alignmentMinPullAccel))
        }

        // Specific force points ALONG gravity at rest, so its direction is down.
        let restMean = restSum / Double(restCount)
        let down = restMean.normalized
        let up = down * -1

        // Per the sign convention, forward acceleration `a` contributes
        // -a*cos(theta) to the longitudinal component: the deviation points
        // BACKWARD. Negate it to get forward.
        let deviationMean = pullSum / Double(pullCount)
        let forwardRaw = (deviationMean * -1).normalized

        // How far from perpendicular were the two measured directions? This is the
        // honest quality number: Gram-Schmidt below will always produce an
        // orthonormal set, so without this the caller cannot tell a clean
        // alignment from a fabricated one.
        let cosine = max(-1, min(1, forwardRaw.dot(up)))
        let residual = abs(asin(cosine))
        guard residual <= config.alignmentMaxResidual else {
            return .failure(.axesNotPerpendicular(residual: residual,
                                                  limit: config.alignmentMaxResidual))
        }

        let forward = (forwardRaw - up * forwardRaw.dot(up)).normalized
        // Right-handed with Z up requires LEFT as the second axis.
        let left = up.cross(forward)

        return .success(MountAlignment(forwardInBody: forward,
                                       upInBody: up,
                                       leftInBody: left,
                                       residual: residual,
                                       peakPullAcceleration: peakDeviation,
                                       bikeProfileID: bikeProfileID))
    }

    public mutating func restart() {
        restSum = .zero; restCount = 0
        pullSum = .zero; pullCount = 0
        peakDeviation = 0
        gate.reset()
    }
}
