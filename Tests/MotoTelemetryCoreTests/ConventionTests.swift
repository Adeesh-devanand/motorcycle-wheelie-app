import XCTest
@testable import MotoTelemetryCore

/// The guard rail for Conventions.swift.
///
/// The package previously contained a frame contradiction that no existing test
/// could see: `SyntheticSource` emitted nose-up as a POSITIVE rotation about +Y
/// with a POSITIVE gravity x-component, while `AxisElevation` and its passing
/// roll-invariance test encode nose-up as a NEGATIVE rotation about +Y in a Z-up
/// world. The validity gate tests only |f| (1.000 g under either sign) and the
/// naive-tilt test uses atan2(fx, -fz) (sign-symmetric), so both passed happily
/// while an estimator built on the generator would have reported negative angles
/// for real wheelies.
///
/// These tests close that hole. `testIntegratedGyroTracksTruePitch` is the
/// important one: it is the end-to-end statement that the generator's gyro, the
/// quaternion exponential, and the pitch readout all agree about which way is up.
/// It must fail if either sign in SyntheticSource is reverted.
final class ConventionTests: XCTestCase {

    // MARK: - The forward model agrees with the quaternion

    func testRestSpecificForceMatchesTheQuaternionConvention() {
        // At every pitch, the modelled specific force must equal world gravity
        // rotated into the body frame by the attitude for that pitch. This is
        // the cross-check that the algebra in Conventions matches the rotation
        // code rather than merely looking plausible.
        for degrees in [0.0, 10.0, 30.0, 45.0, 55.0, 70.0, 90.0, -15.0] {
            let pitch = degrees * .pi / 180
            let q = Conventions.attitude(nosUpBy: pitch)

            // R^T applied to world gravity == inverse rotation of the vector.
            let inverse = Quaternion(w: q.w, x: -q.x, y: -q.y, z: -q.z)
            let expected = inverse.rotate(Conventions.worldGravity)
            let modelled = Conventions.specificForce(pitch: pitch)

            XCTAssertEqual(modelled.x, expected.x, accuracy: 1e-9,
                           "gravity x disagrees at \(degrees) deg")
            XCTAssertEqual(modelled.y, expected.y, accuracy: 1e-9)
            XCTAssertEqual(modelled.z, expected.z, accuracy: 1e-9,
                           "gravity z disagrees at \(degrees) deg")
        }
    }

    func testLevelRestMatchesTheValidityGateFixture() {
        // ValidityGateTests.level(_:) uses (0, 0, -g); Conventions must agree or
        // the gate and the estimator are in different frames.
        let f = Conventions.specificForce(pitch: 0)
        XCTAssertEqual(f.x, 0, accuracy: 1e-12)
        XCTAssertEqual(f.z, -Conventions.g, accuracy: 1e-12)
        XCTAssertEqual(f.magnitude, Conventions.g, accuracy: 1e-12)
    }

    func testNoseUpGivesANegativeGravityXComponent() {
        // The specific defect: the old generator had this POSITIVE.
        let f = Conventions.specificForce(pitch: 30 * .pi / 180)
        XCTAssertLessThan(f.x, 0,
            "nose-up must tilt apparent gravity toward the REAR (-x). A positive "
            + "value here is the aerospace/Z-down convention and is the bug.")
        XCTAssertEqual(f.x, -Conventions.g * 0.5, accuracy: 1e-9)
    }

    func testAxisElevationRecoversPitchFromTheModelledAttitude() {
        for degrees in [0.0, 12.0, 33.0, 48.0, 62.0, 85.0] {
            let pitch = degrees * .pi / 180
            let q = Conventions.attitude(nosUpBy: pitch)
            let read = AxisElevation.pitch(attitude: q,
                                           forwardInBody: Conventions.bikeForward)
            XCTAssertEqual(read, pitch, accuracy: 1e-9,
                           "pitch readout disagrees at \(degrees) deg")
        }
    }

    func testBikeFrameIsRightHanded() {
        let cross = Conventions.bikeForward.cross(Conventions.bikeLeft)
        XCTAssertEqual(cross.x, Conventions.bikeUp.x, accuracy: 1e-12)
        XCTAssertEqual(cross.y, Conventions.bikeUp.y, accuracy: 1e-12)
        XCTAssertEqual(cross.z, Conventions.bikeUp.z, accuracy: 1e-12)
    }

    // MARK: - The generator agrees with the pipeline

    /// THE guard test. Integrate the generator's own gyro stream from identity
    /// through Quaternion.exp, read pitch with AxisElevation, and compare against
    /// the generator's declared ground truth. Bias-free and vibration-free, so
    /// the only thing under test is the frame convention.
    ///
    /// Integration uses the MID-POINT rule (average of consecutive rates), which
    /// is the propagation rule the ESKF will use. A right-endpoint rectangular
    /// rule leaves ~0.28 deg of integrator error on the ramps, which would mask
    /// the thing this test exists to measure.
    func testIntegratedGyroTracksTruePitch() {
        var scenario = SyntheticSource.Scenario()
        scenario.gyroBias = .zero
        scenario.vibrationAmplitude = 0
        scenario.emitGNSS = false
        var source = SyntheticSource(scenario: scenario)

        var q = Quaternion.identity
        var lastTime: TimeInterval?
        var lastRate: Vector3?
        var worstError = 0.0
        var worstAt = 0.0
        var sawMotion = false

        while let sample = source.next() {
            guard case .imu(let imu) = sample else { continue }
            defer { lastTime = imu.time; lastRate = imu.rotationRate }
            guard let previous = lastTime, let previousRate = lastRate else { continue }

            let dt = imu.time - previous
            let meanRate = (previousRate + imu.rotationRate) * 0.5
            q = (q * Quaternion.exp(rotationVector: meanRate * dt)).normalized

            let estimated = AxisElevation.pitch(attitude: q,
                                                forwardInBody: Conventions.bikeForward)
            let truth = source.truePitch(at: imu.time)
            if abs(truth) > 1e-6 { sawMotion = true }

            let error = abs(estimated - truth) * 180 / .pi
            if error > worstError { worstError = error; worstAt = imu.time }
        }

        XCTAssertTrue(sawMotion, "scenario produced no pitch to track")
        XCTAssertLessThan(worstError, 0.1,
            String(format: "integrated gyro diverges from truth by %.4f deg at "
                   + "t=%.2f s. If this is roughly 2x the true pitch, the "
                   + "generator's gyro sign is inverted relative to "
                   + "Quaternion.exp — see Conventions.swift.",
                   worstError, worstAt))
    }

    /// The generator's specific force must be the same forward model the
    /// estimator will invert, at every point of the scenario — including while
    /// thrust is present, which is where the two frames diverged.
    func testGeneratedSpecificForceMatchesTheForwardModel() {
        var scenario = SyntheticSource.Scenario()
        scenario.vibrationAmplitude = 0
        scenario.emitGNSS = false
        var source = SyntheticSource(scenario: scenario)

        var checked = 0
        while let sample = source.next() {
            guard case .imu(let imu) = sample else { continue }
            let pitch = source.truePitch(at: imu.time)
            let thrust = Conventions.g * tan(min(pitch, 60 * .pi / 180))
            let expected = Conventions.specificForce(pitch: pitch,
                                                     forwardAcceleration: thrust)
            XCTAssertEqual(imu.specificForce.x, expected.x, accuracy: 1e-9)
            XCTAssertEqual(imu.specificForce.z, expected.z, accuracy: 1e-9)
            checked += 1
        }
        XCTAssertGreaterThan(checked, 1000)
    }

    /// A wheelie must produce a negative y rate under this convention. Stated
    /// separately so the failure message is unambiguous.
    func testWheelieProducesNegativeYawRateAboutY() {
        var scenario = SyntheticSource.Scenario()
        scenario.gyroBias = .zero
        scenario.emitGNSS = false
        var source = SyntheticSource(scenario: scenario)

        var sawRising = false
        while let sample = source.next() {
            guard case .imu(let imu) = sample else { continue }
            // During the rise the true pitch rate is positive.
            if source.truePitchRate(at: imu.time) > 0.2 {
                sawRising = true
                XCTAssertLessThan(imu.rotationRate.y, 0,
                    "nose-up must be a NEGATIVE rotation about +Y")
            }
        }
        XCTAssertTrue(sawRising)
    }

    /// The pre-existing test that could not see the defect. Kept and asserted
    /// here as documentation: it must remain passing after the sign fix, because
    /// atan2(fx, -fz) is sign-symmetric. If this breaks, the fix was wrong.
    func testNaiveTiltTestIsSignSymmetricAndStillPasses() {
        var scenario = SyntheticSource.Scenario()
        scenario.peakPitch = 45 * .pi / 180
        var source = SyntheticSource(scenario: scenario)

        var worst = 0.0
        while let sample = source.next() {
            guard case .imu(let imu) = sample else { continue }
            let truth = source.truePitch(at: imu.time)
            guard truth > 1e-6 else { continue }
            let naive = atan2(imu.specificForce.x, -imu.specificForce.z)
            worst = max(worst, abs(naive - truth))
        }
        XCTAssertGreaterThan(worst * 180 / .pi, 10.0)
    }
}
