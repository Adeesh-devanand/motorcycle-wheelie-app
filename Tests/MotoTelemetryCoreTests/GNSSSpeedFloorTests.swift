import XCTest
@testable import MotoTelemetryCore

/// A stationary phone lifted off a table displayed 3 km/h. The 2026-09-09 device log
/// carries the fix that did it:
///
///     speed heartbeat speed=1.0199999809265137 speedAcc=1.6399999856948853 hAcc=7.83
///
/// 1.02 m/s is 3.67 km/h, and the receiver's OWN error bound on that number is
/// 1.64 m/s — larger than the reading. The fix does not say "moving at 3.7 km/h", it
/// says "somewhere between stopped and 9.6 km/h", and `isSpeedValid` (a bare
/// `speed >= 0`) admitted it because CoreLocation had produced *a* Doppler solution.
///
/// These tests pin `resolvedSpeed`. The threshold is the receiver's own accuracy
/// figure, so there is no constant here to loosen later: anyone tempted to "allow a
/// bit more GNSS noise" would have to break the comparison itself.
final class GNSSSpeedFloorTests: XCTestCase {

    private let bike = UUID()

    private func fix(speed: Double, accuracy: Double, at t: TimeInterval = 1) -> GNSSFix {
        GNSSFix(fixTime: t, arrivalTime: t, speed: speed, speedAccuracy: accuracy,
                horizontalAccuracy: 7.83)
    }

    // MARK: - The reading from the log

    func testTheLiftedPhoneFixFromTheDeviceLogReportsZero() {
        let lifted = fix(speed: 1.0199999809265137, accuracy: 1.6399999856948853)
        XCTAssertEqual(lifted.resolvedSpeed, 0,
                       "a Doppler reading smaller than its own error bound is not evidence of motion")
    }

    /// Two more fixes from the same session, both consistent with rest.
    func testTheOtherRestFixesFromTheSameSessionAlsoReportZero() {
        XCTAssertEqual(fix(speed: 0.18000000715255737, accuracy: 0.699999988079071).resolvedSpeed, 0)
        XCTAssertEqual(fix(speed: 0.17000000178813934, accuracy: 0.6499999761581421).resolvedSpeed, 0)
    }

    // MARK: - What must still get through

    /// The whole point of the speedometer. A riding speed is many times its own
    /// accuracy and must pass through untouched — a floor that suppressed this would
    /// be worse than the bug it fixed.
    func testARidingSpeedPassesThroughUnchanged() {
        XCTAssertEqual(fix(speed: 16.7, accuracy: 0.9).resolvedSpeed, 16.7)
    }

    /// Equality is admitted, not floored: at `speed == speedAccuracy` the receiver is
    /// no longer claiming the reading could be zero.
    func testAReadingExactlyAtItsAccuracyIsAdmitted() {
        XCTAssertEqual(fix(speed: 1.19, accuracy: 1.19).resolvedSpeed, 1.19)
    }

    // MARK: - The two "no answer" cases stay distinct

    /// `speed < 0` is CoreLocation saying it has no Doppler solution at all. That is
    /// UNAVAILABLE, not zero — R15.3 forbids fabricating a 0 there, and nil is what
    /// keeps `Pipeline`'s speed `nil` so the UI can show a dash.
    func testNoDopplerSolutionStaysUnavailableRatherThanBecomingZero() {
        XCTAssertNil(fix(speed: -1, accuracy: -1).resolvedSpeed)
        XCTAssertNil(fix(speed: -1, accuracy: 0.5).resolvedSpeed)
    }

    /// A valid speed with an UNKNOWN accuracy has no bound to test against. Passing it
    /// through is the honest choice: flooring it would invent a zero from the absence
    /// of information, which is the same fabrication in the other direction.
    func testAValidSpeedWithUnknownAccuracyIsNotFloored() {
        XCTAssertEqual(fix(speed: 1.02, accuracy: -1).resolvedSpeed, 1.02)
    }

    // MARK: - The pipeline honours it

    /// End to end, because the display and the recorded samples both read
    /// `PipelineOutput.speed` — fixing only `GNSSFix` would leave the bug live if the
    /// `.gnss` branch still went to `fix.speed`.
    func testPipelineReportsZeroForARestFixAndTheRealValueForARidingFix() {
        let zeroBias = BiasEstimate(bias: .zero,
                                    sigma: Vector3(1e-4, 1e-4, 1e-4),
                                    sampleCount: 200,
                                    monotonicTime: 0,
                                    bikeProfileID: bike)
        var pipeline = Pipeline(config: Config(),
                                alignment: .identity(bikeProfileID: bike),
                                initialBias: zeroBias,
                                gravityAnchor: Conventions.restSpecificForce)

        func pitchTick(_ i: Int) -> PipelineOutput? {
            let imu = IMUSample(time: Double(i) / 100,
                                rotationRate: .zero,
                                specificForce: Conventions.restSpecificForce)
            return pipeline.process(Sample.imu(imu))
        }

        _ = pitchTick(1)
        _ = pipeline.process(Sample.gnss(fix(speed: 1.0199999809265137,
                                             accuracy: 1.6399999856948853, at: 0.015)))
        XCTAssertEqual(pitchTick(2)?.speed, 0,
                       "the lifted-phone fix must reach the display as 0, not 3.7 km/h")

        _ = pipeline.process(Sample.gnss(fix(speed: 16.7, accuracy: 0.9, at: 0.025)))
        XCTAssertEqual(pitchTick(3)?.speed, 16.7,
                       "a real riding speed must still reach the display")
    }
}
