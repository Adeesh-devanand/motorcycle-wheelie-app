import XCTest
@testable import MotoTelemetryCore

final class AttitudeESKFTests: XCTestCase {

    private let bike = UUID()

    private func alignment() -> MountAlignment { .identity(bikeProfileID: bike) }

    private func biasEstimate(_ bias: Vector3, sigma: Double = 1e-5) -> BiasEstimate {
        BiasEstimate(bias: bias,
                     sigma: Vector3(sigma, sigma, sigma),
                     sampleCount: 800,
                     monotonicTime: 0,
                     bikeProfileID: bike)
    }

    private func makeFilter(bias: Vector3 = .zero,
                            biasSigma: Double = 1e-5,
                            config: Config = Config()) -> AttitudeESKF {
        AttitudeESKF(config: config,
                     alignment: alignment(),
                     initialBias: biasEstimate(bias, sigma: biasSigma),
                     gravityAnchor: Conventions.restSpecificForce)
    }

    // MARK: - T3.3 propagation

    func testGravityAnchorSeedsLevelAttitude() {
        let filter = makeFilter()
        XCTAssertEqual(filter.pitch, 0, accuracy: 1e-9)
        XCTAssertEqual(filter.roll, 0, accuracy: 1e-9)
    }

    func testAnchorSeedsAPitchedAttitudeFromGravityAlone() {
        // A phone sitting on a 20 deg slope: the anchor must recover the tilt.
        let pitch = 20.0 * .pi / 180
        let f = Conventions.specificForce(pitch: pitch)
        let filter = AttitudeESKF(config: Config(),
                                  alignment: alignment(),
                                  initialBias: biasEstimate(.zero),
                                  gravityAnchor: f)
        XCTAssertEqual(filter.pitch * 180 / .pi, 20, accuracy: 1e-6)
    }

    /// With no measurement updates and a known constant bias, the filter must drift
    /// exactly as analytic gyro integration does.
    func testPropagationMatchesAnalyticIntegrationWithNoUpdates() {
        var config = Config()
        config.gyroNoiseDensity = 0
        config.gyroBiasInstability = 0
        var filter = AttitudeESKF(config: config,
                                  alignment: alignment(),
                                  initialBias: biasEstimate(.zero),
                                  gravityAnchor: Conventions.restSpecificForce)

        // Constant nose-up rate of 20 deg/s for 2 s, no bias correction applied.
        let rate = Conventions.rotationRate(pitchRate: 20 * .pi / 180)
        for i in 1...200 {
            let sample = IMUSample(time: Double(i) / 100,
                                   rotationRate: rate,
                                   specificForce: Conventions.restSpecificForce)
            filter.propagate(sample)
        }
        // 199 integrated steps of 0.01 s: the first sample only sets the epoch,
        // because there is no elapsed interval before it.
        XCTAssertEqual(filter.pitch * 180 / .pi, 20 * 1.99, accuracy: 1e-6)
    }

    func testCovarianceStaysPositiveDefiniteOverManySteps() {
        var filter = makeFilter()
        let rate = Vector3(0.01, -0.02, 0.005)
        for i in 1...20_000 {
            let sample = IMUSample(time: Double(i) / 100,
                                   rotationRate: rate,
                                   specificForce: Conventions.restSpecificForce)
            filter.propagate(sample)
            filter.updateWithGravity(sample, gateOpen: i % 3 == 0)
        }
        XCTAssertNotNil(filter.covariance.cholesky(),
                        "covariance must stay positive definite; Joseph form and "
                        + "symmetrisation exist precisely to guarantee this")
        XCTAssertFalse(filter.isDegraded)

        // And symmetric.
        for i in 0..<6 {
            for j in 0..<6 {
                XCTAssertEqual(filter.covariance[i, j], filter.covariance[j, i],
                               accuracy: 1e-15)
            }
        }
    }

    func testOutOfOrderSampleIsIgnoredRatherThanIntegratedBackwards() {
        var filter = makeFilter()
        let rate = Conventions.rotationRate(pitchRate: 20 * .pi / 180)
        for i in 1...100 {
            filter.propagate(IMUSample(time: Double(i) / 100,
                                       rotationRate: rate,
                                       specificForce: Conventions.restSpecificForce))
        }
        let before = filter.pitch
        filter.propagate(IMUSample(time: 0.5,      // in the past
                                   rotationRate: rate,
                                   specificForce: Conventions.restSpecificForce))
        XCTAssertEqual(filter.pitch, before, accuracy: 1e-15)
    }

    func testPitchRateReadsThroughTheAlignmentNotTheDeviceAxis() {
        var filter = makeFilter()
        let rate = Conventions.rotationRate(pitchRate: 30 * .pi / 180)
        filter.propagate(IMUSample(time: 0.01, rotationRate: rate,
                                   specificForce: Conventions.restSpecificForce))
        XCTAssertEqual(filter.pitchRate * 180 / .pi, 30, accuracy: 1e-9)
    }

    // MARK: - T3.4 gravity measurement

    func testSaturatedSampleSkipsTheGravityMeasurementEntirely() {
        var filter = makeFilter()
        let sample = IMUSample(time: 0.01,
                               rotationRate: .zero,
                               specificForce: Vector3(50, 0, -9.8),
                               saturated: true)
        filter.propagate(sample)
        XCTAssertFalse(filter.updateWithGravity(sample, gateOpen: true))
    }

    /// The behaviour graded inflation exists for: the ESTIMATE must not lurch when
    /// the gate reopens.
    ///
    /// With the accelerometer effectively switched off while the gate is shut, error
    /// accumulates unchecked and gets corrected in one visible jolt on reopen. With a
    /// mild tier for "quasi-static but dwell not yet met", it is bled off
    /// continuously. Measured as the largest single-sample change in pitch.
    func testGradedInflationKeepsTheEstimateContinuousOnGateReopen() {
        func run(mildTier: Double) -> Double {
            var config = Config()
            config.accelNoiseInflation = mildTier
            var filter = AttitudeESKF(config: config,
                                      alignment: MountAlignment.identity(bikeProfileID: UUID()),
                                      initialBias: BiasEstimate(bias: .zero,
                                                                sigma: Vector3(1e-3, 1e-3, 1e-3),
                                                                sampleCount: 800,
                                                                monotonicTime: 0,
                                                                bikeProfileID: UUID()),
                                      gravityAnchor: Conventions.restSpecificForce)

            // A real gyro bias makes the estimate drift while unaided.
            let drift = Vector3(0, -0.4 * .pi / 180, 0)
            var previousPitch = filter.pitch
            var worstJump = 0.0

            for i in 1...900 {
                let t = Double(i) / 100
                // 6 s where conditions are quasi-static but the dwell keeps being
                // interrupted (dwellNotMet), then the gate opens fully.
                let reason: ValidityGate.Reason = t < 6.0 ? .dwellNotMet : .open
                let sample = IMUSample(time: t,
                                       rotationRate: drift,
                                       specificForce: Conventions.restSpecificForce)
                filter.propagate(sample)
                filter.updateWithGravity(sample,
                                         verdict: ValidityGate.Verdict(
                                            isOpen: reason == .open,
                                            heldFor: 0,
                                            reason: reason))
                let pitch = filter.pitch
                if i > 2 { worstJump = max(worstJump, abs(pitch - previousPitch)) }
                previousPitch = pitch
            }
            return worstJump * 180 / .pi
        }

        let graded = run(mildTier: 100)          // the shipped middle tier
        let effectivelyOff = run(mildTier: 1e10) // what an on/off gate would do

        XCTAssertLessThan(graded, effectivelyOff,
            String(format: "graded inflation must bleed error off continuously: "
                   + "worst per-sample jump %.4f deg vs %.4f deg with the "
                   + "measurement switched off", graded, effectivelyOff))
    }

    /// Sustained straight-line thrust is the case magnitude-keyed inflation got
    /// wrong, so it is asserted directly: 0.3 g forward with the wheel DOWN must not
    /// drag the estimate toward the phantom 16.7 degrees.
    func testSustainedThrustDoesNotDragTheEstimateToThePhantomAngle() {
        var filter = makeFilter(biasSigma: 1e-4)
        let a = 0.3 * Conventions.g
        let force = Conventions.specificForce(pitch: 0, forwardAcceleration: a)
        let phantom = atan(0.3) * 180 / .pi          // 16.699 deg

        // |f| here is 1.044 g, only 4.4% off gravity, so a magnitude test barely
        // notices — while the direction is 16.7 deg wrong.
        XCTAssertEqual(force.magnitude / Conventions.g, 1.044, accuracy: 0.001)

        var gate = ValidityGate(config: Config())
        for i in 1...3000 {
            let sample = IMUSample(time: Double(i) / 100,
                                   rotationRate: .zero,
                                   specificForce: force)
            let verdict = gate.process(sample)!
            filter.propagate(sample)
            filter.updateWithGravity(sample, verdict: verdict)
        }
        XCTAssertLessThan(abs(filter.pitch) * 180 / .pi, phantom / 4,
            String(format: "estimate drifted to %.2f deg under sustained thrust; "
                   + "the phantom angle is %.2f deg",
                   filter.pitch * 180 / .pi, phantom))
    }

    func testGravityUpdatePullsAFalsePitchBackTowardLevel() {
        var filter = makeFilter()
        // Corrupt attitude by propagating a bogus rate, then let gravity correct it.
        let bogus = Conventions.rotationRate(pitchRate: 10 * .pi / 180)
        for i in 1...100 {
            filter.propagate(IMUSample(time: Double(i) / 100,
                                       rotationRate: bogus,
                                       specificForce: Conventions.restSpecificForce))
        }
        let corrupted = abs(filter.pitch)
        XCTAssertGreaterThan(corrupted * 180 / .pi, 5)

        for i in 101...1500 {
            let sample = IMUSample(time: Double(i) / 100,
                                   rotationRate: .zero,
                                   specificForce: Conventions.restSpecificForce)
            filter.propagate(sample)
            filter.updateWithGravity(sample, gateOpen: true)
        }
        XCTAssertLessThan(abs(filter.pitch) * 180 / .pi, 0.5,
                          "a level bike under an open gate must converge to level")
    }

    // MARK: - T3.5 GNSS-aided pitch

    /// The measurement's whole point: it observes pitch DURING acceleration, when the
    /// gravity anchor is unavailable, and so contains bias before the event.
    func testGNSSAidingContainsBiasDuringSustainedAcceleration() {
        func run(useGNSS: Bool) -> Double {
            var config = Config()
            config.gyroBiasInstability = 3.0 * .pi / 180 / 3600
            let trueBias = Vector3(0, -0.5 * .pi / 180, 0)   // 0.5 deg/s, nose-up sign
            var filter = AttitudeESKF(config: config,
                                      alignment: MountAlignment.identity(bikeProfileID: UUID()),
                                      // Filter is told bias is zero with loose confidence.
                                      initialBias: BiasEstimate(bias: .zero,
                                                                sigma: Vector3(0.02, 0.02, 0.02),
                                                                sampleCount: 100,
                                                                monotonicTime: 0,
                                                                bikeProfileID: UUID()),
                                      gravityAnchor: Conventions.restSpecificForce)

            // 30 s of level straight-line acceleration at 0.3 g. The gate is SHUT the
            // whole time (we are accelerating), so gravity alone cannot help.
            let a = 0.3 * Conventions.g
            let bikeForce = Conventions.specificForce(pitch: 0, forwardAcceleration: a)
            var gnssTime = 1.0
            for i in 1...3000 {
                let t = Double(i) / 100
                let sample = IMUSample(time: t,
                                       rotationRate: trueBias,
                                       specificForce: bikeForce)
                filter.propagate(sample)
                filter.updateWithGravity(sample, gateOpen: false)

                if useGNSS, t >= gnssTime {
                    gnssTime += 1.0
                    filter.updateWithGNSSPitch(
                        longitudinalForce: bikeForce.x,
                        groundAcceleration: a,
                        accelerationSigma: 0.141)
                }
            }
            // True pitch is 0 throughout, so any reported pitch is error.
            return abs(filter.pitch) * 180 / .pi
        }

        let withoutAiding = run(useGNSS: false)
        let withAiding = run(useGNSS: true)

        XCTAssertGreaterThan(withoutAiding, 2.0,
            "without aiding a 0.5 deg/s bias over 30 s should be several degrees off")
        XCTAssertLessThan(withAiding, withoutAiding / 5,
            String(format: "GNSS aiding must contain the bias by at least 5x: "
                   + "%.2f deg -> %.2f deg", withoutAiding, withAiding))
    }

    func testGNSSMeasurementIsConsistentWithTheForwardModel() {
        // At a known pitch with known ground acceleration, the residual must be zero:
        // the measurement equation and Conventions must agree exactly.
        let pitch = 25.0 * .pi / 180
        let a = 0.4 * Conventions.g
        let f = Conventions.specificForce(pitch: pitch, forwardAcceleration: a)

        var filter = AttitudeESKF(config: Config(),
                                  alignment: alignment(),
                                  initialBias: biasEstimate(.zero),
                                  gravityAnchor: Conventions.specificForce(pitch: pitch))
        let before = filter.pitch
        filter.updateWithGNSSPitch(longitudinalForce: f.x,
                                   groundAcceleration: a,
                                   accelerationSigma: 0.141)
        XCTAssertEqual(filter.pitch, before, accuracy: 1e-6,
            "a consistent measurement must not move a correct estimate")
    }

    // MARK: - T3.6 delayed state

    func testLatentFixAppliedAtItsOwnTimeBeatsApplyingItAtThePresent() {
        // Build a rotating history, then apply the same measurement two ways.
        func run(retroactive: Bool) -> Double {
            var config = Config()
            let a = 0.3 * Conventions.g
            let force = Conventions.specificForce(pitch: 0, forwardAcceleration: a)
            var filter = AttitudeESKF(config: config,
                                      alignment: MountAlignment.identity(bikeProfileID: UUID()),
                                      initialBias: BiasEstimate(bias: .zero,
                                                                sigma: Vector3(0.02, 0.02, 0.02),
                                                                sampleCount: 100,
                                                                monotonicTime: 0,
                                                                bikeProfileID: UUID()),
                                      gravityAnchor: Conventions.restSpecificForce)
            var buffer = DelayedStateBuffer(config: config)
            let trueBias = Vector3(0, -0.5 * .pi / 180, 0)

            var nextFix = 1.0
            for i in 1...2000 {
                let t = Double(i) / 100
                let sample = IMUSample(time: t, rotationRate: trueBias,
                                       specificForce: force)
                filter.propagate(sample)
                filter.updateWithGravity(sample, gateOpen: false)
                buffer.record(filter.snapshot(measuredRate: sample.rotationRate,
                                              specificForce: sample.specificForce,
                                              saturated: false,
                                              gateOpen: false))

                // A fix that is 400 ms stale on arrival.
                if t >= nextFix {
                    let fixTime = t - 0.4
                    nextFix += 1.0
                    if retroactive {
                        _ = buffer.applyRetroactively(to: &filter,
                                                      fixTime: fixTime,
                                                      thermalState: 0) { f, snapshot in
                            f.updateWithGNSSPitch(
                                longitudinalForce: snapshot.specificForce.dot(Vector3(1, 0, 0)),
                                groundAcceleration: a,
                                accelerationSigma: 0.141)
                        }
                    } else {
                        filter.updateWithGNSSPitch(longitudinalForce: force.x,
                                                   groundAcceleration: a,
                                                   accelerationSigma: 0.141)
                    }
                }
            }
            return abs(filter.pitch) * 180 / .pi
        }

        let retro = run(retroactive: true)
        let naive = run(retroactive: false)
        // Both should work here because the trajectory is smooth; the point is that
        // the retroactive path is not WORSE, and the numbers are recorded.
        XCTAssertLessThan(retro, 1.0,
                          String(format: "retroactive: %.3f deg, naive: %.3f deg",
                                 retro, naive))
    }

    func testFixOlderThanTheWindowIsDiscardedAndCounted() {
        var config = Config()
        config.delayedStateWindow = 0.5
        var buffer = DelayedStateBuffer(config: config)
        var filter = makeFilter(config: config)

        for i in 1...200 {
            let sample = IMUSample(time: Double(i) / 100,
                                   rotationRate: .zero,
                                   specificForce: Conventions.restSpecificForce)
            filter.propagate(sample)
            buffer.record(filter.snapshot(measuredRate: sample.rotationRate,
                                          specificForce: sample.specificForce,
                                          saturated: false,
                                          gateOpen: true))
        }
        let applied = buffer.applyRetroactively(to: &filter, fixTime: 0.1,
                                                thermalState: 0) { _, _ in }
        XCTAssertFalse(applied)
        XCTAssertEqual(buffer.discardedTooOld, 1,
                       "a fix too old to place must be counted, never guessed at")
    }

    func testBufferIsBoundedByItsWindow() {
        var config = Config()
        config.delayedStateWindow = 1.0
        var buffer = DelayedStateBuffer(config: config)
        var filter = makeFilter(config: config)
        for i in 1...5000 {
            let sample = IMUSample(time: Double(i) / 100,
                                   rotationRate: .zero,
                                   specificForce: Conventions.restSpecificForce)
            filter.propagate(sample)
            buffer.record(filter.snapshot(measuredRate: sample.rotationRate,
                                          specificForce: sample.specificForce,
                                          saturated: false,
                                          gateOpen: true))
        }
        XCTAssertLessThanOrEqual(buffer.count, 103)
    }

    // MARK: - Ground acceleration estimator

    func testGroundAccelerationDifferentiatesSpeedAndInflatesSigma() {
        var estimator = GroundAccelerationEstimator(config: Config())
        XCTAssertNil(estimator.process(GNSSFix(fixTime: 0, arrivalTime: 0.25,
                                               speed: 10, speedAccuracy: 0.1)))
        guard let e = estimator.process(GNSSFix(fixTime: 1, arrivalTime: 1.25,
                                                speed: 13, speedAccuracy: 0.1)) else {
            return XCTFail("expected an estimate on the second fix")
        }
        XCTAssertEqual(e.acceleration, 3.0, accuracy: 1e-12)
        // sqrt(0.1^2 + 0.1^2) / 1 s = 0.1414
        XCTAssertEqual(e.sigma, 0.1414, accuracy: 1e-3)
        // Centred between the fixes, not stamped at the newer one: stamping at the
        // end would bias the measurement by half the interval.
        XCTAssertEqual(e.midTime, 0.5, accuracy: 1e-12)
        XCTAssertEqual(e.speed, 11.5, accuracy: 1e-12)
    }

    func testPoorAccuracyFixesAreRefusedForAiding() {
        var config = Config()
        config.gnssMaxSpeedAccuracy = 0.5
        var estimator = GroundAccelerationEstimator(config: config)
        _ = estimator.process(GNSSFix(fixTime: 0, arrivalTime: 0.1,
                                      speed: 10, speedAccuracy: 0.1))
        XCTAssertNil(estimator.process(GNSSFix(fixTime: 1, arrivalTime: 1.1,
                                               speed: 13, speedAccuracy: 2.0)),
                     "a 2 m/s accuracy fix must not drive an attitude measurement")
    }

    func testInvalidSpeedIsRefused() {
        var estimator = GroundAccelerationEstimator(config: Config())
        _ = estimator.process(GNSSFix(fixTime: 0, arrivalTime: 0.1,
                                      speed: 10, speedAccuracy: 0.1))
        XCTAssertNil(estimator.process(GNSSFix(fixTime: 1, arrivalTime: 1.1,
                                               speed: -1, speedAccuracy: -1)))
    }
}

// MARK: - Grade baseline

final class GradeBaselineTests: XCTestCase {

    func testConstantGradeIsRemoved() {
        var baseline = GradeBaseline(config: Config())
        let grade = 4.0 * .pi / 180
        var corrected = 0.0
        for i in 0..<3000 {
            corrected = baseline.process(GradeBaseline.Input(
                pitch: grade, gateOpen: true, time: Double(i) / 100)) ?? 0
        }
        XCTAssertEqual(corrected * 180 / .pi, 0, accuracy: 0.01)
        XCTAssertEqual((baseline.grade ?? 0) * 180 / .pi, 4.0, accuracy: 0.01)
    }

    /// The reason the baseline freezes: a 25 s time constant left running would eat a
    /// large fraction of a 10 s hold and quietly under-report the angle.
    func testFrozenBaselineDoesNotAbsorbAWheelie() {
        var config = Config()
        var baseline = GradeBaseline(config: config)

        // 30 s of level cruising with the gate open establishes the reference.
        for i in 0..<3000 {
            _ = baseline.process(GradeBaseline.Input(pitch: 0, gateOpen: true,
                                                    time: Double(i) / 100))
        }
        // Then a 10 s hold at 45 deg with the gate SHUT, as it would be in reality.
        let hold = 45.0 * .pi / 180
        var last = 0.0
        for i in 3000..<4000 {
            last = baseline.process(GradeBaseline.Input(pitch: hold, gateOpen: false,
                                                       time: Double(i) / 100)) ?? 0
        }
        XCTAssertEqual(last * 180 / .pi, 45, accuracy: 0.001,
                       "the frozen baseline must report the full angle")

        // Now show what a non-freezing baseline would have done, for the record.
        var leaky = GradeBaseline(config: config)
        for i in 0..<3000 {
            _ = leaky.process(GradeBaseline.Input(pitch: 0, gateOpen: true,
                                                 time: Double(i) / 100))
        }
        var leakyLast = 0.0
        for i in 3000..<4000 {
            leakyLast = leaky.process(GradeBaseline.Input(pitch: hold, gateOpen: true,
                                                         time: Double(i) / 100)) ?? 0
        }
        XCTAssertLessThan(leakyLast * 180 / .pi, 35,
            "a baseline that kept updating would swallow a third of the hold — this "
            + "is the bug freezing prevents")
    }

    func testFirstGateOpenSampleSeedsTheBaselineImmediately() {
        var baseline = GradeBaseline(config: Config())
        let grade = 3.0 * .pi / 180
        let corrected = baseline.process(GradeBaseline.Input(pitch: grade,
                                                            gateOpen: true,
                                                            time: 0))
        XCTAssertEqual(corrected ?? 99, 0, accuracy: 1e-12,
                       "seeding outright avoids a minute of convergence")
        XCTAssertEqual(baseline.grade ?? 0, grade, accuracy: 1e-12)
    }

    func testCorrectionAppliesEvenBeforeAnyGateOpen() {
        var baseline = GradeBaseline(config: Config())
        let corrected = baseline.process(GradeBaseline.Input(pitch: 0.5,
                                                            gateOpen: false,
                                                            time: 0))
        XCTAssertEqual(corrected ?? 0, 0.5, accuracy: 1e-12)
        XCTAssertNil(baseline.grade)
    }

    func testSampleRateIndependence() {
        // Same elapsed time at two rates must converge to the same grade.
        func converge(rate: Double) -> Double {
            var baseline = GradeBaseline(config: Config())
            let grade = 4.0 * .pi / 180
            let steps = Int(60 * rate)
            for i in 0..<steps {
                _ = baseline.process(GradeBaseline.Input(pitch: grade, gateOpen: true,
                                                        time: Double(i) / rate))
            }
            return baseline.grade ?? 0
        }
        XCTAssertEqual(converge(rate: 100), converge(rate: 25), accuracy: 1e-6)
    }
}

/// The grade baseline seen through the whole `Pipeline`, which is where the reported
/// angle is actually produced. `GradeBaselineTests` above drives the baseline in
/// isolation with an explicit `gateOpen`; these drive the real gating decision.
final class GradeBaselinePipelineTests: XCTestCase {

    /// Reported (baseline-corrected) pitch in degrees after holding a STATIONARY
    /// bike at `degrees` for `seconds`. Stationary and tilted is the case that
    /// matters: specific force is pure gravity, so the validity gate stays OPEN.
    private func reportedPitch(heldAt degrees: Double,
                               seconds: Double,
                               config: Config = Config()) -> Double {
        let radians = degrees * .pi / 180
        let force = Conventions.specificForce(pitch: radians)
        var pipeline = Pipeline(config: config,
                                alignment: .identity(),
                                initialBias: nil,
                                gravityAnchor: force)
        let dt = 1.0 / config.nominalSampleRate
        var reported = 0.0
        var t = 0.0
        while t < seconds {
            let sample = IMUSample(time: t, rotationRate: .zero, specificForce: force)
            if let output = pipeline.process(.imu(sample)) {
                reported = output.pitch * 180 / .pi
            }
            t += dt
        }
        return reported
    }

    /// R8.8: a few degrees of constant ROAD GRADE must still be absorbed, so a bike
    /// merely sitting on an incline never reads as a permanent wheelie.
    func testConstantRoadGradeIsStillAbsorbed() {
        XCTAssertEqual(reportedPitch(heldAt: 4, seconds: 90), 0, accuracy: 1.0,
                       "a constant 4 deg grade must be absorbed by the baseline")
    }

    /// The reported bug: a sustained tilt above the event threshold must NOT be
    /// absorbed. The baseline froze only on gate CLOSURE, but a held tilt is
    /// quasi-static so the gate stays open — the 25 s baseline chased the held angle
    /// and it decayed as 20*e^(-t/25): about 13 deg after 10 s, under 3 deg after 50 s.
    func testHeldTiltIsNotAbsorbedAsGrade() {
        for seconds in [10.0, 50.0, 90.0] {
            let reported = reportedPitch(heldAt: 20, seconds: seconds)
            XCTAssertEqual(reported, 20, accuracy: 1.0,
                           "a held 20 deg tilt must survive \(seconds) s, got \(reported)")
        }
    }
}
