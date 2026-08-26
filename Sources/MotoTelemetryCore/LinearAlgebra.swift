import Foundation

// Fixed-size linear algebra for the estimator.
//
// Accelerate is a platform framework and is banned from this target, so the
// algebra the ESKF and the RTS smoother need is written out explicitly at the
// exact sizes required: 3x3 for measurement updates, 6x6 for the error state.
// No general matrix type, no dynamic allocation, nothing to tune.

/// Row-major 3x3 matrix.
public struct Matrix3: Equatable, Sendable {
    /// Row-major, `e[row][col]` flattened: indices 0..2 are row 0.
    public var e: [Double]

    public init(rows: [Double]) {
        precondition(rows.count == 9, "Matrix3 needs 9 elements")
        self.e = rows
    }

    public init(_ r0: Vector3, _ r1: Vector3, _ r2: Vector3) {
        self.e = [r0.x, r0.y, r0.z, r1.x, r1.y, r1.z, r2.x, r2.y, r2.z]
    }

    public static let identity = Matrix3(rows: [1, 0, 0, 0, 1, 0, 0, 0, 1])
    public static let zero = Matrix3(rows: [Double](repeating: 0, count: 9))

    public subscript(row: Int, col: Int) -> Double {
        get { e[row * 3 + col] }
        set { e[row * 3 + col] = newValue }
    }

    public static func * (a: Matrix3, b: Matrix3) -> Matrix3 {
        var out = Matrix3.zero
        for i in 0..<3 {
            for j in 0..<3 {
                var s = 0.0
                for k in 0..<3 { s += a[i, k] * b[k, j] }
                out[i, j] = s
            }
        }
        return out
    }

    public static func * (a: Matrix3, v: Vector3) -> Vector3 {
        Vector3(a[0, 0]*v.x + a[0, 1]*v.y + a[0, 2]*v.z,
                a[1, 0]*v.x + a[1, 1]*v.y + a[1, 2]*v.z,
                a[2, 0]*v.x + a[2, 1]*v.y + a[2, 2]*v.z)
    }

    public static func * (a: Matrix3, s: Double) -> Matrix3 {
        Matrix3(rows: a.e.map { $0 * s })
    }

    public static func + (a: Matrix3, b: Matrix3) -> Matrix3 {
        Matrix3(rows: zip(a.e, b.e).map(+))
    }

    public static func - (a: Matrix3, b: Matrix3) -> Matrix3 {
        Matrix3(rows: zip(a.e, b.e).map(-))
    }

    public var transposed: Matrix3 {
        var out = Matrix3.zero
        for i in 0..<3 { for j in 0..<3 { out[i, j] = self[j, i] } }
        return out
    }

    public var determinant: Double {
        self[0, 0] * (self[1, 1]*self[2, 2] - self[1, 2]*self[2, 1])
      - self[0, 1] * (self[1, 0]*self[2, 2] - self[1, 2]*self[2, 0])
      + self[0, 2] * (self[1, 0]*self[2, 1] - self[1, 1]*self[2, 0])
    }

    /// Analytic inverse via the adjugate. Returns nil when effectively singular,
    /// which the caller must treat as a real condition rather than substituting
    /// a pseudo-inverse and carrying on.
    public func inverted() -> Matrix3? {
        let det = determinant
        guard abs(det) > 1e-12 else { return nil }
        let invDet = 1.0 / det
        var out = Matrix3.zero
        out[0, 0] = (self[1, 1]*self[2, 2] - self[1, 2]*self[2, 1]) * invDet
        out[0, 1] = (self[0, 2]*self[2, 1] - self[0, 1]*self[2, 2]) * invDet
        out[0, 2] = (self[0, 1]*self[1, 2] - self[0, 2]*self[1, 1]) * invDet
        out[1, 0] = (self[1, 2]*self[2, 0] - self[1, 0]*self[2, 2]) * invDet
        out[1, 1] = (self[0, 0]*self[2, 2] - self[0, 2]*self[2, 0]) * invDet
        out[1, 2] = (self[0, 2]*self[1, 0] - self[0, 0]*self[1, 2]) * invDet
        out[2, 0] = (self[1, 0]*self[2, 1] - self[1, 1]*self[2, 0]) * invDet
        out[2, 1] = (self[0, 1]*self[2, 0] - self[0, 0]*self[2, 1]) * invDet
        out[2, 2] = (self[0, 0]*self[1, 1] - self[0, 1]*self[1, 0]) * invDet
        return out
    }
}

/// Skew-symmetric matrix of `v`, i.e. `[v]x` such that `[v]x * w == v.cross(w)`.
/// The workhorse of both measurement Jacobians.
public func skew(_ v: Vector3) -> Matrix3 {
    Matrix3(rows: [   0, -v.z,  v.y,
                    v.z,    0, -v.x,
                   -v.y,  v.x,    0])
}

/// Row-major 6x6 matrix. The error state is [attitude error; gyro bias error].
public struct Matrix6: Equatable, Sendable {
    public var e: [Double]

    public init(rows: [Double]) {
        precondition(rows.count == 36, "Matrix6 needs 36 elements")
        self.e = rows
    }

    public static let zero = Matrix6(rows: [Double](repeating: 0, count: 36))

    public static let identity: Matrix6 = {
        var m = Matrix6.zero
        for i in 0..<6 { m[i, i] = 1 }
        return m
    }()

    public subscript(row: Int, col: Int) -> Double {
        get { e[row * 6 + col] }
        set { e[row * 6 + col] = newValue }
    }

    /// Builds a 6x6 from four 3x3 blocks.
    public init(topLeft: Matrix3, topRight: Matrix3,
                bottomLeft: Matrix3, bottomRight: Matrix3) {
        self = .zero
        for i in 0..<3 {
            for j in 0..<3 {
                self[i, j]         = topLeft[i, j]
                self[i, j + 3]     = topRight[i, j]
                self[i + 3, j]     = bottomLeft[i, j]
                self[i + 3, j + 3] = bottomRight[i, j]
            }
        }
    }

    public func block(row: Int, col: Int) -> Matrix3 {
        var out = Matrix3.zero
        for i in 0..<3 { for j in 0..<3 { out[i, j] = self[row + i, col + j] } }
        return out
    }

    public static func * (a: Matrix6, b: Matrix6) -> Matrix6 {
        var out = Matrix6.zero
        for i in 0..<6 {
            for j in 0..<6 {
                var s = 0.0
                for k in 0..<6 { s += a[i, k] * b[k, j] }
                out[i, j] = s
            }
        }
        return out
    }

    public static func * (a: Matrix6, s: Double) -> Matrix6 {
        Matrix6(rows: a.e.map { $0 * s })
    }

    public static func + (a: Matrix6, b: Matrix6) -> Matrix6 {
        Matrix6(rows: zip(a.e, b.e).map(+))
    }

    public static func - (a: Matrix6, b: Matrix6) -> Matrix6 {
        Matrix6(rows: zip(a.e, b.e).map(-))
    }

    public var transposed: Matrix6 {
        var out = Matrix6.zero
        for i in 0..<6 { for j in 0..<6 { out[i, j] = self[j, i] } }
        return out
    }

    /// Diagonal matrix from six values.
    public static func diagonal(_ d: [Double]) -> Matrix6 {
        precondition(d.count == 6)
        var m = Matrix6.zero
        for i in 0..<6 { m[i, i] = d[i] }
        return m
    }
}

/// A 6x6 symmetric positive-definite covariance.
///
/// Stored full but symmetrised after every update, because asymmetry is how a
/// Kalman filter dies quietly: over the ~180 000 sequential updates in a
/// half-hour session, accumulated asymmetry turns into a negative eigenvalue and
/// the filter starts trusting garbage without ever throwing.
public struct Symmetric6: Equatable, Sendable {
    public var m: Matrix6

    public init(_ m: Matrix6) { self.m = m }

    public static func diagonal(_ d: [Double]) -> Symmetric6 {
        Symmetric6(.diagonal(d))
    }

    public subscript(row: Int, col: Int) -> Double {
        get { m[row, col] }
        set { m[row, col] = newValue }
    }

    /// P <- (P + P^T) / 2.
    public mutating func symmetrise() {
        var out = Matrix6.zero
        for i in 0..<6 {
            for j in 0..<6 { out[i, j] = 0.5 * (m[i, j] + m[j, i]) }
        }
        m = out
    }

    /// Lower-triangular Cholesky factor L with `self == L * L^T`, or nil when the
    /// matrix is not positive definite. A nil here is a reportable condition, not
    /// something to paper over.
    public func cholesky() -> Matrix6? {
        var l = Matrix6.zero
        for i in 0..<6 {
            for j in 0...i {
                var s = m[i, j]
                for k in 0..<j { s -= l[i, k] * l[j, k] }
                if i == j {
                    guard s > 0 else { return nil }
                    l[i, j] = s.squareRoot()
                } else {
                    guard l[j, j] != 0 else { return nil }
                    l[i, j] = s / l[j, j]
                }
            }
        }
        return l
    }

    /// Solves `self * X = b` for X via the Cholesky factor.
    ///
    /// The RTS smoother needs `P^-1` but must never form it: an explicit inverse
    /// of a near-singular covariance amplifies error and destroys symmetry.
    /// Forward/back substitution keeps both.
    public func solve(_ b: Matrix6) -> Matrix6? {
        guard let l = cholesky() else { return nil }
        var x = Matrix6.zero
        // Solve column by column: L y = b_col, then L^T x_col = y.
        for col in 0..<6 {
            var y = [Double](repeating: 0, count: 6)
            for i in 0..<6 {
                var s = b[i, col]
                for k in 0..<i { s -= l[i, k] * y[k] }
                y[i] = s / l[i, i]
            }
            for i in stride(from: 5, through: 0, by: -1) {
                var s = y[i]
                for k in (i + 1)..<6 { s -= l[k, i] * x[k, col] }
                x[i, col] = s / l[i, i]
            }
        }
        return x
    }

    /// Quadratic form `v^T P v` over the 3-vector occupying rows/cols
    /// `offset..<offset+3`. Used to project the attitude covariance onto the
    /// pitch direction for the reported 1-sigma.
    public func quadraticForm(_ v: Vector3, offset: Int = 0) -> Double {
        let c = [v.x, v.y, v.z]
        var s = 0.0
        for i in 0..<3 {
            for j in 0..<3 { s += c[i] * m[offset + i, offset + j] * c[j] }
        }
        return s
    }
}
