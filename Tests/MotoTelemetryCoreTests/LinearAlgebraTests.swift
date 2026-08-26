import XCTest
@testable import MotoTelemetryCore

final class LinearAlgebraTests: XCTestCase {

    // MARK: - skew

    func testSkewMatchesCrossProduct() {
        let vs = [Vector3(1, 2, 3), Vector3(-0.4, 0.7, 2.1), Vector3(0, 0, 1)]
        for v in vs {
            for w in vs {
                let viaMatrix = skew(v) * w
                let viaCross = v.cross(w)
                XCTAssertEqual(viaMatrix.x, viaCross.x, accuracy: 1e-12)
                XCTAssertEqual(viaMatrix.y, viaCross.y, accuracy: 1e-12)
                XCTAssertEqual(viaMatrix.z, viaCross.z, accuracy: 1e-12)
            }
        }
    }

    func testSkewIsAntisymmetric() {
        let s = skew(Vector3(0.3, -1.2, 4.0))
        for i in 0..<3 {
            for j in 0..<3 {
                XCTAssertEqual(s[i, j], -s[j, i], accuracy: 1e-12)
            }
        }
    }

    // MARK: - Matrix3

    func testMatrix3InverseRoundTrips() {
        let m = Matrix3(rows: [4, 7, 2,
                               3, 6, 1,
                               2, 5, 3])
        guard let inv = m.inverted() else { return XCTFail("should be invertible") }
        let product = m * inv
        for i in 0..<3 {
            for j in 0..<3 {
                XCTAssertEqual(product[i, j], i == j ? 1 : 0, accuracy: 1e-12)
            }
        }
    }

    func testMatrix3SingularReturnsNil() {
        // Third row is the sum of the first two: rank 2.
        let singular = Matrix3(rows: [1, 2, 3,
                                      4, 5, 6,
                                      5, 7, 9])
        XCTAssertNil(singular.inverted())
    }

    func testMatrix3TransposeAndMultiply() {
        let a = Matrix3(rows: [1, 2, 3, 4, 5, 6, 7, 8, 10])
        XCTAssertEqual((a.transposed).transposed, a)
        let i = a * Matrix3.identity
        XCTAssertEqual(i, a)
    }

    func testRotationMatrixFromSkewIsOrthogonalUnderExponentialMap() {
        // Cross-check against the quaternion path: rotating by q and by the
        // matrix built from q's action must agree.
        let q = Quaternion.exp(rotationVector: Vector3(0.2, -0.5, 0.1)).normalized
        let basis = [Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)]
        let cols = basis.map { q.rotate($0) }
        let r = Matrix3(Vector3(cols[0].x, cols[1].x, cols[2].x),
                        Vector3(cols[0].y, cols[1].y, cols[2].y),
                        Vector3(cols[0].z, cols[1].z, cols[2].z))
        let v = Vector3(0.3, 1.1, -2.0)
        let viaMatrix = r * v
        let viaQuat = q.rotate(v)
        XCTAssertEqual(viaMatrix.x, viaQuat.x, accuracy: 1e-12)
        XCTAssertEqual(viaMatrix.y, viaQuat.y, accuracy: 1e-12)
        XCTAssertEqual(viaMatrix.z, viaQuat.z, accuracy: 1e-12)
        // Orthogonality: R R^T == I.
        let rrt = r * r.transposed
        for i in 0..<3 {
            for j in 0..<3 {
                XCTAssertEqual(rrt[i, j], i == j ? 1 : 0, accuracy: 1e-12)
            }
        }
    }

    // MARK: - Matrix6

    func testMatrix6IdentityAndBlocks() {
        let f = Matrix6(topLeft: skew(Vector3(1, 2, 3)) * -1,
                        topRight: Matrix3.identity * -1,
                        bottomLeft: .zero,
                        bottomRight: .zero)
        XCTAssertEqual(f.block(row: 0, col: 3), Matrix3.identity * -1)
        XCTAssertEqual(f.block(row: 3, col: 3), Matrix3.zero)
        XCTAssertEqual(Matrix6.identity * Matrix6.identity, Matrix6.identity)
        XCTAssertEqual(f * Matrix6.identity, f)
    }

    func testMatrix6TransposeOfProduct() {
        // (AB)^T == B^T A^T — cheap guard against an index slip in the loops.
        var a = Matrix6.zero, b = Matrix6.zero
        var seed = 1.0
        for i in 0..<6 {
            for j in 0..<6 {
                a[i, j] = sin(seed); b[i, j] = cos(seed * 1.7); seed += 1
            }
        }
        let lhs = (a * b).transposed
        let rhs = b.transposed * a.transposed
        for i in 0..<6 {
            for j in 0..<6 {
                XCTAssertEqual(lhs[i, j], rhs[i, j], accuracy: 1e-12)
            }
        }
    }

    // MARK: - Symmetric6

    private func samplePSD() -> Symmetric6 {
        // Build a genuinely SPD matrix as A A^T + 0.5 I.
        var a = Matrix6.zero
        var seed = 0.3
        for i in 0..<6 {
            for j in 0..<6 { a[i, j] = sin(seed) + 0.1 * Double(i + j); seed += 0.7 }
        }
        var p = Symmetric6(a * a.transposed + Matrix6.identity * 0.5)
        p.symmetrise()
        return p
    }

    func testCholeskyReproducesTheMatrix() {
        let p = samplePSD()
        guard let l = p.cholesky() else { return XCTFail("should be PD") }
        let reconstructed = l * l.transposed
        for i in 0..<6 {
            for j in 0..<6 {
                XCTAssertEqual(reconstructed[i, j], p[i, j], accuracy: 1e-10)
            }
        }
    }

    func testCholeskyRejectsNonPositiveDefinite() {
        var bad = Symmetric6(.identity)
        bad[2, 2] = -1
        XCTAssertNil(bad.cholesky(),
                     "a negative eigenvalue must be reported, not absorbed")

        // Also reject the semi-definite (singular) case.
        var singular = Symmetric6(.identity)
        singular[4, 4] = 0
        XCTAssertNil(singular.cholesky())
    }

    func testSolveMatchesAnExplicitInverse() {
        // Compare P^-1 * B computed by substitution against the same thing
        // computed by inverting a block-diagonal case analytically.
        let p = samplePSD()
        guard let x = p.solve(.identity) else { return XCTFail("solve failed") }
        // x should be P^-1: check P * x == I.
        let product = p.m * x
        for i in 0..<6 {
            for j in 0..<6 {
                XCTAssertEqual(product[i, j], i == j ? 1 : 0, accuracy: 1e-9)
            }
        }
    }

    func testSolveHandlesAGeneralRightHandSide() {
        let p = samplePSD()
        var b = Matrix6.zero
        var seed = 2.0
        for i in 0..<6 {
            for j in 0..<6 { b[i, j] = cos(seed); seed += 0.4 }
        }
        guard let x = p.solve(b) else { return XCTFail("solve failed") }
        let product = p.m * x
        for i in 0..<6 {
            for j in 0..<6 {
                XCTAssertEqual(product[i, j], b[i, j], accuracy: 1e-9)
            }
        }
    }

    func testSymmetriseRemovesAsymmetry() {
        var p = Symmetric6(.identity)
        p[0, 3] = 0.4
        p[3, 0] = 0.2
        p.symmetrise()
        XCTAssertEqual(p[0, 3], 0.3, accuracy: 1e-15)
        XCTAssertEqual(p[3, 0], 0.3, accuracy: 1e-15)
    }

    func testQuadraticFormProjectsTheAttitudeBlock() {
        var p = Symmetric6(.zero)
        p[0, 0] = 4; p[1, 1] = 9; p[2, 2] = 16
        // Unit vector along y picks out 9; sigma is therefore 3.
        XCTAssertEqual(p.quadraticForm(Vector3(0, 1, 0)), 9, accuracy: 1e-12)
        XCTAssertEqual(p.quadraticForm(Vector3(0, 1, 0)).squareRoot(),
                       3, accuracy: 1e-12)
        // Offset 3 reads the bias block, which is zero here.
        XCTAssertEqual(p.quadraticForm(Vector3(0, 1, 0), offset: 3),
                       0, accuracy: 1e-12)
    }
}
