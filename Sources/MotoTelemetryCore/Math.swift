import Foundation

public struct Vector3: Equatable, Codable, Sendable {
    public var x, y, z: Double
    public init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }

    public static let zero = Vector3(0, 0, 0)

    public var magnitude: Double { (x*x + y*y + z*z).squareRoot() }
    public var normalized: Vector3 {
        let m = magnitude
        return m > 0 ? Vector3(x/m, y/m, z/m) : .zero
    }

    public static func + (a: Vector3, b: Vector3) -> Vector3 { Vector3(a.x+b.x, a.y+b.y, a.z+b.z) }
    public static func - (a: Vector3, b: Vector3) -> Vector3 { Vector3(a.x-b.x, a.y-b.y, a.z-b.z) }
    public static func * (a: Vector3, s: Double) -> Vector3 { Vector3(a.x*s, a.y*s, a.z*s) }
    public static func / (a: Vector3, s: Double) -> Vector3 { Vector3(a.x/s, a.y/s, a.z/s) }

    public func dot(_ o: Vector3) -> Double { x*o.x + y*o.y + z*o.z }
    public func cross(_ o: Vector3) -> Vector3 {
        Vector3(y*o.z - z*o.y, z*o.x - x*o.z, x*o.y - y*o.x)
    }
}

/// Unit quaternion, scalar-first (w, x, y, z). Rotates body -> world.
public struct Quaternion: Equatable, Codable, Sendable {
    public var w, x, y, z: Double
    public init(w: Double, x: Double, y: Double, z: Double) {
        self.w = w; self.x = x; self.y = y; self.z = z
    }

    public static let identity = Quaternion(w: 1, x: 0, y: 0, z: 0)

    public var normalized: Quaternion {
        let m = (w*w + x*x + y*y + z*z).squareRoot()
        guard m > 0 else { return .identity }
        return Quaternion(w: w/m, x: x/m, y: y/m, z: z/m)
    }

    public static func * (a: Quaternion, b: Quaternion) -> Quaternion {
        Quaternion(
            w: a.w*b.w - a.x*b.x - a.y*b.y - a.z*b.z,
            x: a.w*b.x + a.x*b.w + a.y*b.z - a.z*b.y,
            y: a.w*b.y - a.x*b.z + a.y*b.w + a.z*b.x,
            z: a.w*b.z + a.x*b.y - a.y*b.x + a.z*b.w
        )
    }

    /// Rotate a body-frame vector into the world frame.
    public func rotate(_ v: Vector3) -> Vector3 {
        let qv = Vector3(x, y, z)
        let t = qv.cross(v) * 2.0
        return v + t * w + qv.cross(t)
    }

    /// Exponential map of a rotation vector (axis * angle, radians).
    public static func exp(rotationVector r: Vector3) -> Quaternion {
        let theta = r.magnitude
        guard theta > 1e-12 else { return .identity }
        let half = theta / 2
        let s = sin(half) / theta
        return Quaternion(w: cos(half), x: r.x*s, y: r.y*s, z: r.z*s)
    }
}
