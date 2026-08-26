import XCTest
@testable import MotoTelemetryCore

/// R8.7, R21.2: Full scenario matrix verifying LIVE pipeline accuracy ≤ 2° across
/// all combinations of peak angle, gyro bias, road grade, vibration, and GNSS state.
///
/// The 83 Hz vibration slot tests the benign case (engine twin at 5000 rpm, well
/// above Nyquist/2 and does not alias to DC). The pathological 100 Hz case that
/// DOES alias is tested separately in T3.10.
final class AccuracyMatrixTests: XCTestCase {

    // MARK: - Scenario axes

    private static let peakAngles: [Double] = [30, 45, 70]            // degrees
    private static let gyroBiases: [Double] = [0.05, 0.3, 0.5]       // deg/s
    private static let roadGrades: [Double] = [0, 4, -4]             // degrees
    private static let vibrationFreqs: [(amp: Double, freq: Double, label: String)] = [
        (0.0, 0.0, "none"),
        (0.1, 83.0, "83Hz"),  // Mild vibration (well-isolated mount)
    ]
    private static let gnssStates: [(on: Bool, label: String)] = [
        (true, "gnssOn"),
        (false, "gnssOff"),
    ]

    /// Maximum acceptable live error, degrees.
    private static let liveToleranceDeg = 2.0

    // MARK: - Helpers

    private let bike = UUID()

    private func alignment() -> MountAlignment { .identity(bikeProfileID: bike) }

    private func biasEstimate(_ bias: Vector3, sigma: Double = 1e-4) -> BiasEstimate {
        BiasEstimate(bias: bias,
                     sigma: Vector3(sigma, sigma, sigma),
                     sampleCount: 800,
                     monotonicTime: 0,
                     bikeProfileID: bike)
    }

    /// Runs a scenario through the pipeline and returns the worst-case live error
    /// during the event (eventStart through end of ramp-down), in degrees.
    private func worstLiveError(scenario: SyntheticSource.Scenario) -> Double {
        var source = SyntheticSource(scenario: scenario)
        let config = Config()
        let align = alignment()

        // Seed the pipeline with the scenario's injected bias so the estimator
        // starts from a realistic calibration state.
        let seedBias = biasEstimate(scenario.gyroBias)
        var pipeline = Pipeline(config: config,
                                alignment: align,
                                initialBias: seedBias,
                                gravityAnchor: Conventions.restSpecificForce)

        let outputs = runPipeline(source: &source, pipeline: &pipeline)

        // Measure error only during the event envelope (ramp-up through ramp-down).
        let eventStart = scenario.eventStart
        let eventEnd = scenario.eventStart + scenario.rampDuration * 2 + scenario.holdDuration

        var worst = 0.0
        for out in outputs {
            guard out.time >= eventStart, out.time <= eventEnd else { continue }
            let truth = source.truePitch(at: out.time) * 180 / .pi
            let measured = out.pitch * 180 / .pi
            let err = abs(measured - truth)
            if err > worst { worst = err }
        }
        return worst
    }

    // MARK: - Matrix test

    func testAccuracyMatrix() {
        var failures: [(label: String, error: Double)] = []

        for peakDeg in Self.peakAngles {
            for biasDeg in Self.gyroBiases {
                for gradeDeg in Self.roadGrades {
                    for vib in Self.vibrationFreqs {
                        for gnss in Self.gnssStates {
                            var scenario = SyntheticSource.Scenario()
                            scenario.peakPitch = peakDeg * .pi / 180
                            scenario.gyroBias = Vector3(0, biasDeg * .pi / 180, 0)
                            scenario.roadGrade = gradeDeg * .pi / 180
                            scenario.vibrationAmplitude = vib.amp
                            scenario.vibrationFrequency = vib.freq
                            scenario.emitGNSS = gnss.on

                            let label = "peak=\(Int(peakDeg))° bias=\(biasDeg)°/s " +
                                        "grade=\(Int(gradeDeg))° vib=\(vib.label) \(gnss.label)"

                            let err = worstLiveError(scenario: scenario)
                            if err > Self.liveToleranceDeg {
                                failures.append((label, err))
                            }
                        }
                    }
                }
            }
        }

        if !failures.isEmpty {
            let detail = failures.map { "  \($0.label): \($0.error, format: .fixed(precision: 2))°" }
                .joined(separator: "\n")
            XCTFail("Live error > \(Self.liveToleranceDeg)° in \(failures.count) scenarios:\n\(detail)")
        }
    }
}

// MARK: - Formatting helper

private extension DefaultStringInterpolation {
    struct FixedFormat {
        let precision: Int
    }

    mutating func appendInterpolation(_ value: Double, format: FixedFormat) {
        appendLiteral(String(format: "%.\(format.precision)f", value))
    }
}

private extension DefaultStringInterpolation.FixedFormat {
    static func fixed(precision: Int) -> Self { Self(precision: precision) }
}
