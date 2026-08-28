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

    /// A phone held or cradled in PORTRAIT with the screen facing the rider — the
    /// overwhelmingly common case, and a far better default than `identity`.
    ///
    /// CoreMotion's device frame is +X across the screen to the right, +Y along the
    /// screen toward the top, +Z out of the front face. With the screen facing
    /// backward at the rider:
    ///
    /// - bike forward `+X` is out the BACK of the phone → device `−Z`
    /// - bike up `+Z` is the top of the screen           → device `+Y`
    /// - bike left `+Y` is                                  device `−X`
    ///
    /// Right-handedness holds: `forward × left == (0,1,0) == up`, per Conventions.
    ///
    /// Why this matters: `identity` claims bike-forward is device `+X`, which in a
    /// portrait mount is the LATERAL axis. `AxisElevation.pitch` then reports the
    /// elevation of the bike's lateral axis — which is lean, not pitch. That is why
    /// an identity-aligned portrait phone appears to measure only roll, and why its
    /// angle swings negative as the phone tips either way.
    ///
    /// This is still a PRESET, not a measurement: it assumes a square mount. Only
    /// the two-gesture solve (R7.1) accounts for a crooked one, so a rider whose
    /// phone is visibly rotated in its cradle still needs the real alignment.
    public static func portraitMount(bikeProfileID: UUID = UUID()) -> MountAlignment {
        MountAlignment(forwardInBody: Vector3(0, 0, -1),
                       upInBody: Vector3(0, 1, 0),
                       leftInBody: Vector3(-1, 0, 0),
                       residual: 0,
                       peakPullAcceleration: 0,
                       bikeProfileID: bikeProfileID)
    }

    /// Derives an alignment from the MEASURED rest specific-force vector alone.
    ///
    /// Gravity fixes `up` exactly. It cannot fix heading — rotation about up is
    /// unobservable from gravity — so one assumption supplies the rest: the
    /// device's screen-horizontal axis is the bike's lateral axis. That holds for
    /// any ordinary cradle, portrait-upright or lying flat, which is precisely the
    /// pair of cases a fixed preset cannot straddle: bike-forward is device -Z for
    /// an upright phone but device +Y for a flat one, and guessing wrong swaps
    /// lean and pitch.
    ///
    ///   up      = -normalize(f_rest)                  (measured)
    ///   left    = device -X, Gram-Schmidt'd against up
    ///   forward = left x up                           (Conventions: left x up == forward)
    ///
    /// A lean is then a rotation about `forward`, and rotating a vector about
    /// itself is the identity, so `AxisElevation.pitch` is invariant under lean —
    /// which is the property that stops a corner reading as a wheelie.
    ///
    /// This is still weaker than R7.1's two-gesture solve, which remains necessary:
    /// this cannot detect a phone rotated in its cradle about the screen normal,
    /// and cannot tell forward from backward.
    public static func fromMeasuredGravity(specificForce: Vector3,
                                           bikeProfileID: UUID = UUID()) -> MountAlignment {
        let up = (specificForce * -1).normalized

        // Device -X is the lateral candidate. If the phone is mounted on its side
        // it can lie along `up`, where the projection collapses and would yield a
        // NaN axis; device -Y is then guaranteed independent, since two orthogonal
        // axes cannot both be parallel to up.
        var lateralCandidate = Vector3(-1, 0, 0)
        if abs(lateralCandidate.dot(up)) > 0.94 {          // within ~20 deg of up
            lateralCandidate = Vector3(0, -1, 0)
        }

        let projected = lateralCandidate - up * lateralCandidate.dot(up)
        let left = projected.normalized
        let forward = left.cross(up)

        return MountAlignment(forwardInBody: forward,
                              upInBody: up,
                              leftInBody: left,
                              residual: 0,
                              peakPullAcceleration: 0,
                              bikeProfileID: bikeProfileID)
    }

    /// Re-levels an EXISTING alignment against a freshly measured gravity vector,
    /// keeping the forward heading and replacing only what gravity actually observes.
    ///
    /// This is what a re-anchor needs, and neither of the two obvious options gives
    /// it. Re-deriving the whole alignment with `fromMeasuredGravity` re-guesses which
    /// horizontal direction is bike-forward, and a device log showed seven
    /// calibrations in one session each silently reassigning which tilt counts as a
    /// wheelie. Leaving the alignment untouched looks safe but does not zero the
    /// angle: `AxisElevation.pitch` is the elevation of `forward`, so if the old
    /// `forward` is not perpendicular to the NEW `up`, the pose the rider just
    /// declared level still reads its full tilt — 35 deg still reported 35.0 deg, and
    /// the re-zero the rider asked for did nothing.
    ///
    /// So: take `up` from the measurement (gravity fixes it exactly) and
    /// Gram-Schmidt the existing `forward` against it. Forward keeps its heading, is
    /// perpendicular to the new up by construction, and the pose reads exactly 0.
    public func releveled(againstMeasuredGravity specificForce: Vector3) -> MountAlignment {
        let up = (specificForce * -1).normalized
        let projected = forwardInBody - up * forwardInBody.dot(up)
        guard projected.magnitude > 1e-6 else {
            // Forward is parallel to the new up: the phone has been turned through
            // ~90 deg, which is a REMOUNT, not a re-level. There is no heading left
            // to preserve, so fall back to deriving one.
            return .fromMeasuredGravity(specificForce: specificForce,
                                        bikeProfileID: bikeProfileID)
        }
        let forward = projected.normalized
        return MountAlignment(forwardInBody: forward,
                              upInBody: up,
                              leftInBody: up.cross(forward),
                              residual: residual,
                              peakPullAcceleration: peakPullAcceleration,
                              capturedAt: capturedAt,
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
