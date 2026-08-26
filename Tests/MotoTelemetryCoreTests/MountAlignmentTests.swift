import XCTest
@testable import MotoTelemetryCore

final class MountAlignmentTests: XCTestCase {

    private let bike = UUID()

    /// A crooked mount: yaw 25 deg, pitch 15 deg, roll -30 deg, in one rotation.
    private var crookedMount: Quaternion {
        (Quaternion.exp(rotationVector: Vector3(0, 0, 25 * .pi / 180))
         * Quaternion.exp(rotationVector: Vector3(0, 15 * .pi / 180, 0))
         * Quaternion.exp(rotationVector: Vector3(-30 * .pi / 180, 0, 0))).normalized
    }

    /// Feeds the solver a rest phase and a pull phase as seen through `mount`.
    private func solve(mount: Quaternion,
                       pullAcceleration: Double = 0.5 * Conventions.g,
                       restSamples: Int = 150,
                       pullSamples: Int = 60,
                       config: Config = Config())
        -> Result<MountAlignment, AlignmentSolver.Failure> {
        var solver = AlignmentSolver(config: config, bikeProfileID: bike)

        // Rest: level, stationary. In bike axes f = (0, 0, -g).
        for i in 0..<restSamples {
            let f = mount.rotate(Conventions.restSpecificForce)
            solver.addRestSample(IMUSample(time: Double(i) / 100,
                                           rotationRate: .zero,
                                           specificForce: f))
        }
        // Pull: level, accelerating forward at `pullAcceleration`.
        for i in 0..<pullSamples {
            let bikeForce = Conventions.specificForce(
                pitch: 0, forwardAcceleration: pullAcceleration)
            let f = mount.rotate(bikeForce)
            solver.addPullSample(IMUSample(time: 2.0 + Double(i) / 100,
                                           rotationRate: .zero,
                                           specificForce: f))
        }
        return solver.solve()
    }

    // MARK: - The acceptance criterion

    /// T3.2 / R7.5 — with an arbitrary mount rotation, the recovered alignment must
    /// reproduce true pitch to within 0.5 deg across a whole scenario.
    func testRecoveredAlignmentReproducesTruePitchAcrossTheScenario() throws {
        let mount = crookedMount
        guard case .success(let alignment) = solve(mount: mount) else {
            return XCTFail("solver failed on a valid pair of gestures")
        }

        var scenario = SyntheticSource.Scenario()
        scenario.mountRotation = mount
        scenario.gyroBias = .zero
        scenario.vibrationAmplitude = 0
        scenario.emitGNSS = false
        var source = SyntheticSource(scenario: scenario)

        // Integrate the DEVICE-frame gyro to a device->world attitude, then read
        // pitch through the recovered alignment. No estimator involved: this
        // isolates the alignment.
        //
        // The starting attitude is NOT identity. `mountRotation` maps bike
        // components to device components, so at t = 0 — bike level, world frame
        // aligned with the bike — the device->world attitude is the mount's
        // conjugate. Starting from identity would measure attitude relative to the
        // initial DEVICE frame instead of the world, which for a crooked mount is
        // wrong by the whole mount rotation. On a real phone this initial attitude
        // comes from the gate-open gravity anchor, which is exactly what the ESKF
        // will do.
        var q = Quaternion(w: mount.w, x: -mount.x, y: -mount.y, z: -mount.z).normalized
        var lastTime: TimeInterval?
        var lastRate: Vector3?
        var worst = 0.0

        while let sample = source.next() {
            guard case .imu(let imu) = sample else { continue }
            defer { lastTime = imu.time; lastRate = imu.rotationRate }
            guard let previous = lastTime, let previousRate = lastRate else { continue }
            let dt = imu.time - previous
            let mean = (previousRate + imu.rotationRate) * 0.5
            q = (q * Quaternion.exp(rotationVector: mean * dt)).normalized

            let estimated = alignment.pitch(attitude: q)
            let truth = source.truePitch(at: imu.time)
            worst = max(worst, abs(estimated - truth) * 180 / .pi)
        }

        XCTAssertLessThan(worst, 0.5,
            String(format: "recovered alignment reproduces pitch to only %.3f deg",
                   worst))
    }

    func testIdentityMountIsRecoveredAsIdentity() throws {
        guard case .success(let alignment) = solve(mount: .identity) else {
            return XCTFail("solver failed")
        }
        XCTAssertEqual(alignment.forwardInBody.x, 1, accuracy: 1e-9)
        XCTAssertEqual(alignment.forwardInBody.y, 0, accuracy: 1e-9)
        XCTAssertEqual(alignment.forwardInBody.z, 0, accuracy: 1e-9)
        XCTAssertEqual(alignment.upInBody.z, 1, accuracy: 1e-9)
        XCTAssertEqual(alignment.leftInBody.y, 1, accuracy: 1e-9)
    }

    func testSolvedAxesAreOrthonormalAndRightHanded() throws {
        guard case .success(let a) = solve(mount: crookedMount) else {
            return XCTFail("solver failed")
        }
        XCTAssertEqual(a.forwardInBody.magnitude, 1, accuracy: 1e-12)
        XCTAssertEqual(a.upInBody.magnitude, 1, accuracy: 1e-12)
        XCTAssertEqual(a.leftInBody.magnitude, 1, accuracy: 1e-12)
        XCTAssertEqual(a.forwardInBody.dot(a.upInBody), 0, accuracy: 1e-12)
        XCTAssertEqual(a.forwardInBody.dot(a.leftInBody), 0, accuracy: 1e-12)
        XCTAssertEqual(a.upInBody.dot(a.leftInBody), 0, accuracy: 1e-12)

        // forward x left == up, the same handedness Conventions declares.
        let cross = a.forwardInBody.cross(a.leftInBody)
        XCTAssertEqual(cross.x, a.upInBody.x, accuracy: 1e-12)
        XCTAssertEqual(cross.y, a.upInBody.y, accuracy: 1e-12)
        XCTAssertEqual(cross.z, a.upInBody.z, accuracy: 1e-12)
    }

    func testRollIsRecoveredThroughACrookedMount() throws {
        let mount = crookedMount
        guard case .success(let alignment) = solve(mount: mount) else {
            return XCTFail("solver failed")
        }
        // A bike rolled 20 deg right, seen through the mount.
        let bikeAttitude = Quaternion.exp(
            rotationVector: Vector3(20 * .pi / 180, 0, 0)).normalized
        // device->world = (bike->world) composed with (device->bike). Since
        // mountRotation maps bike components to device components, device->bike is
        // its conjugate.
        let deviceToBike = Quaternion(w: mount.w, x: -mount.x,
                                      y: -mount.y, z: -mount.z).normalized
        let deviceAttitude = (bikeAttitude * deviceToBike).normalized
        XCTAssertEqual(alignment.roll(attitude: deviceAttitude) * 180 / .pi,
                       20, accuracy: 0.5)
        // And pitch must stay near zero: roll does not leak into axis elevation.
        XCTAssertEqual(alignment.pitch(attitude: deviceAttitude) * 180 / .pi,
                       0, accuracy: 0.5)
    }

    // MARK: - Rejections

    func testGentlePullIsRejectedWithTheNumberAsked() {
        let result = solve(mount: crookedMount,
                           pullAcceleration: 0.15 * Conventions.g)
        guard case .failure(let failure) = result,
              case .pullTooWeak(let peak, let required) = failure else {
            return XCTFail("a 0.15 g pull must be rejected, got \(result)")
        }
        XCTAssertLessThan(peak, required)
        XCTAssertTrue(failure.message.contains("harder"))
    }

    func testPullTakenWhileBrakingIsRejectedAsNotPerpendicular() {
        // Deviation mostly along the DOWN axis: e.g. the rider hit a dip rather
        // than accelerating. The axes then are not perpendicular and the forward
        // direction would be fabricated by Gram-Schmidt.
        var config = Config()
        config.alignmentMaxResidual = 5.0 * .pi / 180
        var solver = AlignmentSolver(config: config, bikeProfileID: bike)
        for i in 0..<150 {
            solver.addRestSample(IMUSample(time: Double(i) / 100,
                                           rotationRate: .zero,
                                           specificForce: Conventions.restSpecificForce))
        }
        for i in 0..<60 {
            // Deviation straight down: 0.5 g of extra load, no forward component.
            let f = Vector3(0, 0, -Conventions.g - 0.5 * Conventions.g)
            solver.addPullSample(IMUSample(time: 2 + Double(i) / 100,
                                           rotationRate: .zero,
                                           specificForce: f))
        }
        guard case .failure(let failure) = solver.solve(),
              case .axesNotPerpendicular = failure else {
            return XCTFail("a purely vertical deviation must not define forward")
        }
        XCTAssertTrue(failure.message.contains("straight"))
    }

    func testMovingBikeContributesNoRestSamples() {
        var solver = AlignmentSolver(config: Config(), bikeProfileID: bike)
        // Rotating above the gate's limit: never admitted.
        for i in 0..<300 {
            solver.addRestSample(IMUSample(
                time: Double(i) / 100,
                rotationRate: Vector3(0, 0, 10 * .pi / 180),
                specificForce: Conventions.restSpecificForce))
        }
        XCTAssertEqual(solver.restSampleCount, 0)
        guard case .failure(let failure) = solver.solve(),
              case .notEnoughRestSamples = failure else {
            return XCTFail("expected notEnoughRestSamples")
        }
        XCTAssertTrue(failure.message.contains("still"))
    }

    func testSaturatedSamplesAreExcludedFromBothGestures() {
        var solver = AlignmentSolver(config: Config(), bikeProfileID: bike)
        for i in 0..<300 {
            solver.addRestSample(IMUSample(time: Double(i) / 100,
                                           rotationRate: .zero,
                                           specificForce: Conventions.restSpecificForce,
                                           saturated: true))
        }
        XCTAssertEqual(solver.restSampleCount, 0,
                       "a saturated axis has no usable direction")
    }

    func testTooFewPullSamplesIsReportedSeparately() {
        let result = solve(mount: .identity, pullSamples: 5)
        guard case .failure(let failure) = result,
              case .notEnoughPullSamples = failure else {
            return XCTFail("expected notEnoughPullSamples, got \(result)")
        }
        XCTAssertTrue(failure.message.contains("throttle"))
    }

    func testAlignmentRoundTripsThroughCoding() throws {
        guard case .success(let alignment) = solve(mount: crookedMount) else {
            return XCTFail("solver failed")
        }
        let data = try JSONEncoder().encode(alignment)
        let decoded = try JSONDecoder().decode(MountAlignment.self, from: data)
        XCTAssertEqual(alignment, decoded)
    }

    func testResidualIsReportedSoAFabricatedAxisIsVisible() throws {
        // Gram-Schmidt always yields an orthonormal set, so the residual is the
        // only way a caller can tell a clean solve from a rescued one.
        guard case .success(let clean) = solve(mount: crookedMount) else {
            return XCTFail("solver failed")
        }
        XCTAssertLessThan(clean.residual * 180 / .pi, 0.001,
                          "a level pull should be essentially perpendicular")
        XCTAssertGreaterThan(clean.peakPullAcceleration, 0.25 * Conventions.g)
    }
}
