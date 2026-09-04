import XCTest
@testable import MotoTelemetryCore

/// Regressions for the 2026-08-28 live-device log audit: the pre-anchor publish
/// guard, the stream-gap reset, the two-gate band split, and the re-anchor re-zero.
/// Every fixture below is taken from numbers the device log actually recorded.
///
/// REMOVED in the calibrate-once beta (their subject — `AttitudeESKF` and its
/// gravity-update path — was deleted with the ESKF, so there is nothing left to pin):
///   - testAnchorRejectsTheTiltedPoseFromTheDeviceLog / testAnchorStillAcceptsALevelPose
///     / testAnchorRefusesWhenTheGateIsClosed: the ESKF's magnitude-plus-level anchor
///     acceptance test. `CalibrateOnceEstimator` takes its anchor from calibration's
///     already-proven gravity vector and does no in-filter acceptance, so there is no
///     anchor-acceptance behaviour to regress.
///   - testYawBiasIsHeldRatherThanEstimatedOnAStationaryPhone: the ESKF's gravity
///     update and its in-filter bias re-estimation are both gone; bias is measured once
///     and held constant, so the "yaw bias must not be estimated" property has no
///     estimator to violate.
///   - testExplicitReanchorZeroesEvenABeyondLevelPose: its premise was that the filter
///     had TRACKED a 30 deg tilt (via the ESKF gravity update) before the re-anchor
///     zeroed it. `CalibrateOnceEstimator` excludes the accelerometer by design, so a
///     30 deg specific force with zero gyro moves the attitude not at all — the tilt is
///     never reached, and a re-anchor against it would zero a pose the estimator never
///     reported as tilted. The scenario is no longer meaningful, so the test is dropped
///     rather than rewritten to pin the inverted numbers.
/// The `coldFilter` / `openVerdict` helpers went with them.
final class DeviceLogAuditRegressionTests: XCTestCase {

    private let bike = UUID()
    private func alignment() -> MountAlignment { .identity(bikeProfileID: bike) }

    // MARK: - Bug 3b: publish nothing before an anchor exists

    /// The log has `pitchDeg=-89.7183` published into the pipeline 16 ms BEFORE
    /// `anchor acquired`. Attitude is identity then, so that number is the raw device
    /// axis, and nothing downstream can tell it from a real -89.7 deg. `Pipeline`
    /// still guards on `estimator.isAnchored`, so the property survives unchanged.
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
        if case .collecting(let elapsed, _, let samples, _) = afterGap {
            XCTAssertLessThan(elapsed, 0.5,
                              "post-gap accumulation must begin afresh, not resume near 8 s")
            XCTAssertLessThan(samples, 5,
                              "the sample count must restart with the window, not carry across the gap")
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

    // MARK: - Bug 3c: an explicit re-anchor re-levels while preserving heading

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
