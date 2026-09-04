import XCTest
@testable import MotoTelemetryCore

/// Regression guards for the 2026-09-04 audit fixes.
///
/// Every bug below shipped on this branch with a GREEN test suite, so each one is
/// evidence about a blind spot rather than just a defect. They are collected here
/// instead of scattered into the per-type files because the useful thing to see is
/// the pattern: four of the five are a value or a timer that SURVIVED an event it
/// should not have survived (a re-anchor, a stream gap, a stream end), and the
/// fifth is a filter that was never applied. All four produced a plausible number
/// rather than an obviously broken one, which is why nothing caught them.
final class BetaAuditFixTests: XCTestCase {

    private let config = Config()

    // MARK: - A. An event open when the stream ends must still be emitted

    /// Feeds `samples` and returns every transition, then the `finish()` transition
    /// separately, so a test can assert on the end-of-stream one specifically.
    private func feedThenFinish(
        _ segmenter: inout EventSegmenter,
        _ samples: [(time: TimeInterval, pitch: Double, pitchRate: Double)]
    ) -> (during: [EventSegmenter.Transition], atEnd: EventSegmenter.Transition?) {
        var during: [EventSegmenter.Transition] = []
        for s in samples {
            if let t = segmenter.process(time: s.time, pitch: s.pitch, pitchRate: s.pitchRate) {
                during.append(t)
            }
        }
        return (during, segmenter.finish())
    }

    /// A wheelie STILL UP when the samples stop must produce an event.
    ///
    /// The bug: the only path that emitted `.end` was the exit dwell elapsing inside
    /// `processDisarming`, which cannot happen once samples stop. So a ride ended
    /// while still lofted produced NO event at all — and because the longest holds
    /// are the likeliest to be cut off, the loss was biased toward the rider's best
    /// runs. Precisely the data you would most want back.
    func testEventStillActiveAtStreamEndIsClosedAtTheLastSample() {
        var seg = EventSegmenter(config: config)
        let entry = config.eventEntryPitch
        let dt = 0.01

        // Rise above entry and STAY there for 2 s — well past the 1.0 s minDuration.
        var samples: [(TimeInterval, Double, Double)] = [(0, 0, 0)]
        for i in 0...200 {
            samples.append((0.01 + Double(i) * dt, entry + 0.05, 0.2))
        }
        let lastTime = samples.last!.0

        let (during, atEnd) = feedThenFinish(&seg, samples)

        XCTAssertTrue(during.contains { if case .onset = $0.kind { return true }; return false },
                      "an onset should have been emitted during the stream")
        XCTAssertFalse(during.contains { if case .end = $0.kind { return true }; return false },
                       "the event never came down, so no in-stream .end is possible")

        guard let atEnd, case .end(let endTime) = atEnd.kind else {
            return XCTFail("finish() must close an event left open in .active; got \(String(describing: atEnd?.kind))")
        }
        XCTAssertEqual(endTime, lastTime, accuracy: 1e-9,
                       "an event still in progress is truncated at the last sample seen — understating a hold, which is the right direction to be wrong in")
        XCTAssertEqual(seg.state, .idle, "finish() must leave the segmenter idle")
    }

    /// `minDuration` still applies through `finish()`: a stream ending shortly after
    /// a lift begins must NOT be promoted to a wheelie just because it was open.
    func testFinishStillDiscardsAnEventShorterThanMinDuration() {
        var seg = EventSegmenter(config: config)
        let entry = config.eventEntryPitch
        let dt = 0.01

        // Above entry for only ~0.30 s: long enough to arm (0.15 s) but far short of
        // the 1.0 s minDuration.
        var samples: [(TimeInterval, Double, Double)] = [(0, 0, 0)]
        for i in 0...30 {
            samples.append((0.01 + Double(i) * dt, entry + 0.05, 0.2))
        }

        let (_, atEnd) = feedThenFinish(&seg, samples)

        guard let atEnd, case .discarded(let duration) = atEnd.kind else {
            return XCTFail("expected .discarded, got \(String(describing: atEnd?.kind))")
        }
        XCTAssertLessThan(duration, config.eventMinDuration)
        XCTAssertEqual(seg.state, .idle)
    }

    /// `finish()` from a state where no onset was ever emitted has nothing to close.
    /// Returning a transition here would invent an event that never started.
    func testFinishReturnsNilWhenNoEventWasEverOpened() {
        // .idle — never crossed entry at all.
        var idle = EventSegmenter(config: config)
        _ = idle.process(time: 0.0, pitch: 0, pitchRate: 0)
        _ = idle.process(time: 0.01, pitch: 0, pitchRate: 0)
        XCTAssertNil(idle.finish(), "no crossing ever happened, so there is no event")

        // .arming — crossed entry but the dwell never completed, so no onset was
        // emitted and there is no event to close.
        var arming = EventSegmenter(config: config)
        _ = arming.process(time: 0.0, pitch: 0, pitchRate: 0)
        _ = arming.process(time: 0.01, pitch: config.eventEntryPitch + 0.05, pitchRate: 0.5)
        XCTAssertEqual(arming.state, .arming, "precondition: should be arming, not active")
        XCTAssertNil(arming.finish(), "arming never emitted an onset, so nothing to close")
    }

    // MARK: - B. A stream gap must not satisfy a dwell

    /// A dwell asserts pitch was SUSTAINED. A gap is the absence of evidence for
    /// that, so a single post-gap sample must not complete it.
    ///
    /// The bug: dwell timers compared raw sample timestamps, so a sensor gap jumped
    /// `time` forward and ONE sample after the gap satisfied `time - armingStartTime
    /// >= entryDwell`. The 0.15 s debounce that exists to reject curb-pops was
    /// defeated by exactly the condition under which the data is least trustworthy.
    func testAGapDuringArmingDoesNotCommitAnEventOnOneSample() {
        var seg = EventSegmenter(config: config)
        let entry = config.eventEntryPitch

        _ = seg.process(time: 0.0, pitch: 0, pitchRate: 0)
        // Cross entry.
        _ = seg.process(time: 0.01, pitch: entry + 0.05, pitchRate: 0.5)
        XCTAssertEqual(seg.state, .arming)

        // Now a gap far bigger than maxSampleGap AND bigger than entryDwell. Under
        // the old arithmetic this single sample committed the event.
        let gapped = 0.01 + config.maxSampleGap + 1.0
        let t = seg.process(time: gapped, pitch: entry + 0.05, pitchRate: 0.5)

        XCTAssertNil(t, "a gap must restart the dwell, not satisfy it")
        XCTAssertEqual(seg.state, .arming, "still arming — the dwell restarted from the post-gap sample")
    }

    /// The mirror case: a gap must not END an event either, which would truncate a
    /// hold that may well have continued across the missing span.
    func testAGapDuringDisarmingDoesNotEndTheEvent() {
        var seg = EventSegmenter(config: config)
        let entry = config.eventEntryPitch
        let exit = config.eventExitPitch
        let dt = 0.01

        // Establish a committed event: above entry for 2 s.
        _ = seg.process(time: 0.0, pitch: 0, pitchRate: 0)
        var t = 0.01
        for _ in 0...200 {
            _ = seg.process(time: t, pitch: entry + 0.05, pitchRate: 0.2)
            t += dt
        }
        XCTAssertEqual(seg.state, .active, "precondition: event must be committed")

        // Drop below exit to enter disarming.
        _ = seg.process(time: t, pitch: exit - 0.02, pitchRate: -0.5)
        XCTAssertEqual(seg.state, .disarming)

        // A gap larger than both maxSampleGap and exitDwell.
        let gapped = t + config.maxSampleGap + 1.0
        let transition = seg.process(time: gapped, pitch: exit - 0.02, pitchRate: -0.5)

        XCTAssertNil(transition, "a gap must restart the exit dwell, not complete it")
        XCTAssertEqual(seg.state, .disarming)
    }

    // MARK: - C. A re-anchor must not integrate across itself

    /// Re-anchoring declares the pose the rider is holding to be the new zero. The
    /// next sample must not then rotate that fresh zero by a span measured from
    /// BEFORE the re-anchor.
    ///
    /// The bug: `lastTime` survived `anchor(with:)`, so the first post-re-zero
    /// sample computed its `dt` against a pre-anchor timestamp and integrated that
    /// whole span onto the attitude just declared level. A rider re-zeroing at a
    /// traffic light after a pause would watch their brand-new zero immediately
    /// read as tilted.
    func testReAnchorDoesNotIntegrateAcrossTheReZeroBoundary() {
        var estimator = CalibrateOnceEstimator(
            config: config,
            alignment: .identity(),
            bias: .zero,
            gravityAnchor: Conventions.restSpecificForce)

        // Integrate up to a clearly non-zero pitch.
        let dt = 0.01
        let rate = 20.0 * .pi / 180
        var t = 0.0
        for _ in 0...100 {
            estimator.integrate(IMUSample(time: t,
                                          rotationRate: Conventions.rotationRate(pitchRate: rate),
                                          specificForce: Conventions.restSpecificForce))
            t += dt
        }
        XCTAssertGreaterThan(estimator.pitch, 10.0 * .pi / 180, "precondition: should be well off level")

        // Re-anchor at a level pose: this pose IS the new zero.
        estimator.anchor(with: Conventions.restSpecificForce)
        XCTAssertEqual(estimator.pitch, 0, accuracy: 1e-9,
                       "the pose just anchored must read as zero")

        // A sample arriving well after the re-anchor. Its dt against the PRE-anchor
        // timestamp would be ~0.9 s of fabricated rotation.
        let jumped = t + 0.9
        estimator.integrate(IMUSample(time: jumped,
                                      rotationRate: Conventions.rotationRate(pitchRate: rate),
                                      specificForce: Conventions.restSpecificForce))
        XCTAssertEqual(estimator.pitch, 0, accuracy: 1e-9,
                       "the first post-anchor sample only re-establishes the timebase; integrating it would tilt the zero the rider just set")

        // And normal integration must resume immediately afterward.
        estimator.integrate(IMUSample(time: jumped + dt,
                                      rotationRate: Conventions.rotationRate(pitchRate: rate),
                                      specificForce: Conventions.restSpecificForce))
        XCTAssertEqual(estimator.pitch, rate * dt, accuracy: 1e-6,
                       "one normal step after the re-anchor integrates exactly one dt")
    }

    // MARK: - D. An unknown rate must not read as the last known rate

    /// When `integrate` cannot advance, `pitchRate` must go to zero rather than
    /// retain a value from before the discontinuity.
    ///
    /// The bug: `pitchRate` was refreshed only inside the successful path, so after
    /// a gap the cue kept predicting a threshold crossing from a rate that was
    /// seconds out of date — "I do not know" silently reading as "unchanged".
    func testASkippedSampleZeroesPitchRateRatherThanLeavingItStale() {
        var estimator = CalibrateOnceEstimator(
            config: config,
            alignment: .identity(),
            bias: .zero,
            gravityAnchor: Conventions.restSpecificForce)

        let dt = 0.01
        let rate = 30.0 * .pi / 180
        var t = 0.0
        for _ in 0...10 {
            estimator.integrate(IMUSample(time: t,
                                          rotationRate: Conventions.rotationRate(pitchRate: rate),
                                          specificForce: Conventions.restSpecificForce))
            t += dt
        }
        XCTAssertEqual(estimator.pitchRate, rate, accuracy: 1e-9,
                       "precondition: a live rate is being reported")

        // A dt beyond maxIntegrationDt: the estimator cannot integrate this.
        let absurd = t + config.maxIntegrationDt + 1.0
        let advanced = estimator.integrate(
            IMUSample(time: absurd,
                      rotationRate: Conventions.rotationRate(pitchRate: rate),
                      specificForce: Conventions.restSpecificForce))

        XCTAssertFalse(advanced, "precondition: this sample must be rejected")
        XCTAssertEqual(estimator.pitchRate, 0, accuracy: 1e-12,
                       "an unknown rate must not be reported as the previous rate")
    }

    // MARK: - E. A heuristic hold window must not win a personal best

    /// `bestConsistency` must consider only events whose hold window was actually
    /// resolved from pitch-rate crossings.
    ///
    /// The bug was worse than a missing filter. The heuristic fallback takes a fixed
    /// narrow slice around the event midpoint, which is both shorter and better
    /// centred than a genuine hold, so it systematically produces a LOWER standard
    /// deviation. An unresolved event was therefore not merely eligible for
    /// best-consistency, it was biased toward winning it.
    func testBestConsistencyIgnoresUnresolvedHoldWindows() {
        func event(onset: TimeInterval, stdDev: Double, resolved: Bool) -> EventMetrics {
            EventMetrics(onset: onset,
                         end: onset + 2,
                         duration: 2,
                         liveMaxAngle: 0.5,
                         averageHeldAngle: 0.4,
                         angleStdDev: stdDev,
                         distance: nil,
                         entrySpeed: nil,
                         rollMin: 0,
                         rollMax: 0,
                         flags: [],
                         holdWindowResolved: resolved)
        }

        let resolved = event(onset: 0, stdDev: 0.10, resolved: true)
        // Lower stdDev, but measured over a heuristic window.
        let unresolved = event(onset: 3, stdDev: 0.01, resolved: false)

        let summary = SessionSummary(events: [resolved, unresolved])
        XCTAssertEqual(summary.bestConsistency?.onset, resolved.onset,
                       "the resolved event must win despite its higher stdDev")

        let noneResolved = SessionSummary(events: [unresolved])
        XCTAssertNil(noneResolved.bestConsistency,
                     "with nothing measured properly there is no best consistency to report — reporting the heuristic one would present a guess as a record")
    }
}
