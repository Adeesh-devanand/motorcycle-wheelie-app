import Foundation

/// Wheelie angle, defined correctly.
///
/// Do NOT use Euler pitch. Euler angles do not commute, so roll leaks into
/// pitch and a 30 deg lean corrupts the reading depending on unpack order.
/// Instead: rotate the bike's forward axis into the world frame and read its
/// ELEVATION above the horizontal plane. That scalar is exactly the physical
/// quantity — how far the bike's long axis has rotated up from level — and it
/// is mathematically indifferent to roll about that axis.
///
/// Lean then becomes a separate, useful channel rather than an error term.
public enum AxisElevation {

    /// Elevation of the bike's forward axis above horizontal, radians.
    /// Positive = nose up.
    public static func pitch(attitude: Quaternion, forwardInBody: Vector3) -> Double {
        let fWorld = attitude.rotate(forwardInBody.normalized).normalized
        // World frame: +Z is up.
        return asin(max(-1, min(1, fWorld.z)))
    }

    /// Roll about the bike's forward axis, radians. Positive = right.
    public static func roll(attitude: Quaternion,
                            forwardInBody: Vector3,
                            upInBody: Vector3) -> Double {
        let f = attitude.rotate(forwardInBody.normalized).normalized
        let u = attitude.rotate(upInBody.normalized).normalized
        // Project world-up into the plane perpendicular to forward, then
        // measure the angle between that and the bike's own up axis.
        let worldUp = Vector3(0, 0, 1)
        let refUp = (worldUp - f * worldUp.dot(f)).normalized
        let right = f.cross(refUp)
        return atan2(u.dot(right), u.dot(refUp))
    }

    /// Seconds until `target` is reached at the current rate, or nil if not
    /// closing on it. The cue fires on THIS, not on crossing the threshold —
    /// creep up slowly and it stays quiet, snap up fast and it warns early.
    public static func timeToThreshold(current: Double,
                                       rate: Double,
                                       target: Double) -> TimeInterval? {
        let remaining = target - current
        guard rate > 1e-6, remaining > 0 else { return nil }
        return remaining / rate
    }
}
