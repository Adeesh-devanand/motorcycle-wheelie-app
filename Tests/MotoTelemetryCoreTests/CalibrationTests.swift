import XCTest
@testable import MotoTelemetryCore

final class CalibrationTests: XCTestCase {

    private let bike = UUID()

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
        XCTAssertGreaterThan(estimate.sampleCount, 700)
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

    func testVibrationFailsCalibrationRatherThanPoisoningIt() {
        // 3 m/s^2 of 83 Hz excitation, i.e. a twin around 5000 rpm on a rigid
        // mount. Note what the gate does here: its band is +/-0.03 g = 0.294 m/s^2
        // and it is INSTANTANEOUS, so it rejects this immediately rather than
        // averaging it to 1 g. The gate is therefore the detector; the
        // high-frequency indicator's job is to turn that rejection into an
        // actionable reason instead of "bike is not level and still".
        let result = run(stationarySamples(duration: 12, vibrationAmplitude: 3.0))

        guard case .failed(let failure)? = result else {
            return XCTFail("a shaking bike must not produce a silent estimate, got "
                           + "\(String(describing: result))")
        }
        guard case .vibrationTooHigh(let rms, let limit) = failure else {
            return XCTFail("expected vibrationTooHigh, got \(failure)")
        }
        XCTAssertGreaterThan(rms, limit)
        XCTAssertTrue(failure.message.contains("mount"),
                      "the message must point at the mechanical fix")
    }

    func testMildVibrationInsideTheGateBandStillFailsCalibration() {
        // 0.2 m/s^2 stays inside the gate's window, so the gate never objects.
        // This is the dangerous case: without the RMS check the bias would be
        // averaged over the oscillation and come out quietly wrong.
        let result = run(stationarySamples(duration: 12, vibrationAmplitude: 0.2))
        guard case .failed(let failure)? = result,
              case .vibrationTooHigh = failure else {
            return XCTFail("mild in-band vibration must still fail, got "
                           + "\(String(describing: result))")
        }
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

    func testInterruptionResetsProgressSoAPartialZeroingIsNeverAccepted() {
        var config = Config()
        config.biasCalibrationDuration = 4.0
        var estimator = BiasEstimator(config: config, bikeProfileID: bike)

        // 3 s of quiet, then a bump, then 3 s of quiet: neither stretch is long
        // enough, so nothing may complete.
        var samples = stationarySamples(duration: 3, rate: 100)
        samples.append(IMUSample(time: 3.0,
                                 rotationRate: Vector3(0, 0, 20 * .pi / 180),
                                 specificForce: Conventions.restSpecificForce))
        samples += stationarySamples(duration: 3, rate: 100).map {
            IMUSample(time: $0.time + 3.01,
                      rotationRate: $0.rotationRate,
                      specificForce: $0.specificForce)
        }

        var completed = false
        for sample in samples {
            if let p = estimator.process(sample), case .done = p { completed = true }
        }
        XCTAssertFalse(completed,
                       "two sub-duration stretches must not add up to a zeroing")
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

    func testTrackerGoesStaleAfterTheConfiguredAge() {
        let config = Config()
        var tracker = CalibrationTracker(config: config)
        let estimate = BiasEstimate(bias: .zero, sigma: Vector3(1e-5, 1e-5, 1e-5),
                                    sampleCount: 800, monotonicTime: 100,
                                    bikeProfileID: bike)
        tracker.adopt(estimate)

        if case .calibrated = tracker.update(now: 200) {} else {
            XCTFail("100 s old must still be calibrated")
        }
        guard case .stale(_, let reason) = tracker.update(now: 100 + config.biasStaleAfter + 1)
        else { return XCTFail("expected stale") }
        XCTAssertEqual(reason, .aged)
    }

    func testStaleBiasIsStillUsable() {
        // A stale estimate beats no estimate; it is used with worse confidence,
        // not thrown away.
        var tracker = CalibrationTracker(config: Config())
        tracker.adopt(BiasEstimate(bias: Vector3(0.01, 0, 0),
                                   sigma: Vector3(1e-5, 1e-5, 1e-5),
                                   sampleCount: 800, monotonicTime: 0,
                                   bikeProfileID: bike))
        tracker.invalidate(.aged)
        XCTAssertNotNil(tracker.status.usableBias)
        XCTAssertEqual(tracker.status.usableBias?.x, 0.01)
    }

    func testBikeChangeInvalidatesCalibration() {
        var tracker = CalibrationTracker(config: Config())
        tracker.adopt(BiasEstimate(bias: .zero, sigma: Vector3(1e-5, 1e-5, 1e-5),
                                   sampleCount: 800, monotonicTime: 0,
                                   bikeProfileID: bike))
        tracker.invalidate(.bikeProfileChanged)
        guard case .stale(_, let reason) = tracker.status else {
            return XCTFail("expected stale")
        }
        XCTAssertEqual(reason, .bikeProfileChanged)
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
        XCTAssertEqual(estimate, decoded)
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
