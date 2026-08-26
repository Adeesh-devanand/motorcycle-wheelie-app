import Foundation

/// The canonical frame and sign conventions. Every sign question anywhere in
/// this package is settled by reading this file.
///
/// This exists because the package once contained a contradiction: the synthetic
/// generator was written in an aerospace-style frame (nose-up positive about +Y,
/// Z down) while `AxisElevation` reads a Z-up world and its passing test pins
/// nose-up as a NEGATIVE rotation about +Y. Neither the validity gate (magnitude
/// only) nor the naive-tilt test (`atan2(fx, -fz)`, sign-symmetric) could detect
/// the mismatch, and an estimator built against the generator's frame would have
/// reported negative angles for real wheelies. See `ConventionTests`.
///
/// ## World frame W
/// Right-handed, **+Z up**. Fixed by `AxisElevation`, which reads `fWorld.z` and
/// compares against `Vector3(0, 0, 1)`.
///
/// ## Bike frame B
/// Right-handed, **+X forward, +Y left, +Z up**. Y must point *left*, not right:
/// with Z up, right-handedness requires `forward cross left == up`.
///
/// ## Attitude
/// `Quaternion` rotates **body -> world**, per `Quaternion.rotate(_:)`.
///
/// ## Nose-up is a NEGATIVE rotation about +Y
/// A wheelie of theta is `Quaternion.exp(rotationVector: Vector3(0, -theta, 0))`.
/// Fixed by `AxisElevationTests.testPitchIsIndependentOfRoll`.
/// Consequently **a wheelie produces a negative `rotationRate.y`**.
///
/// ## Specific force points ALONG gravity
/// A level bike at rest reads `(0, 0, -g)`. Fixed by `ValidityGateTests.level`.
/// This is the negative of proper acceleration. Formally:
///
///     f_B = R(q)^T * (g_W - a_W)      g_W = (0, 0, -g), a_W = world accel
///
/// For a bike pitched nose-up by theta accelerating forward at `a`:
///
///     f_B = ( -g*sin(theta) - a*cos(theta), 0, -g*cos(theta) + a*sin(theta) )
///
/// At theta = 0, a = 0 that is `(0, 0, -g)`.
public enum Conventions {

    /// Standard gravity, m/s^2.
    public static let g = 9.80665

    /// World up, world frame.
    public static let worldUp = Vector3(0, 0, 1)

    /// World gravity vector, world frame.
    public static let worldGravity = Vector3(0, 0, -g)

    /// Bike forward, bike frame.
    public static let bikeForward = Vector3(1, 0, 0)

    /// Bike left, bike frame. Left, not right — required for right-handedness
    /// once +Z is up.
    public static let bikeLeft = Vector3(0, 1, 0)

    /// Bike up, bike frame.
    public static let bikeUp = Vector3(0, 0, 1)

    /// What a level, stationary bike's accelerometer reads, bike frame.
    public static let restSpecificForce = Vector3(0, 0, -g)

    /// The attitude of a bike pitched nose-up by `pitch` radians, no roll.
    /// The single place the nose-up sign is written down.
    public static func attitude(nosUpBy pitch: Double) -> Quaternion {
        Quaternion.exp(rotationVector: Vector3(0, -pitch, 0)).normalized
    }

    /// Body-frame specific force for a bike at `pitch` (nose-up, radians)
    /// undergoing world-horizontal forward acceleration `forwardAcceleration`.
    /// This is the forward model the ESKF's gravity measurement inverts, and the
    /// model the synthetic generator must emit.
    public static func specificForce(pitch: Double,
                                     forwardAcceleration a: Double = 0) -> Vector3 {
        Vector3(-g * sin(pitch) - a * cos(pitch),
                0,
                -g * cos(pitch) + a * sin(pitch))
    }

    /// Body-frame angular rate for a bike pitching up at `pitchRate` rad/s.
    public static func rotationRate(pitchRate: Double) -> Vector3 {
        Vector3(0, -pitchRate, 0)
    }
}
