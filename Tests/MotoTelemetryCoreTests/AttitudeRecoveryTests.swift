import XCTest
@testable import MotoTelemetryCore

final class AttitudeRecoveryTests: XCTestCase {
    private let radians = Double.pi / 180

    private func inverse(_ q: Quaternion) -> Quaternion {
        Quaternion(w: q.w, x: -q.x, y: -q.y, z: -q.z)
    }

    func testObliqueMountPreservesSwipeProjectionAndRejectsBothLeans() {
        // Compound mount rotation: the previous projection silently changed heading.
        for x in [-55.0, -25, 25, 55] {
            for y in [-35.0, 35] {
                let mount = Quaternion.exp(rotationVector: Vector3(x * radians, y * radians, 0.4))
                let bodyFromBike = inverse(mount)
                let forward = bodyFromBike.rotate(Conventions.bikeForward)
                let gravity = bodyFromBike.rotate(Conventions.worldGravity)
                let alignment = MountAlignment.fromMeasuredGravity(specificForce: gravity,
                    screenYaw: atan2(forward.y, forward.x))
                XCTAssertGreaterThan(alignment.forwardInBody.dot(forward), 0.999999)
                for lean in [-50.0, -30, 0, 30, 50] {
                    for heading in [0.0, 80, 160] {
                        let yaw = Quaternion.exp(rotationVector: Vector3(0, 0, heading * radians))
                        let roll = Quaternion.exp(rotationVector: Vector3(lean * radians, 0, 0))
                        XCTAssertEqual(alignment.pitch(attitude: yaw * roll * mount), 0, accuracy: 1e-9)
                        let pitch = Quaternion.exp(rotationVector: Vector3(0, -42 * radians, 0))
                        XCTAssertEqual(alignment.pitch(attitude: yaw * pitch * roll * mount),
                                       42 * radians, accuracy: 1e-9)
                    }
                }
            }
        }
    }

    func testIntegratedBankedTurnDoesNotProduceWheelie() {
        let mount = Quaternion.exp(rotationVector: Vector3(0.7, 0.4, -0.3))
        let inv = inverse(mount)
        let f = inv.rotate(Conventions.bikeForward)
        let gravity = inv.rotate(Conventions.worldGravity)
        let alignment = MountAlignment.fromMeasuredGravity(specificForce: gravity,
            screenYaw: atan2(f.y, f.x))
        for sign in [-1.0, 1] {
            var estimator = CalibrateOnceEstimator(config: Config(), alignment: alignment,
                bias: .zero, gravityAnchor: gravity)
            var previous = mount
            for i in 0...1000 {
                let t = Double(i) * 0.01
                let lean = sign * min(t, 1) * 40 * radians
                let yaw = max(0, t - 1) * sign * 12 * radians
                let pose = Quaternion.exp(rotationVector: Vector3(0, 0, yaw))
                    * Quaternion.exp(rotationVector: Vector3(lean, 0, 0)) * mount
                let delta = (inverse(previous) * pose).normalized
                let vectorLength = Vector3(delta.x, delta.y, delta.z).magnitude
                let angle = 2 * atan2(vectorLength, delta.w)
                let rate = vectorLength > 1e-12
                    ? Vector3(delta.x, delta.y, delta.z) * (angle / vectorLength / 0.01) : .zero
                estimator.integrate(IMUSample(time: t, rotationRate: rate,
                    specificForce: inverse(pose).rotate(Conventions.worldGravity)))
                XCTAssertEqual(estimator.pitch, 0, accuracy: 1e-8)
                previous = pose
            }
        }
    }

    private func pipeline() -> Pipeline {
        Pipeline(config: Config(), alignment: .identity(),
                 initialBias: BiasEstimate(bias: .zero, sigma: Vector3(0.0001, 0.0001, 0.0001),
                     sampleCount: 200, monotonicTime: 0, bikeProfileID: UUID()),
                 gravityAnchor: Conventions.worldGravity)
    }

    func testStopRecoveryBoundsSlowThermalDriftAndPublishesUpdatedBias() throws {
        for sign in [-1.0, 1] {
            var p = pipeline()
            var latest: PipelineOutput?
            var maximumPitch = 0.0
            for i in 0...18000 {
                let t = Double(i) * 0.01
                if i % 100 == 0 {
                    _ = p.process(.gnss(GNSSFix(fixTime: t, arrivalTime: t,
                        speed: 0, speedAccuracy: 0.1)))
                }
                // Warm-up walks the pitch-axis bias from 0 to 0.15 deg/s.
                let bias = Vector3(0, sign * min(t / 120, 1) * 0.15 * radians, 0)
                latest = p.process(.imu(IMUSample(time: t, rotationRate: bias,
                    specificForce: Conventions.worldGravity)))
                maximumPitch = max(maximumPitch, abs(latest?.pitchDegrees ?? 0))
            }
            XCTAssertGreaterThan(p.stationaryCorrectionCount, 40)
            XCTAssertLessThan(maximumPitch, 0.1)
            XCTAssertEqual(try XCTUnwrap(latest).gyroBias.y, sign * 0.15 * radians, accuracy: 1e-8)
            XCTAssertEqual(try XCTUnwrap(latest).pitchDegrees, 0, accuracy: 1e-7)
        }
    }

    func testRecoveryDoesNotFlattenStationarySlopeOrLean() throws {
        var p = pipeline()
        let pose = Quaternion.exp(rotationVector: Vector3(0, -12 * radians, 0))
            * Quaternion.exp(rotationVector: Vector3(25 * radians, 0, 0))
        let force = inverse(pose).rotate(Conventions.worldGravity)
        var latest: PipelineOutput?
        for i in 0...400 {
            let t = Double(i) * 0.01
            if i % 100 == 0 {
                _ = p.process(.gnss(GNSSFix(fixTime: t, arrivalTime: t, speed: 0, speedAccuracy: 0.1)))
            }
            latest = p.process(.imu(IMUSample(time: t, rotationRate: .zero, specificForce: force)))
        }
        XCTAssertEqual(p.stationaryCorrectionCount, 1)
        XCTAssertEqual(try XCTUnwrap(latest).pitchDegrees, 12, accuracy: 1e-8)
        XCTAssertEqual(abs(try XCTUnwrap(latest).roll) / radians, 25, accuracy: 1e-8)
    }

    func testRecoveryBlockedDuringMotionOrUnreliableData() {
        for scenario in ["moving", "unknownAccuracy", "poorAccuracy", "displayZero", "missingGPS",
                         "staleGPS", "futureGPS", "acceleration", "turn", "slowTilt", "vibration", "event", "saturation", "gaps"] {
            var p = pipeline()
            p.eventActive = scenario == "event"
            for i in 0...700 {
                let t = Double(i) * (scenario == "gaps" ? 0.2 : 0.01)
                if i % 100 == 0 && scenario != "missingGPS" {
                    let time = scenario == "staleGPS" ? t - 5 : (scenario == "futureGPS" ? t + 5 : t)
                    _ = p.process(.gnss(GNSSFix(fixTime: time, arrivalTime: time,
                        speed: scenario == "moving" ? 20 : (scenario == "displayZero" ? 1 : 0),
                        speedAccuracy: scenario == "unknownAccuracy" ? -1 :
                            (["poorAccuracy", "displayZero"].contains(scenario) ? 2 : 0.1))))
                }
                var force = Conventions.worldGravity
                if scenario == "acceleration" { force = force + Vector3(4, 0, 0) }
                if scenario == "vibration" { force.z += i % 2 == 0 ? 0.1 : -0.1 }
                if scenario == "slowTilt" {
                    force = Conventions.specificForce(pitch: t * 0.2 * radians)
                }
                let rate = scenario == "turn" ? Vector3(0, 0, 0.1) : .zero
                _ = p.process(.imu(IMUSample(time: t, rotationRate: rate,
                    specificForce: force, saturated: scenario == "saturation")))
            }
            XCTAssertEqual(p.stationaryCorrectionCount, 0, scenario)
        }
    }

    func testClearSpeedDiscardsPartiallyCollectedStop() {
        var p = pipeline()
        for i in 0...400 {
            let t = Double(i) * 0.01
            if i % 100 == 0 && i <= 200 {
                _ = p.process(.gnss(GNSSFix(fixTime: t, arrivalTime: t, speed: 0, speedAccuracy: 0.1)))
            }
            if i == 250 { p.clearSpeed() }
            _ = p.process(.imu(IMUSample(time: t, rotationRate: .zero,
                specificForce: Conventions.worldGravity)))
        }
        XCTAssertEqual(p.stationaryCorrectionCount, 0)
    }
}
