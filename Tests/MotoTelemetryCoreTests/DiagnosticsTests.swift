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

    // NOTE: an `openVerdict` fixture used to live here for AttitudeESKF.propagate;
    // it was removed along with the ESKF path, as nothing surviving consumes it.
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
        // than that window is treated as engine buzz and does not close the gate at
        // all, so a single leaned sample correctly produces no transition.
        //
        // The lean length is DERIVED from `gateCloseConfirm` rather than hardcoded.
        // It used to be a literal 70 ms chosen against a 60 ms window, so raising the
        // window to 150 ms in v8 made this fail — not because one change stopped
        // emitting one event, which is what the test is about, but because 70 ms no
        // longer closes the gate at all. Derived, it asserts the invariant at whatever
        // the window is tuned to.
        let step = 0.01
        let leanSamples = Int(((Config().gateCloseConfirm + 0.02) / step).rounded(.up))
        var leanTime = 0.04
        for _ in 0..<leanSamples {
            _ = gate.process(IMUSample(time: leanTime, rotationRate: .zero,
                                       specificForce: Vector3(0, 0, -g / cos(30 * .pi / 180))))
            leanTime += step
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
            // The rewritten Pipeline publishes NOTHING until gravity anchors the
            // world frame (the ESKF's implicit anchoring is gone), so seed the
            // anchor explicitly — same value on both sink/no-sink runs, keeping the
            // byte-identical comparison honest.
            var pipeline = Pipeline(config: Config(),
                                    alignment: .identity(),
                                    initialBias: nil,
                                    gravityAnchor: Conventions.restSpecificForce,
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
        // NOTE: GradeBaseline and AttitudeESKF were deleted with the ESKF path, and
        // CalibrationTracker with the staleness model (calibrate-every-launch has no
        // stored estimate to age), so all three are dropped from this list; the
        // surviving instrumented stages are ValidityGate, EventSegmenter and
        // BiasEstimator. The Pipeline (also instrumented) is covered end-to-end by
        // the nil-sink test above via runPipeline, so it is not re-run here.
        var gate = ValidityGate(config: Config())
        var segmenter = EventSegmenter(config: Config())
        var bias = BiasEstimator(config: Config(), bikeProfileID: UUID())

        for i in 0..<300 {
            let t = Double(i) / 100.0
            let s = level(t)
            _ = gate.process(s)
            _ = segmenter.process(time: t, pitch: 0, pitchRate: 0)
            _ = bias.process(s)
        }
        // Reaching here without a trap is the assertion.
        XCTAssertEqual(gate.process(level(3.0))?.isOpen, true)
    }

    // MARK: - (d) event.time is the sample time, never a wall clock

    func testEventTimeAlwaysEqualsSampleTimeNeverWallClock() {
        let sink = RecordingSink()
        var gate = ValidityGate(config: Config(), sink: sink)
        // GradeBaseline was deleted with the ESKF path; the surviving sample-timed
        // stages that emit here are ValidityGate and EventSegmenter.
        var segmenter = EventSegmenter(config: Config(), sink: sink)

        // Sample times deliberately in the past relative to any wall clock, so a
        // stray Date() would be obvious (it would be ~1.8e9, not < 5).
        let times = stride(from: 0.0, through: 4.0, by: 0.01)
        for t in times {
            _ = gate.process(level(t))
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
