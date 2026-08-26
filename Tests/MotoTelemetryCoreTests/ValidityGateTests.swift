import XCTest
@testable import MotoTelemetryCore

final class ValidityGateTests: XCTestCase {
    let g = 9.80665

    private func level(_ t: TimeInterval) -> IMUSample {
        IMUSample(time: t, rotationRate: .zero, specificForce: Vector3(0, 0, -9.80665))
    }

    func testGateOpensOnlyAfterDwell() {
        var gate = ValidityGate(config: Config())
        // Before the dwell elapses it must stay shut.
        XCTAssertEqual(gate.process(level(0.0))?.isOpen, false)
        XCTAssertEqual(gate.process(level(0.3))?.isOpen, false)
        // At 0.5 s of continuous quiet it may open.
        XCTAssertEqual(gate.process(level(0.5))?.isOpen, true)
    }

    func testLeanIsRejected() {
        var gate = ValidityGate(config: Config())
        _ = gate.process(level(0.0))
        _ = gate.process(level(0.6))
        // A 30 deg lean gives |a| = g/cos(30) = 1.15 g — outside the band.
        let leaned = IMUSample(time: 1.0, rotationRate: .zero,
                               specificForce: Vector3(0, 0, -g / cos(30 * .pi / 180)))
        let v = gate.process(leaned)
        XCTAssertEqual(v?.isOpen, false)
        XCTAssertEqual(v?.reason, .specificForceOutOfBand)
    }

    func testTurningIsRejected() {
        var gate = ValidityGate(config: Config())
        _ = gate.process(level(0.0))
        _ = gate.process(level(0.6))
        // Yaw rate above the limit means we are turning, not cruising level.
        let turning = IMUSample(time: 1.0,
                                rotationRate: Vector3(0, 0, 10 * .pi / 180),
                                specificForce: Vector3(0, 0, -g))
        let v = gate.process(turning)
        XCTAssertEqual(v?.isOpen, false)
        XCTAssertEqual(v?.reason, .rotating)
    }

    func testSaturatedSampleNeverOpensGate() {
        var gate = ValidityGate(config: Config())
        _ = gate.process(level(0.0))
        _ = gate.process(level(0.6))
        let sat = IMUSample(time: 1.0, rotationRate: .zero,
                            specificForce: Vector3(0, 0, -g), saturated: true)
        XCTAssertEqual(gate.process(sat)?.reason, .saturated)
    }
}

final class AxisElevationTests: XCTestCase {

    func testPitchIsIndependentOfRoll() {
        let forward = Vector3(1, 0, 0)
        // 30 deg nose-up about the body Y axis.
        let pitchUp = Quaternion.exp(rotationVector: Vector3(0, 30 * .pi / 180, 0))
        let base = AxisElevation.pitch(attitude: pitchUp, forwardInBody: forward)
        XCTAssertEqual(base, 30 * .pi / 180, accuracy: 1e-9)

        // Now roll about the FORWARD axis. Axis elevation must not move —
        // this is the property Euler pitch does not have.
        for degrees in [10.0, 25.0, 40.0, -35.0] {
            let roll = Quaternion.exp(rotationVector: Vector3(degrees * .pi / 180, 0, 0))
            let combined = (pitchUp * roll).normalized
            let p = AxisElevation.pitch(attitude: combined, forwardInBody: forward)
            XCTAssertEqual(p, base, accuracy: 1e-9,
                           "roll of \(degrees) deg leaked into pitch")
        }
    }

    func testTimeToThreshold() {
        // 10 deg short of target, closing at 25 deg/s -> 0.4 s.
        let ttt = AxisElevation.timeToThreshold(current: 35 * .pi / 180,
                                                rate: 25 * .pi / 180,
                                                target: 45 * .pi / 180)
        XCTAssertEqual(ttt!, 0.4, accuracy: 1e-9)
        // Not closing -> no warning.
        XCTAssertNil(AxisElevation.timeToThreshold(current: 35 * .pi / 180,
                                                    rate: -5 * .pi / 180,
                                                    target: 45 * .pi / 180))
        // Already past -> no warning from this channel.
        XCTAssertNil(AxisElevation.timeToThreshold(current: 50 * .pi / 180,
                                                    rate: 5 * .pi / 180,
                                                    target: 45 * .pi / 180))
    }
}

final class SyntheticSourceTests: XCTestCase {

    func testGeneratesMonotonicStreamWithKnownTruth() {
        var s = SyntheticSource()
        var last = -1.0
        var count = 0
        var sawPeak = false
        while let m = s.next() {
            XCTAssertGreaterThanOrEqual(m.time, last)
            last = m.time
            count += 1
            if case .imu = m, abs(s.truePitch(at: m.time) - s.scenario.peakPitch) < 1e-9 {
                sawPeak = true
            }
        }
        XCTAssertGreaterThan(count, 1000)
        XCTAssertTrue(sawPeak, "scenario never reached its stated peak pitch")
    }

    func testAccelerometerAloneIsBadlyWrongDuringTheEvent() {
        // Demonstrates the confound the whole product exists to solve: naive
        // tilt-from-accelerometer during a wheelie is wildly optimistic.
        var scenario = SyntheticSource.Scenario()
        scenario.peakPitch = 45 * .pi / 180
        var s = SyntheticSource(scenario: scenario)

        var worstError = 0.0
        while let m = s.next() {
            guard case .imu(let imu) = m else { continue }
            let truth = s.truePitch(at: imu.time)
            guard truth > 1e-6 else { continue }
            let naive = atan2(imu.specificForce.x, -imu.specificForce.z)
            worstError = max(worstError, abs(naive - truth))
        }
        // Expect tens of degrees of error, not a few.
        XCTAssertGreaterThan(worstError * 180 / .pi, 15.0)
    }
}
