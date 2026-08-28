import XCTest
@testable import MotoTelemetryCore

/// Regressions for the 2026-08-28 live-device log audit: the anchor validity test,
/// the pre-anchor publish guard, the unobservable yaw bias, and the stream-gap reset.
/// Every fixture below is taken from numbers the device log actually recorded.
final class DeviceLogAuditRegressionTests: XCTestCase {

    private let bike = UUID()
    private func alignment() -> MountAlignment { .identity(bikeProfileID: bike) }
    private let openVerdict = ValidityGate.Verdict(isOpen: true, heldFor: 1.0, reason: .open)

    private func coldFilter(_ config: Config = Config()) -> AttitudeESKF {
        AttitudeESKF(config: config,
                     alignment: alignment(),
                     initialBias: nil,
                     gravityAnchor: nil)          // deferred anchor: the live path
    }

    // MARK: - Bug 3: the anchor must not accept a tilted pose

    /// The exact bad anchor from the log: `gravity=(0.952, -4.805, -8.507)`,
    /// `|f| = 9.817`. Its magnitude sits squarely inside the +/-0.03 g band, which is
    /// why a magnitude-only test accepted it — and the app then reported a constant
    /// -27.87 deg while standing still. `asin(4.805/9.817) = 29.3 deg`.
    func testAnchorRejectsTheTiltedPoseFromTheDeviceLog() {
        var filter = coldFilter()
        let tilted = Vector3(0.952, -4.805, -8.507)

        XCTAssertEqual(tilted.magnitude, 9.817, accuracy: 0.002,
                       "fixture must keep the log's magnitude, which IS in band")
        let config = Config()
        XCTAssertGreaterThanOrEqual(tilted.magnitude, config.gateSpecificForceLow)
        XCTAssertLessThanOrEqual(tilted.magnitude, config.gateSpecificForceHigh)

        // Gate wide open — the ONLY thing that may reject this is the level test.
        for i in 1...200 {
            filter.propagate(IMUSample(time: Double(i) / 100,
                                       rotationRate: .zero,
                                       specificForce: tilted),
                             verdict: openVerdict)
        }
        XCTAssertFalse(filter.isAnchored,
                       "a 29.3 deg pose must never become the definition of level")
    }

    /// The counterpart: a genuinely level pose still anchors immediately, so the new
    /// test is not simply refusing everything.
    func testAnchorStillAcceptsALevelPose() {
        var filter = coldFilter()
        filter.propagate(IMUSample(time: 0.01,
                                   rotationRate: .zero,
                                   specificForce: Conventions.restSpecificForce),
                         verdict: openVerdict)
        XCTAssertTrue(filter.isAnchored)
        XCTAssertEqual(filter.pitch, 0, accuracy: 1e-9)
    }

    /// A level pose with the gate CLOSED must not anchor either: the gate carries the
    /// quiescence proof, and the estimator no longer reimplements a weaker version.
    func testAnchorRefusesWhenTheGateIsClosed() {
        var filter = coldFilter()
        let closed = ValidityGate.Verdict(isOpen: false, heldFor: 0, reason: .rotating)
        for i in 1...200 {
            filter.propagate(IMUSample(time: Double(i) / 100,
                                       rotationRate: .zero,
                                       specificForce: Conventions.restSpecificForce),
                             verdict: closed)
        }
        XCTAssertFalse(filter.isAnchored)
    }

    // MARK: - Bug 3b: publish nothing before an anchor exists

    /// The log has `pitchDeg=-89.7183` published into the pipeline 16 ms BEFORE
    /// `anchor acquired`. Attitude is identity then, so that number is the raw device
    /// axis, and nothing downstream can tell it from a real -89.7 deg.
    func testPipelinePublishesNothingBeforeAnAnchorExists() {
        var pipeline = Pipeline(config: Config(),
                               alignment: alignment(),
                               initialBias: nil,
                               gravityAnchor: nil)
        // Out-of-band force: no anchor can be taken from it, so no output may appear.
        let thrusting = Vector3(0, -6.0, -9.8)
        var outputs = 0
        for i in 1...300 {
            if pipeline.process(.imu(IMUSample(time: Double(i) / 100,
                                               rotationRate: .zero,
                                               specificForce: thrusting))) != nil {
                outputs += 1
            }
        }
        XCTAssertEqual(outputs, 0,
                       "no pitch may be published before the world frame is tied to gravity")
    }

    // MARK: - Bug 10: yaw bias is unobservable, so it must not be estimated

    /// On a desk, the log's bias-Z climbed monotonically 4.23 -> 5.05 deg/s against a
    /// measured truth of 0.111 — about 45x off and still rising. Gravity constrains
    /// only the two tilt axes, so there is no measurement that informs Z at all.
    func testYawBiasIsHeldRatherThanEstimatedOnAStationaryPhone() {
        let seeded = BiasEstimate(bias: Vector3(0, 0, 0.111 * .pi / 180),
                                 sigma: Vector3(1e-4, 1e-4, 1e-4),
                                 sampleCount: 800,
                                 monotonicTime: 0,
                                 bikeProfileID: bike)
        var filter = AttitudeESKF(config: Config(),
                                  alignment: alignment(),
                                  initialBias: seeded,
                                  gravityAnchor: Conventions.restSpecificForce)
        let start = filter.bias.z

        for i in 1...6000 {                      // 60 s of stationary gravity updates
            let sample = IMUSample(time: Double(i) / 100,
                                   rotationRate: Vector3(0, 0, 0.111 * .pi / 180),
                                   specificForce: Conventions.restSpecificForce)
            filter.propagate(sample, verdict: openVerdict)
            filter.updateWithGravity(sample, verdict: openVerdict)
        }

        XCTAssertEqual(filter.bias.z, start, accuracy: 1e-12,
                       "bias.z is unobservable from gravity and must not move")
        // X and Y stay observable — the fix must not disable the axes gravity does see.
        XCTAssertLessThan(abs(filter.bias.x), 0.05 * .pi / 180)
        XCTAssertLessThan(abs(filter.bias.y), 0.05 * .pi / 180)
    }

    // MARK: - Bug 6 remnant: a dead stream must not pool across the gap

    /// The log: the stream died for 19 s (Live tab left, tasks cancelled), then
    /// resumed, and the sample clock jumped straight past the 8-second requirement.
    /// The `n >= 400` floor already blocks a literal 25-sample finish; this pins the
    /// other axis, so a window already near 8 s cannot pool pre- and post-gap samples.
    func testStreamGapResetsAccumulationRatherThanPoolingAcrossIt() {
        var estimator = BiasEstimator(config: Config(), bikeProfileID: bike)
        let rest = Conventions.restSpecificForce
        let quiet = Vector3(0.003, -0.002, 0.001)

        var lastProgress: BiasEstimator.Progress?
        for i in 0..<250 {                       // 2.5 s: neither 8 s nor 400 samples
            lastProgress = estimator.process(IMUSample(time: Double(i) / 100,
                                                       rotationRate: quiet,
                                                       specificForce: rest))
        }
        if case .done = lastProgress { XCTFail("2.5 s cannot complete an 8 s zeroing") }

        // The stream dies for 19 s, then delivers 25 more quiet samples.
        var afterGap: BiasEstimator.Progress?
        for i in 0..<25 {
            afterGap = estimator.process(IMUSample(time: 2.49 + 19.0 + Double(i) / 100,
                                                   rotationRate: quiet,
                                                   specificForce: rest))
        }
        if case .done = afterGap {
            XCTFail("a 19 s stream gap forged a short finish — the exact device defect")
        }
        // And the window must have RESTARTED, not merely failed to complete.
        if case .collecting(let elapsed, _) = afterGap {
            XCTAssertLessThan(elapsed, 0.5,
                              "post-gap accumulation must begin afresh, not resume near 8 s")
        }
    }

    // MARK: - Bug 7: the two gates are deliberately different

    /// Calibration's band is wide so an idling bike can be zeroed; the estimator's
    /// stays tight because the same verdict gates the gravity update, where 0.3 g of
    /// thrust (|f| = 1.044 g) would otherwise be accepted as rest.
    func testCalibrationBandIsWiderThanTheEstimatorBand() {
        let c = Config()
        XCTAssertLessThan(c.calibrationSpecificForceLow, c.gateSpecificForceLow)
        XCTAssertGreaterThan(c.calibrationSpecificForceHigh, c.gateSpecificForceHigh)

        let thrust = Conventions.specificForce(pitch: 0, forwardAcceleration: 0.3 * Conventions.g)
        XCTAssertGreaterThan(thrust.magnitude, c.gateSpecificForceHigh,
                             "0.3 g thrust must stay OUT of the estimator band")
        XCTAssertLessThan(thrust.magnitude, c.calibrationSpecificForceHigh,
                          "the calibration band is looser by design — documents the trade-off")
    }

    // MARK: - Bug 3c: an explicit re-anchor zeroes the pose the rider declared level

    /// A cold anchor requires near-level because nobody declared anything. A
    /// re-anchor is a declaration ("I held the bike still in THIS pose"), so it must
    /// zero even a nose-down cradle — and it must actually reach 0, which requires
    /// re-levelling the alignment, not just the attitude.
    func testExplicitReanchorZeroesEvenABeyondLevelPose() {
        let config = Config()
        var pipeline = Pipeline(config: config,
                               alignment: alignment(),
                               initialBias: nil,
                               gravityAnchor: Conventions.restSpecificForce)
        let force = Conventions.specificForce(pitch: 30 * .pi / 180)
        var reported = 0.0
        var t = 0.0
        let dt = 1.0 / config.nominalSampleRate
        while t < 2.0 {
            if let out = pipeline.process(.imu(IMUSample(time: t, rotationRate: .zero,
                                                         specificForce: force))) {
                reported = out.pitch * 180 / .pi
            }
            t += dt
        }
        XCTAssertEqual(reported, 30, accuracy: 2.0, "the real tilt before re-anchor")

        pipeline.requestReanchor()
        while t < 4.0 {
            if let out = pipeline.process(.imu(IMUSample(time: t, rotationRate: .zero,
                                                         specificForce: force))) {
                reported = out.pitch * 180 / .pi
            }
            t += dt
        }
        XCTAssertEqual(reported, 0, accuracy: 0.01,
                       "a re-anchor must zero the pose the rider declared level")
    }

    /// Re-levelling keeps the forward HEADING rather than re-guessing it, which is
    /// what stops a re-anchor from silently reassigning which tilt is a wheelie.
    func testRelevellingPreservesForwardHeadingAndZeroesPitch() {
        // Identity alignment, so the fixture's frame matches `Conventions`: forward is
        // device +X and up is device +Z.
        let base = MountAlignment.identity(bikeProfileID: bike)
        let tilted = Conventions.specificForce(pitch: 15 * .pi / 180)
        let releveled = base.releveled(againstMeasuredGravity: tilted)

        XCTAssertEqual(releveled.upInBody.dot(releveled.forwardInBody), 0, accuracy: 1e-12,
                       "forward must be perpendicular to the measured up")
        XCTAssertEqual(releveled.forwardInBody.magnitude, 1, accuracy: 1e-12)
        // A 15 deg re-level may rotate forward by at most 15 deg (cos = 0.966): the
        // heading is preserved, not re-derived from a guess.
        XCTAssertGreaterThan(releveled.forwardInBody.dot(base.forwardInBody), 0.96,
                             "the heading must be preserved, not re-derived")
    }
}
