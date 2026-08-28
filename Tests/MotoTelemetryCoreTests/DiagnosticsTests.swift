import XCTest
@testable import MotoTelemetryCore

/// A DiagnosticSink that keeps every event, for assertions. Thread-unsafe by
/// design — tests drive it single-threaded, which is the only place a recording
/// sink is legitimate.
final class RecordingSink: DiagnosticSink, @unchecked Sendable {

    private(set) var events: [DiagnosticEvent] = []
    func emit(_ event: DiagnosticEvent) { events.append(event) }

    func events(category: String) -> [DiagnosticEvent] {
        events.filter { $0.category == category }
    }
}

final class DiagnosticsTests: XCTestCase {

    /// A gate-open verdict, for tests that only need `propagate` to run.
    ///
    /// `propagate` consults the gate because the deferred gravity anchor must not
    /// accept a sample the gate rejected (a magnitude-only test cannot see a tilt).
    /// Tests that seed an explicit `gravityAnchor` are already anchored and ignore it.
    private let openVerdict = ValidityGate.Verdict(isOpen: true, heldFor: 1.0, reason: .open)
    private let g = 9.80665

    private func level(_ t: TimeInterval, saturated: Bool = false) -> IMUSample {
        IMUSample(time: t, rotationRate: .zero,
                  specificForce: Vector3(0, 0, -9.80665), saturated: saturated)
    }

    // MARK: - (a) one reason change emits exactly one transition event

    func testOneGateReasonChangeEmitsExactlyOneEvent() {
        let sink = RecordingSink()
        var gate = ValidityGate(config: Config(), sink: sink)

        // First sample at t=0 establishes the initial reason (dwellNotMet) — one
        // event. Keep feeding identical LEVEL samples inside the same 1 s window:
        // the reason does not change and no heartbeat is due, so still one event.
        _ = gate.process(level(0.00))
        let afterFirst = sink.events(category: "gate").count
        XCTAssertEqual(afterFirst, 1, "first sample should emit one gate event")

        _ = gate.process(level(0.01))
        _ = gate.process(level(0.02))
        _ = gate.process(level(0.03))
        XCTAssertEqual(sink.events(category: "gate").count, 1,
                       "identical reason within the heartbeat window must not re-emit")

        // Now flip the reason exactly once: a sustained lean pushes |f| out of band.
        // It must be SUSTAINED — `Config.gateCloseConfirm` means a violation shorter
        // than ~60 ms is treated as engine buzz and does not close the gate at all, so
        // a single leaned sample correctly produces no transition. Feeding 70 ms of
        // lean crosses the window exactly once, which is still one reason change.
        var leanTime = 0.04
        for _ in 0..<8 {
            _ = gate.process(IMUSample(time: leanTime, rotationRate: .zero,
                                       specificForce: Vector3(0, 0, -g / cos(30 * .pi / 180))))
            leanTime += 0.01
        }
        let gateEvents = sink.events(category: "gate")
        XCTAssertEqual(gateEvents.count, 2,
                       "one reason change should add exactly one event")
        XCTAssertTrue(gateEvents.last!.message.contains("specificForceOutOfBand"))
    }

    // MARK: - (b) rate discipline: 200 identical samples do not emit 200 events

    func testTwoHundredIdenticalSamplesDoNotEmitTwoHundredEvents() {
        let sink = RecordingSink()
        var gate = ValidityGate(config: Config(), sink: sink)

        // 200 samples at 100 Hz = 2.0 s of identical, unchanging LEVEL input.
        // Expect: 1 transition (first sample) + heartbeats at ~1 Hz. Nowhere near
        // 200. The gate reason DOES change once (dwellNotMet -> open at 0.5 s), so
        // allow for that single extra transition too.
        for i in 0..<200 {
            _ = gate.process(level(Double(i) / 100.0))
        }
        let count = sink.events(category: "gate").count
        XCTAssertLessThan(count, 10,
                          "rate discipline failed: \(count) events for 200 samples")
        XCTAssertGreaterThan(count, 0, "should have emitted at least the first transition")
    }

    // MARK: - (c) nil sink: no crash, byte-identical behaviour

    func testNilSinkProducesByteIdenticalPipelineOutput() {
        func run(sink: DiagnosticSink?) -> [PipelineOutput] {
            var scenario = SyntheticSource.Scenario()
            scenario.duration = 12.0
            scenario.gyroBias = Vector3(0.01, -0.02, 0.005)
            scenario.roadGrade = 2.0 * .pi / 180
            var source = SyntheticSource(scenario: scenario)
            var pipeline = Pipeline(config: Config(),
                                    alignment: .identity(),
                                    initialBias: nil,
                                    sink: sink)
            return runPipeline(source: &source, pipeline: &pipeline)
        }

        let withoutSink = run(sink: nil)
        let withSink = run(sink: RecordingSink())

        XCTAssertFalse(withoutSink.isEmpty)
        XCTAssertEqual(withoutSink.count, withSink.count,
                       "sink presence changed the number of pipeline outputs")
        // Equatable PipelineOutput: assert every record is identical.
        XCTAssertEqual(withoutSink, withSink,
                       "diagnostics must be purely additive — output must be byte-identical")
    }

    func testNilSinkAcrossEveryInstrumentedStageDoesNotCrash() {
        // Exercise each stage with its default (nil) sink — the shipped path when
        // no logging is attached — and assert it simply runs.
        var gate = ValidityGate(config: Config())
        var baseline = GradeBaseline(config: Config())
        var segmenter = EventSegmenter(config: Config())
        var bias = BiasEstimator(config: Config(), bikeProfileID: UUID())
        var tracker = CalibrationTracker(config: Config())
        var eskf = AttitudeESKF(config: Config(), alignment: .identity(), initialBias: nil)

        for i in 0..<300 {
            let t = Double(i) / 100.0
            let s = level(t)
            _ = gate.process(s)
            _ = baseline.process(GradeBaseline.Input(pitch: 0, gateOpen: true, time: t))
            _ = segmenter.process(time: t, pitch: 0, pitchRate: 0)
            _ = bias.process(s)
            eskf.propagate(s, verdict: openVerdict)
            _ = tracker.update(now: t)
        }
        // Reaching here without a trap is the assertion.
        XCTAssertEqual(gate.process(level(3.0))?.isOpen, true)
    }

    // MARK: - (d) event.time is the sample time, never a wall clock

    func testEventTimeAlwaysEqualsSampleTimeNeverWallClock() {
        let sink = RecordingSink()
        var gate = ValidityGate(config: Config(), sink: sink)
        var baseline = GradeBaseline(config: Config(), sink: sink)
        var segmenter = EventSegmenter(config: Config(), sink: sink)

        // Sample times deliberately in the past relative to any wall clock, so a
        // stray Date() would be obvious (it would be ~1.8e9, not < 5).
        let times = stride(from: 0.0, through: 4.0, by: 0.01)
        for t in times {
            _ = gate.process(level(t))
            _ = baseline.process(GradeBaseline.Input(pitch: 0, gateOpen: true, time: t))
            _ = segmenter.process(time: t, pitch: 0, pitchRate: 0)
        }

        XCTAssertFalse(sink.events.isEmpty)
        for event in sink.events {
            XCTAssertGreaterThanOrEqual(event.time, 0)
            XCTAssertLessThanOrEqual(event.time, 4.0,
                "event.time \(event.time) is outside the sample range — a wall clock leaked in")
        }
    }

    // MARK: - The bias finish log carries raw std and n separately from SEM

    func testBiasFinishLogSeparatesRawStdFromReportedSigma() {
        let sink = RecordingSink()
        var bias = BiasEstimator(config: Config(), bikeProfileID: UUID(), sink: sink)

        // 10 s of dead-still, quiet gyro: calibration should complete and log a
        // "bias finish" line with rawStd*, sem*, meanBias*, n and sqrtN present.
        var t = 0.0
        while t <= 10.0 {
            _ = bias.process(level(t))
            t += 0.01
        }
        let finish = sink.events(category: "bias").first { $0.message == "bias finish" }
        XCTAssertNotNil(finish, "expected a bias finish diagnostic")
        guard let f = finish else { return }
        for key in ["rawStdX", "rawStdY", "rawStdZ", "semX", "semY", "semZ",
                    "meanBiasX", "meanBiasY", "meanBiasZ", "n", "sqrtN",
                    "biasSigmaLimit"] {
            XCTAssertNotNil(f.values[key], "bias finish missing \(key)")
        }
    }
}
