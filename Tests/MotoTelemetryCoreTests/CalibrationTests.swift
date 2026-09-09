import XCTest
@testable import MotoTelemetryCore

final class CalibrationTests: XCTestCase {

    private let bike = UUID()

    /// The count `BiasEstimator` itself requires, derived rather than hardcoded.
    ///
    /// It was `> 700`, which silently encoded an 8 s `biasCalibrationDuration`; when
    /// the beta shortened that to 2 s the assertion failed while the code was
    /// behaving exactly as configured. A test that pins a product decision it does
    /// not name is a test that fails for the wrong reason.
    private static var requiredSampleCount: Int {
        let c = Config()
        return Int(c.biasCalibrationDuration * c.nominalSampleRate * 0.5)
    }

    /// Stationary, level, with white gyro noise of a given sigma (rad/s).
    private func stationarySamples(duration: TimeInterval,
                                   rate: Double = 100,
                                   trueBias: Vector3 = Vector3(0.003, -0.002, 0.001),
                                   noiseSigma: Double = 0.0006,
                                   vibrationAmplitude: Double = 0,
                                   seed: UInt64 = 42) -> [IMUSample] {
        var rng = SplitMix64(seed: seed)
        let n = Int(duration * rate)
        return (0..<n).map { i in
            let t = Double(i) / rate
            let noise = Vector3(rng.nextGaussian() * noiseSigma,
                                rng.nextGaussian() * noiseSigma,
                                rng.nextGaussian() * noiseSigma)
            var f = Conventions.restSpecificForce
            if vibrationAmplitude > 0 {
                // 83 Hz excitation, i.e. a twin around 5000 rpm.
                let phase = 2 * .pi * 83.0 * t
                f = Vector3(f.x + vibrationAmplitude * sin(phase),
                            f.y,
                            f.z + vibrationAmplitude * sin(phase + 1.1))
            }
            return IMUSample(time: t,
                             rotationRate: trueBias + noise,
                             specificForce: f)
        }
    }

    private func run(_ samples: [IMUSample],
                     config: Config = Config(),
                     thermalState: Int = 0) -> BiasEstimator.Progress? {
        var estimator = BiasEstimator(config: config,
                                      bikeProfileID: bike,
                                      thermalState: thermalState)
        var last: BiasEstimator.Progress?
        for sample in samples {
            guard let progress = estimator.process(sample) else { continue }
            last = progress
            if case .done = progress { return progress }
            if case .failed = progress { return progress }
        }
        return last
    }

    // MARK: - The happy path

    /// A STARVED stream fails on sigma while the identical noise at full rate passes,
    /// and the failure looks exactly like "the bike was moving too much".
    ///
    /// This is the 2026-09-08 device log, encoded. Completion needs `elapsed >= 2 s`
    /// AND `n >= requiredSampleCount` (duration x rate x 0.5 = 100). At full rate the
    /// 2 s bound binds and n lands near 200; at a fifth of the rate the sample floor
    /// binds and n stops at exactly 100 — which is what all three `bias finish` lines
    /// on the device reported. Since the SEM is `std/sqrt(n)`, sqrt(100) rather than
    /// sqrt(200) inflates the reported sigma by 1.41x against a limit chosen for the
    /// 200-sample case.
    ///
    /// The cause there was `MotionService` pairing (986 emitted against 7,907
    /// unpaired). The point of this test is that no threshold is at fault: the same
    /// gyro noise passes or fails purely on how many samples arrived, so a future
    /// reader must not "fix" it by loosening `biasSigmaLimit`.
    func testAStarvedStreamFailsSigmaOnSampleCountAloneNotNoise() throws {
        // Noise chosen to sit between the two sqrt(n) cases: it passes at n ~ 200 and
        // fails at n = 100. Deterministic, alternating so the mean stays put and only
        // the spread carries.
        let noise = 0.55 * .pi / 180          // deg/s of raw per-sample spread
        func samples(rate: Double, seconds: Double) -> [IMUSample] {
            let count = Int(rate * seconds)
            return (0..<count).map { i in
                let sign: Double = i % 2 == 0 ? 1 : -1
                return IMUSample(time: Double(i) / rate,
                                 rotationRate: Vector3(sign * noise, 0, 0),
                                 specificForce: Conventions.restSpecificForce)
            }
        }

        // Full rate: the elapsed bound binds, n is ~200, sigma passes.
        guard case .done(let estimate)? = run(samples(rate: 100, seconds: 4)) else {
            return XCTFail("full-rate stream should complete")
        }
        XCTAssertGreaterThan(estimate.sampleCount, 150,
                            "at 100 Hz the 2 s elapsed bound should bind, not the floor")

        // Same noise, a fifth of the rate. `discontinuityGap` is 30 nominal intervals
        // (300 ms), and 20 Hz gives 50 ms spacing, so this is a slow stream and NOT a
        // discontinuous one — exactly the device's case.
        let starved = run(samples(rate: 20, seconds: 20))
        guard case .failed(let failure)? = starved else {
            return XCTFail("starved stream should fail, got \(String(describing: starved))")
        }
        guard case .sigmaTooHigh = failure else {
            return XCTFail("expected sigmaTooHigh, got \(failure)")
        }
    }

    func testTenSecondZeroingRecoversBiasWithSmallSigma() throws {
        let trueBias = Vector3(0.004, -0.0025, 0.0011)
        let result = run(stationarySamples(duration: 12, trueBias: trueBias))

        guard case .done(let estimate)? = result else {
            return XCTFail("expected a completed estimate, got \(String(describing: result))")
        }

        // Recovers the bias.
        XCTAssertEqual(estimate.bias.x, trueBias.x, accuracy: 1e-4)
        XCTAssertEqual(estimate.bias.y, trueBias.y, accuracy: 1e-4)
        XCTAssertEqual(estimate.bias.z, trueBias.z, accuracy: 1e-4)

        // R6.4: per-axis sigma under 0.01 deg/s. With 0.0006 rad/s of noise over
        // ~800 samples the standard error is ~2e-5 rad/s, so this has margin —
        // a failure here means something is genuinely wrong, not a tight bound.
        let limitDegPerSec = 0.01
        XCTAssertLessThan(estimate.sigma.x * 180 / .pi, limitDegPerSec)
        XCTAssertLessThan(estimate.sigma.y * 180 / .pi, limitDegPerSec)
        XCTAssertLessThan(estimate.sigma.z * 180 / .pi, limitDegPerSec)
        XCTAssertGreaterThanOrEqual(estimate.sampleCount, Self.requiredSampleCount)
    }

    func testProgressReportsFractionWhileCollecting() {
        var estimator = BiasEstimator(config: Config(), bikeProfileID: bike)
        var fractions: [Double] = []
        for sample in stationarySamples(duration: 6) {
            if let p = estimator.process(sample), case .collecting = p {
                fractions.append(p.fraction)
            }
        }
        XCTAssertFalse(fractions.isEmpty)
        XCTAssertEqual(fractions, fractions.sorted(), "progress must be monotonic")
        XCTAssertLessThan(fractions.last!, 1.0, "6 s cannot complete an 8 s zeroing")
    }

    // MARK: - The failure paths, which are the point of the class

    func testViolentShakeNeverCompletesAZeroing() {
        // 3 m/s^2 of 83 Hz excitation, i.e. a twin around 5000 rpm on a rigid mount.
        // This must not silently produce an estimate — but note HOW it is refused.
        // The gate's band is breached for a large fraction of every cycle, longer
        // than `gateCloseConfirm`, so the gate keeps closing and the dwell never
        // completes. The refusal comes from the gate reporting its own condition, not
        // from a vibration RMS threshold, and it is honest: with the attempt window
        // (30 s) longer than this fixture (12 s) the estimator is still trying.
        let result = run(stationarySamples(duration: 12, vibrationAmplitude: 3.0))

        switch result {
        case .done:
            XCTFail("a violently shaking mount must not produce an estimate")
        case .failed(let failure):
            // Acceptable: the attempt window elapsed and it explained why.
            guard case .gateNeverOpened = failure else {
                return XCTFail("expected gateNeverOpened, got \(failure)")
            }
        case .rejected, .collecting, .none:
            break  // still trying, which is correct inside the attempt window
        }
    }

    func testMildInBandVibrationCalibratesAndTheBiasIsStillAccurate() {
        // THIS TEST INVERTED IN v3, deliberately. It used to assert that 0.2 m/s^2
        // of vibration FAILED calibration, on the stated grounds that "without the
        // RMS check the bias would be averaged over the oscillation and come out
        // quietly wrong."
        //
        // That premise is false, and this fixture is why: `vibrationAmplitude`
        // perturbs `specificForce` ONLY — the gyro is untouched — and the bias
        // estimate is the MEAN OF THE GYRO. More generally, even real gyro vibration
        // is zero-mean, and averaging is precisely the operation that removes it;
        // what survives is the standard error, which `biasSigmaLimit` bounds. So the
        // check rejected a perfectly good zeroing and left the filter with no bias at
        // all, which is the far larger error. It also made calibrating on a running
        // bike impossible, and mid-ride recalibration impossible outright.
        //
        // The assertion is therefore the one that actually matters: it completes, AND
        // the number it produces is right.
        let trueBias = Vector3(0.003, -0.002, 0.001)
        let result = run(stationarySamples(duration: 12,
                                           trueBias: trueBias,
                                           vibrationAmplitude: 0.2))

        guard case .done(let estimate)? = result else {
            return XCTFail("mild in-band vibration must still calibrate, got "
                           + "\(String(describing: result))")
        }
        // Accurate to well inside the 0.05 deg/s (8.7e-4 rad/s) error budget.
        XCTAssertEqual(estimate.bias.x, trueBias.x, accuracy: 1e-4)
        XCTAssertEqual(estimate.bias.y, trueBias.y, accuracy: 1e-4)
        XCTAssertEqual(estimate.bias.z, trueBias.z, accuracy: 1e-4)
        XCTAssertLessThan(estimate.worstSigma, Config().biasSigmaLimit,
                          "vibration must not inflate the reported uncertainty past the limit")
        XCTAssertGreaterThanOrEqual(estimate.sampleCount, Self.requiredSampleCount)
    }

    func testQuietMountCalibratesDespiteTheVibrationCheck() {
        // Guard against the threshold being so strict that nothing ever passes.
        let result = run(stationarySamples(duration: 12, vibrationAmplitude: 0.01))
        guard case .done? = result else {
            return XCTFail("a quiet mount must calibrate, got "
                           + "\(String(describing: result))")
        }
    }

    func testNoisyGyroFailsOnSigmaAndNamesTheAxis() {
        // Noise must stay inside the gate's per-axis 3 deg/s (0.0524 rad/s) limit
        // or the gate resets progress and nothing ever completes — which is what
        // an earlier version of this test accidentally measured. 0.01 rad/s is
        // 0.57 deg/s, so a breach needs 5.2 sigma and is rare.
        var config = Config()
        config.biasSigmaLimit = 1e-4      // rad/s; expected SEM here is ~3.5e-4
        let result = run(stationarySamples(duration: 12, noiseSigma: 0.01),
                         config: config)

        guard case .failed(let failure)? = result,
              case .sigmaTooHigh(let axis, let sigma, let limit) = failure else {
            return XCTFail("expected sigmaTooHigh, got \(String(describing: result))")
        }
        XCTAssertGreaterThan(sigma, limit)
        XCTAssertTrue(Axis.allCases.contains(axis))
        XCTAssertTrue(failure.message.contains(axis.rawValue.uppercased()),
                      "the failing axis must be named for the rider")
    }

    func testSaturatedSamplesNeverEnterTheEstimate() {
        var samples = stationarySamples(duration: 12)
        // Poison a stretch with a huge rate, but flagged saturated.
        for i in 200..<260 {
            samples[i] = IMUSample(time: samples[i].time,
                                   rotationRate: Vector3(5, 5, 5),
                                   specificForce: Conventions.restSpecificForce,
                                   saturated: true)
        }
        let result = run(samples)
        guard case .done(let estimate)? = result else {
            return XCTFail("expected completion, got \(String(describing: result))")
        }
        // If a 5 rad/s sample had entered, the mean would be wildly off.
        XCTAssertLessThan(estimate.bias.magnitude, 0.01,
                          "a saturated sample leaked into the mean")
    }

    func testMovingBikeIsRejectedWithTheGatesReason() {
        // Rotating faster than the gate's 3 deg/s limit throughout.
        let rate = 10.0 * .pi / 180
        let samples = (0..<400).map { i in
            IMUSample(time: Double(i) / 100,
                      rotationRate: Vector3(0, 0, rate),
                      specificForce: Conventions.restSpecificForce)
        }
        let result = run(samples)
        guard case .rejected(let reason)? = result else {
            return XCTFail("expected rejection, got \(String(describing: result))")
        }
        XCTAssertEqual(reason, .rotating)
    }

    func testAttemptWindowGivesUpAndExplainsWhy() {
        var config = Config()
        config.biasAttemptWindow = 2.0
        let rate = 10.0 * .pi / 180
        let samples = (0..<400).map { i in
            IMUSample(time: Double(i) / 100,
                      rotationRate: Vector3(0, 0, rate),
                      specificForce: Conventions.restSpecificForce)
        }
        let result = run(samples, config: config)
        guard case .failed(let failure)? = result,
              case .gateNeverOpened(let reason) = failure else {
            return XCTFail("expected gateNeverOpened, got \(String(describing: result))")
        }
        XCTAssertEqual(reason, .rotating)
        XCTAssertTrue(failure.message.contains("moving"))
    }

    func testATransientBlipPausesProgressRatherThanDiscardingIt() {
        // REPLACES a v2 test that asserted the opposite ("two sub-duration stretches
        // must not add up"). Discarding on ANY single closed sample is what produced
        // the reported "stuck at 0%": on a running bike a blip fires constantly, and
        // 8 s of unbroken quiet never assembles. A 10 ms blip is 0.2 deg of rotation
        // — the bike has not moved, and throwing away 3 s of good samples over it is
        // the bug, not the safeguard.
        var config = Config()
        config.biasCalibrationDuration = 4.0
        var estimator = BiasEstimator(config: config, bikeProfileID: bike)

        let trueBias = Vector3(0.003, -0.002, 0.001)
        var samples = stationarySamples(duration: 3, rate: 100, trueBias: trueBias)
        samples.append(IMUSample(time: 3.0,
                                 rotationRate: Vector3(0, 0, 20 * .pi / 180),
                                 specificForce: Conventions.restSpecificForce))
        samples += stationarySamples(duration: 3, rate: 100, trueBias: trueBias).map {
            IMUSample(time: $0.time + 3.01,
                      rotationRate: $0.rotationRate,
                      specificForce: $0.specificForce)
        }

        var estimate: BiasEstimate?
        for sample in samples {
            if let p = estimator.process(sample), case .done(let e) = p { estimate = e }
        }

        guard let estimate else {
            return XCTFail("a 10 ms blip must not prevent a 6 s zeroing from completing")
        }
        // And the blip must not have leaked into the mean: the gate stays open across
        // it, so exclusion is `sampleWithinBand`'s job, not the gate's.
        XCTAssertEqual(estimate.bias.z, trueBias.z, accuracy: 1e-4,
                       "the 20 deg/s spike leaked into the bias mean")
        XCTAssertEqual(estimate.bias.x, trueBias.x, accuracy: 1e-4)
    }

    func testASustainedInterruptionDiscardsProgress() {
        // The other side of the grace period: an interruption long enough that the
        // bike may genuinely have moved or been re-oriented DOES discard, so two
        // sub-duration stretches still cannot add up to a zeroing.
        var config = Config()
        config.biasCalibrationDuration = 4.0
        var estimator = BiasEstimator(config: config, bikeProfileID: bike)

        // 3 s quiet, 1 s of real rotation (well past both gateCloseConfirm and
        // biasGateGracePeriod), then 3 s quiet. Neither stretch reaches 4 s alone.
        var samples = stationarySamples(duration: 3, rate: 100)
        samples += (0..<100).map { i in
            IMUSample(time: 3.0 + Double(i) / 100,
                      rotationRate: Vector3(0, 0, 20 * .pi / 180),
                      specificForce: Conventions.restSpecificForce)
        }
        samples += stationarySamples(duration: 3, rate: 100).map {
            IMUSample(time: $0.time + 4.01,
                      rotationRate: $0.rotationRate,
                      specificForce: $0.specificForce)
        }

        var completed = false
        for sample in samples {
            if let p = estimator.process(sample), case .done = p { completed = true }
        }
        XCTAssertFalse(completed,
                       "a sustained interruption must still discard accumulated progress")
    }

    // MARK: - Age and confidence

    func testProjectedSigmaGrowsWithAgeAndHoldLength() {
        let config = Config()
        let estimate = BiasEstimate(bias: .zero,
                                    sigma: Vector3(1e-5, 1e-5, 1e-5),
                                    sampleCount: 800,
                                    monotonicTime: 0,
                                    bikeProfileID: bike)

        let fresh = estimate.projectedPitchSigma(age: 0, holdDuration: 10, config: config)
        let stale = estimate.projectedPitchSigma(age: 1800, holdDuration: 10, config: config)
        XCTAssertGreaterThan(stale, fresh, "confidence must decay with bias age")

        let short = estimate.projectedPitchSigma(age: 300, holdDuration: 2, config: config)
        let long = estimate.projectedPitchSigma(age: 300, holdDuration: 10, config: config)
        XCTAssertGreaterThan(long, short,
                             "bias error integrates into angle, so a long hold "
                             + "costs more than a short one")
        XCTAssertEqual(long / short, 5.0, accuracy: 1e-9, "and it is linear in time")
    }

    func testHotterPhoneProjectsWorseConfidence() {
        let config = Config()
        let cool = BiasEstimate(bias: .zero, sigma: Vector3(1e-5, 1e-5, 1e-5),
                                sampleCount: 800, monotonicTime: 0,
                                bikeProfileID: bike, thermalStateAtCapture: 0)
        let hot = BiasEstimate(bias: .zero, sigma: Vector3(1e-5, 1e-5, 1e-5),
                               sampleCount: 800, monotonicTime: 0,
                               bikeProfileID: bike, thermalStateAtCapture: 3)
        XCTAssertGreaterThan(hot.projectedSigma(age: 1800, config: config),
                             cool.projectedSigma(age: 1800, config: config))
    }
    func testEstimateRoundTripsThroughCoding() throws {
        let estimate = BiasEstimate(bias: Vector3(1e-3, -2e-3, 3e-4),
                                    sigma: Vector3(1e-5, 2e-5, 3e-5),
                                    sampleCount: 812,
                                    monotonicTime: 1234.5,
                                    bikeProfileID: bike,
                                    thermalStateAtCapture: 1)
        let data = try JSONEncoder().encode(estimate)
        let decoded = try JSONDecoder().decode(BiasEstimate.self, from: data)

        // Exact equality for non-floating-point fields
        XCTAssertEqual(estimate.id, decoded.id)
        XCTAssertEqual(estimate.sampleCount, decoded.sampleCount)
        XCTAssertEqual(estimate.bikeProfileID, decoded.bikeProfileID)
        XCTAssertEqual(estimate.thermalStateAtCapture, decoded.thermalStateAtCapture)
        XCTAssertEqual(estimate.wallClock, decoded.wallClock)

        // Tolerance-based comparison for Double fields that lose precision in JSON round-trip
        let accuracy = 1e-15
        XCTAssertEqual(estimate.monotonicTime, decoded.monotonicTime, accuracy: accuracy)

        XCTAssertEqual(estimate.bias.x, decoded.bias.x, accuracy: accuracy)
        XCTAssertEqual(estimate.bias.y, decoded.bias.y, accuracy: accuracy)
        XCTAssertEqual(estimate.bias.z, decoded.bias.z, accuracy: accuracy)

        XCTAssertEqual(estimate.sigma.x, decoded.sigma.x, accuracy: accuracy)
        XCTAssertEqual(estimate.sigma.y, decoded.sigma.y, accuracy: accuracy)
        XCTAssertEqual(estimate.sigma.z, decoded.sigma.z, accuracy: accuracy)
    }
}

/// Deterministic RNG so noise-driven tests are reproducible. A flaky accuracy
/// test is worse than no accuracy test.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func nextUniform() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)
    }

    /// Box-Muller.
    mutating func nextGaussian() -> Double {
        let u1 = max(nextUniform(), 1e-12)
        let u2 = nextUniform()
        return (-2 * Foundation.log(u1)).squareRoot() * Foundation.cos(2 * .pi * u2)
    }
}
