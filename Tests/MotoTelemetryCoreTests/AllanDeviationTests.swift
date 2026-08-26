import XCTest
@testable import MotoTelemetryCore

final class AllanDeviationTests: XCTestCase {

    // MARK: - Deterministic RNG (copied from CalibrationTests per instructions)

    private struct SplitMix64 {
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

        mutating func nextGaussian() -> Double {
            let u1 = max(nextUniform(), 1e-12)
            let u2 = nextUniform()
            return (-2 * Foundation.log(u1)).squareRoot() * Foundation.cos(2 * .pi * u2)
        }
    }

    // MARK: - Test: White noise ARW recovery

    /// Synthesise a rate series with pure white noise of known sigma.
    /// The ADEV at tau=1 for white noise is sigma/sqrt(sampleRate) * sqrt(tau0/tau).
    /// At tau=1: ADEV(1) = sigma * sqrt(tau0) = sigma / sqrt(fs).
    /// This IS the angle random walk (noise density) in rad/s/sqrt(Hz).
    ///
    /// With sigma = 0.01 rad/s at 100 Hz, the expected ARW = 0.01 / sqrt(100) = 0.001 rad/s/sqrt(Hz).
    func testWhiteNoiseARWRecovery() {
        let sigma = 0.01      // rad/s
        let fs = 100.0        // Hz
        let duration = 600.0  // 10 minutes — enough for a stable estimate at tau=1
        let n = Int(duration * fs)
        let expectedARW = sigma / fs.squareRoot()  // 0.001 rad/s/sqrt(Hz)

        var rng = SplitMix64(seed: 12345)
        let rates = (0..<n).map { _ in rng.nextGaussian() * sigma }

        let result = AllanDeviation.analyseGyro(rates: rates, sampleRate: fs)

        // Tolerance: 10% of expected value. With 60k samples at tau=1 (which uses
        // 100 rate points per cluster), the estimator variance is low.
        let tolerance = expectedARW * 0.10
        XCTAssertEqual(result.gyroNoiseDensity, expectedARW, accuracy: tolerance,
                       "ARW recovery: expected \(expectedARW), got \(result.gyroNoiseDensity)")
    }

    // MARK: - Test: White noise + random walk (bias instability) recovery

    /// Synthesise white noise PLUS a random walk to verify the algorithm finds the
    /// ADEV minimum and divides by 0.664 to extract bias instability.
    ///
    /// The random walk in rate produces an ADEV contribution that rises as
    /// tau^{+1/2}. Where it crosses the white-noise tau^{-1/2}, the curve has its
    /// minimum. ADEV_min / 0.664 = BI (IEEE 1139 definition).
    ///
    /// With finite data and octave-spaced tau, the minimum is only approximately
    /// located. We verify: (a) the curve HAS a minimum below its first point, and
    /// (b) the recovered BI is within a factor of 2 of the injected value. Tighter
    /// bounds require multi-hour sessions and decade-spaced tau — that's the real
    /// bench session's job, not a unit test's.
    func testBiasInstabilityRecovery() {
        let sigma = 0.0005    // white noise sigma (rad/s) — kept low to expose the floor
        let biasInstability = 1e-4  // rad/s — target BI
        let fs = 100.0
        let duration = 3600.0  // 1 hour
        let n = Int(duration * fs)
        let tau0 = 1.0 / fs

        // Random walk step: bias[k] = bias[k-1] + N(0, BI * sqrt(tau0))
        let walkStep = biasInstability * tau0.squareRoot()

        var rng = SplitMix64(seed: 77777)
        var bias = 0.0
        var rates = [Double](repeating: 0, count: n)
        for i in 0..<n {
            bias += rng.nextGaussian() * walkStep
            rates[i] = rng.nextGaussian() * sigma + bias
        }

        let result = AllanDeviation.analyseGyro(rates: rates, sampleRate: fs)

        // The curve must show a minimum below the first point — if it doesn't,
        // the recording wasn't long enough or the walk was too weak.
        let minAdev = result.curve.map(\.adev).min() ?? .infinity
        XCTAssertLessThan(minAdev, result.curve[0].adev,
                          "The ADEV curve must turn over and have a minimum")

        // The recovered BI should be within a factor of 2 of the injected value.
        // This is generous but meaningful: it proves the algorithm reads the
        // minimum and applies the 0.664 correction, which is its job. Precision
        // is a function of session length, not algorithm correctness.
        XCTAssertGreaterThan(result.gyroBiasInstability, biasInstability * 0.5,
                             "BI too low: expected ~\(biasInstability), got \(result.gyroBiasInstability)")
        XCTAssertLessThan(result.gyroBiasInstability, biasInstability * 2.0,
                          "BI too high: expected ~\(biasInstability), got \(result.gyroBiasInstability)")
    }

    // MARK: - Test: -1/2 slope verification

    /// The defining property of white noise in an Allan deviation plot is a -1/2
    /// slope on the log-log curve. If this slope is wrong, the entire analysis is
    /// meaningless — it would mean we're computing something other than ADEV.
    func testWhiteNoiseHasMinusHalfSlope() {
        let sigma = 0.005
        let fs = 200.0
        let duration = 1000.0  // long enough for several octaves in the white regime
        let n = Int(duration * fs)

        var rng = SplitMix64(seed: 99999)
        let rates = (0..<n).map { _ in rng.nextGaussian() * sigma }

        let curve = AllanDeviation.compute(rates: rates, tau0: 1.0 / fs)

        // Fit slope over the first decade of tau (the pure white-noise region).
        // With 200 Hz and 1000s of data, tau ranges from 0.005s to ~250s.
        // The white regime dominates at short tau; we fit from tau0 to 10*tau0.
        let tau0 = 1.0 / fs
        let slope = AllanDeviation.fitLogLogSlope(
            curve: curve,
            tauRange: tau0...tau0 * 64  // first 7 octaves — safely in white regime
        )

        guard let slope = slope else {
            return XCTFail("fitLogLogSlope returned nil — not enough points in range")
        }

        // The slope should be -0.5. Tolerance ±0.05 accounts for finite-sample noise.
        XCTAssertEqual(slope, -0.5, accuracy: 0.05,
                       "White noise ADEV slope should be -0.5, got \(slope)")
    }

    // MARK: - Test: Curve structure

    /// Verify the curve is monotonically decreasing in the white-noise regime
    /// (short tau) and that tau values are octave-spaced.
    func testCurveIsOctaveSpacedAndMonotonicInWhiteRegime() {
        let sigma = 0.01
        let fs = 100.0
        let n = 100_000  // 1000s at 100 Hz

        var rng = SplitMix64(seed: 42)
        let rates = (0..<n).map { _ in rng.nextGaussian() * sigma }

        let curve = AllanDeviation.compute(rates: rates, tau0: 1.0 / fs)

        XCTAssertGreaterThan(curve.count, 5, "need enough octaves for a meaningful test")

        // Tau values should double each step.
        for i in 1..<curve.count {
            XCTAssertEqual(curve[i].tau / curve[i - 1].tau, 2.0, accuracy: 1e-10,
                           "tau must be octave-spaced")
        }

        // In pure white noise, ADEV decreases monotonically.
        // Check at least the first 8 points (up to tau = 128 * tau0 = 1.28s).
        let checkCount = min(8, curve.count - 1)
        for i in 0..<checkCount {
            XCTAssertGreaterThan(curve[i].adev, curve[i + 1].adev,
                                 "ADEV must decrease with tau in white noise (octave \(i))")
        }
    }

    // MARK: - Test: Accelerometer noise density recovery

    func testAccelNoiseDensityRecovery() {
        let sigma = 0.002     // m/s^2
        let fs = 100.0
        let duration = 600.0
        let n = Int(duration * fs)
        let expectedNoiseDensity = sigma / fs.squareRoot()  // 0.0002 m/s^2/sqrt(Hz)

        var rng = SplitMix64(seed: 54321)
        let rates = (0..<n).map { _ in rng.nextGaussian() * sigma }

        let result = AllanDeviation.analyseAccel(rates: rates, sampleRate: fs)

        let tolerance = expectedNoiseDensity * 0.10
        XCTAssertEqual(result.accelNoiseDensity, expectedNoiseDensity, accuracy: tolerance,
                       "Accel noise density: expected \(expectedNoiseDensity), got \(result.accelNoiseDensity)")
    }

    // MARK: - Test: Empty and minimal input

    func testEmptyInputReturnsEmptyCurve() {
        let curve = AllanDeviation.compute(rates: [], tau0: 0.01)
        XCTAssertTrue(curve.isEmpty)
    }

    func testSingleSampleReturnsEmptyCurve() {
        let curve = AllanDeviation.compute(rates: [1.0], tau0: 0.01)
        // N = 2 phase points, need 2m < N, so m=1 requires N > 2. With N=2, empty.
        XCTAssertTrue(curve.isEmpty)
    }

    func testTwoSamplesProducesOnePoint() {
        // N = 3 phase points, m=1: terms = N - 2*1 + 1 = 2 >= 1
        let curve = AllanDeviation.compute(rates: [1.0, 1.0], tau0: 0.01)
        XCTAssertEqual(curve.count, 1)
    }

    // MARK: - Test: formatAsConfig produces parseable output

    func testFormatAsConfigContainsAllFields() {
        let gyro = AllanDeviation.GyroResult(
            gyroNoiseDensity: 1.23e-4,
            gyroBiasInstability: 4.56e-6,
            curve: []
        )
        let accel = AllanDeviation.AccelResult(accelNoiseDensity: 9.81e-4, curve: [])

        let output = AllanDeviation.formatAsConfig(gyroY: gyro, accelZ: accel)
        XCTAssertTrue(output.contains("gyroNoiseDensity"))
        XCTAssertTrue(output.contains("gyroBiasInstability"))
        XCTAssertTrue(output.contains("accelNoiseDensity"))
        XCTAssertTrue(output.contains("rad/s/sqrt(Hz)"))
        XCTAssertTrue(output.contains("rad/s"))
        XCTAssertTrue(output.contains("m/s^2/sqrt(Hz)"))
    }
}
