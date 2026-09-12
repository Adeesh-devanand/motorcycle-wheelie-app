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
    /// The only way a swipe capture can fail.
    ///
    /// A single case, because the swipe resolves every mount geometry it can be given:
    /// a horizontal-ish swipe on a flat mount gives the chassis axis directly, and a
    /// swipe along gravity on a vertical mount classifies the mount and routes to the
    /// screen normal. What is left is the rider not drawing anything.
    ///
    /// This replaced `AlignmentSolver.Failure`. The two-gesture rest-plus-pull solve it
    /// belonged to was deleted: it existed to handle mounts the swipe could not, and
    /// once the vertical branch landed there were none, so it was a second capture
    /// path that nothing would ever call.
    public enum SwipeFailure: Error, Sendable, Equatable {
        /// The gesture had no length — a tap, not a line — so there is no direction
        /// to read. `atan2(0, 0)` would return an arbitrary 0 and silently claim the
        /// bike faces along device +X.
        case noSwipeDirection

        public var message: String {
            switch self {
            case .noSwipeDirection:
                // "back to front": this function reads the swipe direction AS the bike's
                // forward axis (see `fromSwipe`), so telling the rider to draw front to
                // back would instruct them into a reversed forward axis — the silent
                // 180-degree error documented there.
                return "Draw a line along the length of the bike, back to front."
            }
        }
    }

    /// Bike forward, expressed in DEVICE axes.
    public var forwardInBody: Vector3
    /// Bike up, expressed in DEVICE axes.
    public var upInBody: Vector3
    /// Bike left, expressed in DEVICE axes. Stored for the roll channel.
    public var leftInBody: Vector3
    public var capturedAt: Date
    public var bikeProfileID: UUID
    /// `|p|` from a swipe-derived capture: the fraction of the swipe that survived
    /// projecting gravity out of it, equal to sin(angle between swipe and gravity).
    /// 1.0 is a perfectly horizontal swipe; near 0 means the swipe carried no
    /// heading information and the screen-normal fallback was used instead.
    ///
    /// Nil for every other capture path, which is why it is Optional rather than 0:
    /// a two-gesture solve has no swipe, and 0 would falsely read as a degenerate
    /// one. Optional also keeps previously-stored alignments decodable.
    public var swipeConfidence: Double?

    public init(forwardInBody: Vector3,
                upInBody: Vector3,
                leftInBody: Vector3,
                capturedAt: Date = Date(),
                bikeProfileID: UUID,
                swipeConfidence: Double? = nil) {
        self.swipeConfidence = swipeConfidence
        self.forwardInBody = forwardInBody
        self.upInBody = upInBody
        self.leftInBody = leftInBody
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
                              bikeProfileID: bikeProfileID)
    }

    // MARK: - Swipe-derived heading (beta)

    /// Resolve the bike's horizontal forward axis from its screen projection.
    /// A drawn line supplies X:Y; measured gravity supplies the missing Z through
    /// forward.dot(gravity) == 0. Orthogonally projecting the swipe off gravity
    /// instead changes X:Y on oblique mounts and leaks side lean into wheelie angle.
    /// Near-vertical screens cannot observe Z reliably and use the rider-facing
    /// screen-normal assumption. A sideways or inaccurate swipe remains ambiguous.
    /// `screenYaw` uses device Y-up; `fromSwipe` converts touch coordinates.
    public static func fromMeasuredGravity(
        specificForce: Vector3,
        screenYaw: Double,
        config: Config = Config(),
        bikeProfileID: UUID = UUID()
    ) -> MountAlignment {
        let gHat = specificForce.normalized
        let swipe = Vector3(cos(screenYaw), sin(screenYaw), 0)

        let p = swipe - gHat * swipe.dot(gHat)
        let confidence = p.magnitude

        // A swipe is the SCREEN PROJECTION of forward. Subtracting gravity
        // from (sx, sy, 0) changes that projection on an oblique mount and
        // mixes roll into pitch. Recover the missing Z component instead,
        // enforcing forward.dot(gravity) == 0 while preserving swipe X:Y.
        // Near vertical, Z is unobservable; retain the disclosed normal fallback.
        let forward: Vector3
        if abs(gHat.z) >= config.alignmentScreenNormalMin {
            forward = Vector3(swipe.x, swipe.y,
                              -(swipe.x * gHat.x + swipe.y * gHat.y) / gHat.z).normalized
        } else {
            return fromScreenNormal(specificForce: specificForce,
                                    bikeProfileID: bikeProfileID)
        }
        let up = gHat * -1
        let left = up.cross(forward)

        return MountAlignment(forwardInBody: forward,
                              upInBody: up,
                              leftInBody: left,
                              bikeProfileID: bikeProfileID,
                              swipeConfidence: confidence)
    }

    /// As above, from a raw gesture translation.
    ///
    /// Does the UIKit/SwiftUI coordinate flip internally, on purpose: screen dy grows
    /// downward while the device's +Y axis points up the screen, so a bottom-to-top
    /// swipe arrives as a NEGATIVE dy. Getting that sign wrong reverses the bike's
    /// forward axis and reports every wheelie as a stoppie — a silent 180-degree
    /// error that no unit test in the app target could catch, since the app target
    /// does not build off-device. So the flip lives here, where it is tested.
    ///
    /// The only genuine failure is a swipe with no length: the rider tapped instead
    /// of drawing, so there is no direction to read. Everything else resolves.
    public static func fromSwipe(
        specificForce: Vector3,
        screenDX: Double,
        screenDY: Double,
        config: Config = Config(),
        bikeProfileID: UUID = UUID()
    ) -> Result<MountAlignment, SwipeFailure> {
        guard screenDX != 0 || screenDY != 0 else {
            return .failure(.noSwipeDirection)
        }
        return .success(fromMeasuredGravity(specificForce: specificForce,
                                            screenYaw: atan2(-screenDY, screenDX),
                                            config: config,
                                            bikeProfileID: bikeProfileID))
    }

    /// The vertical-mount branch: heading comes from the screen NORMAL.
    ///
    /// Reached when the swipe ran along gravity (`|p|` near 0), which is what a rider
    /// on a bar-mounted phone naturally draws for "forward". The geometry then tells
    /// you the answer: the screen plane is vertical and contains `up`, so the bike's
    /// forward axis points out through the screen. A rider looking at the screen has
    /// the front wheel BEYOND it, so forward is into the screen, device `−Z`.
    ///
    /// This is a disclosed assumption rather than a measurement, and it is wrong in
    /// one case it cannot detect: a phone mounted with the screen facing FORWARD,
    /// where forward is `+Z`. Gravity cannot distinguish the two. The capture screen
    /// draws the resolved orientation so the rider sees which way the app thinks the
    /// bike faces, which is what turns that into a visible, re-swipeable mistake
    /// rather than a silent 180-degree error.
    public static func fromScreenNormal(specificForce: Vector3,
                                        bikeProfileID: UUID = UUID()) -> MountAlignment {
        let up = (specificForce * -1).normalized
        let normalCandidate = Vector3(0, 0, -1)          // into the screen
        let projected = normalCandidate - up * normalCandidate.dot(up)
        let forward = projected.normalized
        let left = up.cross(forward)

        return MountAlignment(forwardInBody: forward,
                              upInBody: up,
                              leftInBody: left,
                              bikeProfileID: bikeProfileID,
                              swipeConfidence: 0)
    }

    /// Re-levels an EXISTING alignment against a freshly measured gravity vector,    /// keeping the forward heading and replacing only what gravity actually observes.
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
