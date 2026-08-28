import XCTest
@testable import MotoTelemetryCore

final class AttitudeSmootherTests: XCTestCase {

    /// A gate-open verdict, for tests that only need `propagate` to run.
    ///
    /// `propagate` consults the gate because the deferred gravity anchor must not
    /// accept a sample the gate rejected (a magnitude-only test cannot see a tilt).
    /// Tests that seed an explicit `gravityAnchor` are already anchored and ignore it.
    private let openVerdict = ValidityGate.Verdict(isOpen: true, heldFor: 1.0, reason: .open)


    private let bike = UUID()

    private func alignment() -> MountAlignment { .identity(bikeProfileID: bike) }

    /// Builds a synthetic wheelie and runs the gate over it, so the smoother sees the
    /// same verdicts the live pipeline would.
    private func makeWindow(peakDegrees: Double = 45,
                            gyroBiasDegPerSec: Double = 0.3,
                            grade: Double = 0,
                            vibration: Double = 0,
                            vibrationHz: Double = 83)
        -> (inputs: [AttitudeSmoother.Input], truth: (TimeInterval) -> Double,
            eventEnd: TimeInterval) {
        var scenario = SyntheticSource.Scenario()
        scenario.peakPitch = peakDegrees * .pi / 180
        scenario.gyroBias = Vector3(0, -gyroBiasDegPerSec * .pi / 180, 0)
        scenario.roadGrade = grade
        scenario.vibrationAmplitude = vibration
        scenario.vibrationFrequency = vibrationHz
        scenario.emitGNSS = false
        // Long enough that the wheel-down anchor is well inside the window.
        scenario.duration = 26.0

        var source = SyntheticSource(scenario: scenario)
        var gate = ValidityGate(config: Config())
        var inputs: [AttitudeSmoother.Input] = []
        while let sample = source.next() {
            guard case .imu(let imu) = sample else { continue }
            let verdict = gate.process(imu) ?? ValidityGate.Verdict(
                isOpen: false, heldFor: 0, reason: .noData)
            inputs.append(AttitudeSmoother.Input(time: imu.time,
                                                rotationRate: imu.rotationRate,
                                                specificForce: imu.specificForce,
                                                saturated: imu.saturated,
                                                verdict: verdict))
        }
        let s = scenario
        let eventEnd = s.eventStart + s.rampDuration + s.holdDuration + s.rampDuration
        let truthSource = SyntheticSource(scenario: scenario)
        return (inputs, { truthSource.truePitch(at: $0) }, eventEnd)
    }

    private func bias(_ degPerSec: Double, sigma: Double = 1e-4) -> BiasEstimate {
        // The filter is told bias is ZERO: recovering it is the smoother's job.
        BiasEstimate(bias: .zero,
                     sigma: Vector3(sigma, sigma, sigma),
                     sampleCount: 800,
                     monotonicTime: 0,
                     bikeProfileID: bike)
    }

    private func worstError(_ outputs: [AttitudeSmoother.Output],
                           truth: (TimeInterval) -> Double,
                           over range: ClosedRange<TimeInterval>) -> Double {
        var worst = 0.0
        for o in outputs where range.contains(o.time) {
            worst = max(worst, abs(o.pitch - truth(o.time)) * 180 / .pi)
        }
        return worst
    }

    // MARK: - T4.3 accuracy

    /// The headline criterion: smoothed error under 0.5 deg across the event, with an
    /// injected gyro bias the filter was never told about.
    func testSmoothedAccuracyOnTheNominalScenario() throws {
        let (inputs, truth, eventEnd) = makeWindow(peakDegrees: 45,
                                                   gyroBiasDegPerSec: 0.3)
        let smoother = AttitudeSmoother(config: Config(), alignment: alignment())
        guard case .success(let outputs) = smoother.smooth(window: inputs,
                                                          eventEnd: eventEnd,
                                                          initialBias: bias(0.3)) else {
            return XCTFail("smoothing failed")
        }
        let error = worstError(outputs, truth: truth, over: 6.0...eventEnd)
        XCTAssertLessThan(error, 0.5,
            String(format: "smoothed error %.3f deg over the event", error))
    }

    func testSmoothedBeatsTheForwardFilterOnTheSameData() throws {
        let (inputs, truth, eventEnd) = makeWindow(gyroBiasDegPerSec: 0.5)

        // Forward-only, same configuration.
        var filter = AttitudeESKF(config: Config(),
                                  alignment: alignment(),
                                  initialBias: bias(0.5),
                                  gravityAnchor: inputs[0].specificForce)
        var forwardWorst = 0.0
        for input in inputs {
            let imu = IMUSample(time: input.time,
                               rotationRate: input.rotationRate,
                               specificForce: input.specificForce,
                               saturated: input.saturated)
            filter.propagate(imu, verdict: openVerdict)
            filter.updateWithGravity(imu, verdict: input.verdict)
            if input.time >= 6.0 && input.time <= eventEnd {
                forwardWorst = max(forwardWorst,
                                   abs(filter.pitch - truth(input.time)) * 180 / .pi)
            }
        }

        let smoother = AttitudeSmoother(config: Config(), alignment: alignment())
        guard case .success(let outputs) = smoother.smooth(window: inputs,
                                                          eventEnd: eventEnd,
                                                          initialBias: bias(0.5)) else {
            return XCTFail("smoothing failed")
        }
        let smoothedWorst = worstError(outputs, truth: truth, over: 6.0...eventEnd)

        XCTAssertLessThan(smoothedWorst, forwardWorst,
            String(format: "the backward pass must beat forward-only: %.3f vs %.3f deg",
                   smoothedWorst, forwardWorst))
    }

    func testAccuracyMatrixAcrossPeakAndBias() throws {
        for peak in [30.0, 45.0, 70.0] {
            for biasRate in [0.05, 0.3, 0.5] {
                let (inputs, truth, eventEnd) =
                    makeWindow(peakDegrees: peak, gyroBiasDegPerSec: biasRate)
                let smoother = AttitudeSmoother(config: Config(), alignment: alignment())
                guard case .success(let outputs) =
                        smoother.smooth(window: inputs, eventEnd: eventEnd,
                                        initialBias: bias(biasRate)) else {
                    return XCTFail("smoothing failed at peak \(peak) bias \(biasRate)")
                }
                let error = worstError(outputs, truth: truth, over: 6.0...eventEnd)
                XCTAssertLessThan(error, 0.5,
                    String(format: "peak %.0f deg, bias %.2f deg/s -> %.3f deg error",
                           peak, biasRate, error))
            }
        }
    }

    func testSmoothingUnderRoadGrade() throws {
        for grade in [-4.0, 4.0] {
            let (inputs, truth, eventEnd) =
                makeWindow(gyroBiasDegPerSec: 0.3, grade: grade * .pi / 180)
            let smoother = AttitudeSmoother(config: Config(), alignment: alignment())
            guard case .success(let outputs) =
                    smoother.smooth(window: inputs, eventEnd: eventEnd,
                                    initialBias: bias(0.3)) else {
                return XCTFail("smoothing failed at grade \(grade)")
            }
            // truePitch excludes the grade, and the smoother reports absolute pitch,
            // so the constant offset is expected; subtract it via the baseline the
            // pipeline would apply.
            var baseline = GradeBaseline(config: Config())
            var worst = 0.0
            for (o, input) in zip(outputs, inputs) {
                let corrected = baseline.process(GradeBaseline.Input(
                    pitch: o.pitch, gateOpen: input.verdict.isOpen,
                    time: o.time)) ?? o.pitch
                if o.time >= 6.0 && o.time <= eventEnd {
                    worst = max(worst, abs(corrected - truth(o.time)) * 180 / .pi)
                }
            }
            XCTAssertLessThan(worst, 2.0,
                String(format: "grade %.0f deg -> %.3f deg error", grade, worst))
        }
    }

    // MARK: - T4.4 idempotence and dual numbers

    func testSmoothingIsIdempotentAndDeterministic() throws {
        let (inputs, _, eventEnd) = makeWindow()
        let smoother = AttitudeSmoother(config: Config(), alignment: alignment())
        guard case .success(let first) = smoother.smooth(window: inputs,
                                                        eventEnd: eventEnd,
                                                        initialBias: bias(0.3)),
              case .success(let second) = smoother.smooth(window: inputs,
                                                         eventEnd: eventEnd,
                                                         initialBias: bias(0.3)) else {
            return XCTFail("smoothing failed")
        }
        XCTAssertEqual(first.count, second.count)
        for (a, b) in zip(first, second) {
            XCTAssertEqual(a.pitch, b.pitch, accuracy: 0,
                           "re-smoothing unchanged input must be bit-identical")
            XCTAssertEqual(a.bias.y, b.bias.y, accuracy: 0)
            XCTAssertEqual(a.pitchSigma, b.pitchSigma, accuracy: 0)
        }
    }

    func testSmoothedUncertaintyIsSmallerThanFiltered() throws {
        let (inputs, _, eventEnd) = makeWindow(gyroBiasDegPerSec: 0.5)
        let smoother = AttitudeSmoother(config: Config(), alignment: alignment())
        guard case .success(let outputs) = smoother.smooth(window: inputs,
                                                          eventEnd: eventEnd,
                                                          initialBias: bias(0.5)) else {
            return XCTFail("smoothing failed")
        }
        // Mid-event, where the forward filter is blindest, is where the backward pass
        // should help most.
        let midEvent = outputs.first { $0.time >= 9.0 }!
        var filter = AttitudeESKF(config: Config(),
                                  alignment: alignment(),
                                  initialBias: bias(0.5),
                                  gravityAnchor: inputs[0].specificForce)
        var filteredSigma = 0.0
        for input in inputs where input.time <= midEvent.time {
            let imu = IMUSample(time: input.time,
                               rotationRate: input.rotationRate,
                               specificForce: input.specificForce,
                               saturated: input.saturated)
            filter.propagate(imu, verdict: openVerdict)
            filter.updateWithGravity(imu, verdict: input.verdict)
            filteredSigma = filter.pitchSigma
        }
        XCTAssertLessThan(midEvent.pitchSigma, filteredSigma,
            "future information must reduce uncertainty, not merely move the estimate")
    }

    // MARK: - T4.2 windowing and T4.6 degradation

    func testInsufficientPostEventAnchorIsReportedNotSmoothedAgainstNothing() throws {
        let (inputs, _, eventEnd) = makeWindow()
        // Truncate right at the event's end: there is no wheel-down anchor left.
        let truncated = inputs.filter { $0.time <= eventEnd + 0.2 }
        let smoother = AttitudeSmoother(config: Config(), alignment: alignment())
        let result = smoother.smooth(window: truncated,
                                     eventEnd: eventEnd,
                                     initialBias: bias(0.3))
        guard case .failure(let failure) = result,
              case .insufficientPostEventAnchor(let found, let required) = failure else {
            return XCTFail("expected insufficientPostEventAnchor, got \(result)")
        }
        XCTAssertLessThan(found, required)
    }

    func testTooFewSamplesIsRefused() {
        let smoother = AttitudeSmoother(config: Config(), alignment: alignment())
        let result = smoother.smooth(window: [], initialBias: nil)
        guard case .failure(.tooFewSamples) = result else {
            return XCTFail("expected tooFewSamples")
        }
    }

    /// T4.1 / design 9.2 — the memory arithmetic that justifies windowing per event
    /// rather than smoothing a whole session.
    func testPerSampleFootprintJustifiesWindowing() {
        let bytes = AttitudeSmoother.bytesPerSample
        XCTAssertLessThan(bytes, 500, "per-sample storage should be a few hundred bytes")

        let thirtySecondWindow = 3_000 * bytes
        let thirtyMinuteSession = 180_000 * bytes
        XCTAssertLessThan(thirtySecondWindow, 2 * 1024 * 1024,
                          "an event window must fit comfortably in a couple of MB")
        XCTAssertGreaterThan(thirtyMinuteSession, 30 * 1024 * 1024,
            "a whole session would be tens of MB of transient allocation, which is "
            + "the reason the smoother is windowed - if this ever stops being true, "
            + "revisit the decision rather than leaving a stale comment")
    }

    /// Heavy vibration does not merely add noise to the smoothed number — it removes
    /// it entirely, and that is the correct outcome.
    ///
    /// 0.5 m/s^2 of excitation keeps |f| outside the gate's +/-0.03 g window, so the
    /// gate never opens after the wheel comes down. No gate-open samples means no
    /// gravity anchor, and the backward pass has nothing to carry back. So a bad mount
    /// does not cost you a slightly worse leaderboard number, it costs you the
    /// smoothed number altogether — which is a product consequence worth knowing, and
    /// exactly why mechanical isolation is mandatory rather than advisory.
    func testHeavyVibrationRemovesTheAnchorAndSmoothingIsRefused() throws {
        let (inputs, _, eventEnd) = makeWindow(gyroBiasDegPerSec: 0.3,
                                               vibration: 0.5,
                                               vibrationHz: 83)
        let smoother = AttitudeSmoother(config: Config(), alignment: alignment())
        let result = smoother.smooth(window: inputs,
                                     eventEnd: eventEnd,
                                     initialBias: bias(0.3))
        guard case .failure(let failure) = result,
              case .insufficientPostEventAnchor(let found, _) = failure else {
            return XCTFail("heavy vibration must refuse to smooth, got \(result)")
        }
        XCTAssertEqual(found, 0,
                       "vibration this large keeps the gate shut for the whole window")
    }

    /// Mild in-band vibration leaves the anchor intact, so the smoothed number
    /// survives. Guards against the refusal above being over-eager.
    func testMildVibrationStillSmooths() throws {
        let (inputs, truth, eventEnd) = makeWindow(gyroBiasDegPerSec: 0.3,
                                                   vibration: 0.1,
                                                   vibrationHz: 83)
        let smoother = AttitudeSmoother(config: Config(), alignment: alignment())
        guard case .success(let outputs) = smoother.smooth(window: inputs,
                                                          eventEnd: eventEnd,
                                                          initialBias: bias(0.3)) else {
            return XCTFail("mild in-band vibration must still smooth")
        }
        let error = worstError(outputs, truth: truth, over: 6.0...eventEnd)
        XCTAssertLessThan(error, 1.0,
            String(format: "smoothed error under mild vibration: %.3f deg", error))
    }

    // MARK: - Quaternion log, which the recursion depends on

    func testQuaternionLogInvertsExp() {
        for v in [Vector3(0.1, -0.2, 0.05), Vector3(0, 0.5, 0), Vector3(1.2, 0.3, -0.7)] {
            let round = Quaternion.exp(rotationVector: v).log
            XCTAssertEqual(round.x, v.x, accuracy: 1e-12)
            XCTAssertEqual(round.y, v.y, accuracy: 1e-12)
            XCTAssertEqual(round.z, v.z, accuracy: 1e-12)
        }
        XCTAssertEqual(Quaternion.identity.log.magnitude, 0, accuracy: 1e-15)
    }

    func testQuaternionLogTakesTheShorterArc() {
        // q and -q are the same rotation; the log must not report a ~350 deg turn for
        // a tiny discrepancy, which would make the smoother inject a huge correction.
        let small = Quaternion.exp(rotationVector: Vector3(0, 0.01, 0))
        let negated = Quaternion(w: -small.w, x: -small.x, y: -small.y, z: -small.z)
        XCTAssertEqual(negated.log.magnitude, 0.01, accuracy: 1e-9)
    }
}
