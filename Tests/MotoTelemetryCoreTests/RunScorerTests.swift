import XCTest
@testable import MotoTelemetryCore

final class RunScorerTests: XCTestCase {
    let config = Config()

    // MARK: - T5.3 Tests

    /// angleStdDev < 0.1° on a synthetic perfect hold — proves the metric measures
    /// steadiness over the HOLD WINDOW only. If it were computed over the whole
    /// event (including the ramp), even a perfect hold would show >2° from the
    /// entry/exit ramps.
    func testAngleStdDevOnPerfectHold() {
        var scorer = RunScorer(config: config)

        // Synthetic event: 0.3 s ramp up, 3 s perfect hold at 30°, 0.3 s ramp down.
        // The hold window detection should isolate the 3 s flat section.
        let holdAngle = 30.0 * .pi / 180
        let rampRate = 100.0 * .pi / 180 // fast ramp so hold window is unambiguous
        let dt = 0.01 // 100 Hz

        scorer.beginEvent(onset: 0.0, entrySpeed: 15.0)

        // Ramp up: 0.0 to 0.3 s
        for i in 0..<30 {
            let t = Double(i) * dt
            let pitch = holdAngle * (t / 0.3)
            scorer.addSample(time: t, pitch: pitch, pitchRate: rampRate, roll: 0)
        }
        // Perfect hold: 0.3 to 3.3 s — EXACTLY constant pitch, zero rate
        for i in 30..<330 {
            let t = Double(i) * dt
            scorer.addSample(time: t, pitch: holdAngle, pitchRate: 0, roll: 0)
        }
        // Ramp down: 3.3 to 3.6 s
        for i in 330..<360 {
            let t = Double(i) * dt
            let pitch = holdAngle * (1.0 - (t - 3.3) / 0.3)
            scorer.addSample(time: t, pitch: pitch, pitchRate: -rampRate, roll: 0)
        }

        let metrics = scorer.finalise(end: 3.6)

        // A perfect hold (constant pitch in the hold window) should have near-zero std dev.
        let stdDevDegrees = metrics.angleStdDev * 180 / .pi
        XCTAssertLessThan(stdDevDegrees, 0.1,
                         "A perfectly steady hold must show angleStdDev < 0.1° — " +
                         "if it doesn't, the metric is including the ramp (the whole-event bug)")
    }

    /// angleStdDev > 2° on a deliberately wobbly hold — proves the metric is
    /// sensitive to actual unsteadiness. Together with the perfect-hold test, this
    /// pair proves the metric measures what it claims.
    func testAngleStdDevOnWobblyHold() {
        var scorer = RunScorer(config: config)

        let baseAngle = 30.0 * .pi / 180
        let wobbleAmplitude = 4.0 * .pi / 180 // +/- 4° wobble
        let wobbleFreq = 2.0 // Hz
        let dt = 0.01

        scorer.beginEvent(onset: 0.0, entrySpeed: 15.0)

        // Ramp up: 0.0 to 0.3 s
        let rampRate = 100.0 * .pi / 180
        for i in 0..<30 {
            let t = Double(i) * dt
            let pitch = baseAngle * (t / 0.3)
            scorer.addSample(time: t, pitch: pitch, pitchRate: rampRate, roll: 0)
        }
        // Wobbly hold: 0.3 to 3.3 s — sinusoidal variation around baseAngle
        for i in 30..<330 {
            let t = Double(i) * dt
            let wobble = wobbleAmplitude * sin(2.0 * .pi * wobbleFreq * (t - 0.3))
            let pitch = baseAngle + wobble
            let rate = wobbleAmplitude * 2.0 * .pi * wobbleFreq *
                cos(2.0 * .pi * wobbleFreq * (t - 0.3))
            scorer.addSample(time: t, pitch: pitch, pitchRate: rate, roll: 0)
        }
        // Ramp down: 3.3 to 3.6 s
        for i in 330..<360 {
            let t = Double(i) * dt
            let pitch = baseAngle * (1.0 - (t - 3.3) / 0.3)
            scorer.addSample(time: t, pitch: pitch, pitchRate: -rampRate, roll: 0)
        }

        let metrics = scorer.finalise(end: 3.6)

        let stdDevDegrees = metrics.angleStdDev * 180 / .pi
        XCTAssertGreaterThan(stdDevDegrees, 2.0,
                            "A 4° sinusoidal wobble must produce angleStdDev > 2° — " +
                            "if it doesn't, the metric is averaging away real unsteadiness")
    }

    /// Distance returns nil with fewer than distanceMinFixes (4) GNSS fixes —
    /// an honest "I don't know" rather than a fabricated number from 2-3 points.
    func testDistanceNilWithTooFewFixes() {
        var scorer = RunScorer(config: config)
        scorer.beginEvent(onset: 0.0, entrySpeed: 15.0)

        // Add a few samples
        for i in 0..<100 {
            scorer.addSample(time: Double(i) * 0.01, pitch: 0.15, pitchRate: 0, roll: 0)
        }
        // Only 3 fixes — below distanceMinFixes (4)
        scorer.addGNSSFix(time: 0.0, speed: 15.0)
        scorer.addGNSSFix(time: 1.0, speed: 15.5)
        scorer.addGNSSFix(time: 2.0, speed: 16.0)

        let metrics = scorer.finalise(end: 3.0)
        XCTAssertNil(metrics.distance,
                    "Distance must be nil with only 3 fixes (< distanceMinFixes=4) — " +
                    "a trapezoid integral over 2 segments is too noisy to trust")
    }

    /// Distance returns a value with 5 GNSS fixes and the integral is correct.
    func testDistanceWithSufficientFixes() {
        var scorer = RunScorer(config: config)
        scorer.beginEvent(onset: 0.0, entrySpeed: 15.0)

        for i in 0..<500 {
            scorer.addSample(time: Double(i) * 0.01, pitch: 0.15, pitchRate: 0, roll: 0)
        }
        // 5 fixes at constant 20 m/s over 4 seconds → distance = 80 m
        scorer.addGNSSFix(time: 0.0, speed: 20.0)
        scorer.addGNSSFix(time: 1.0, speed: 20.0)
        scorer.addGNSSFix(time: 2.0, speed: 20.0)
        scorer.addGNSSFix(time: 3.0, speed: 20.0)
        scorer.addGNSSFix(time: 4.0, speed: 20.0)

        let metrics = scorer.finalise(end: 5.0)
        XCTAssertNotNil(metrics.distance,
                       "Distance must be non-nil with 5 fixes (≥ distanceMinFixes=4)")
        XCTAssertEqual(metrics.distance!, 80.0, accuracy: 0.01,
                      "Trapezoid integral of constant 20 m/s over 4 s should be 80 m — " +
                      "if wrong, the integration formula is broken")
    }

    /// Trapezoidal integration handles varying speed correctly.
    func testDistanceVaryingSpeed() {
        var scorer = RunScorer(config: config)
        scorer.beginEvent(onset: 0.0, entrySpeed: 10.0)

        for i in 0..<500 {
            scorer.addSample(time: Double(i) * 0.01, pitch: 0.15, pitchRate: 0, roll: 0)
        }
        // Linearly increasing speed: 10, 15, 20, 25, 30 m/s at 1-s intervals
        // Trapezoid: (10+15)/2*1 + (15+20)/2*1 + (20+25)/2*1 + (25+30)/2*1
        //          = 12.5 + 17.5 + 22.5 + 27.5 = 80.0 m
        scorer.addGNSSFix(time: 0.0, speed: 10.0)
        scorer.addGNSSFix(time: 1.0, speed: 15.0)
        scorer.addGNSSFix(time: 2.0, speed: 20.0)
        scorer.addGNSSFix(time: 3.0, speed: 25.0)
        scorer.addGNSSFix(time: 4.0, speed: 30.0)

        let metrics = scorer.finalise(end: 5.0)
        XCTAssertEqual(metrics.distance!, 80.0, accuracy: 0.01,
                      "Trapezoid rule on linearly increasing speed should give exact result")
    }

    /// Basic metrics: max angle, roll envelope, duration, entry speed.
    func testBasicMetrics() {
        var scorer = RunScorer(config: config)
        scorer.beginEvent(onset: 1.0, entrySpeed: 18.5)

        // Feed a simple ramp-hold-descend with some roll.
        let peakPitch = 35.0 * .pi / 180
        let dt = 0.01
        for i in 0..<200 {
            let t = 1.0 + Double(i) * dt
            let progress = Double(i) / 200.0
            let pitch = peakPitch * min(progress * 3, 1.0)
            let roll = 0.02 * sin(2.0 * .pi * 1.5 * (t - 1.0))
            scorer.addSample(time: t, pitch: pitch, pitchRate: 0.5, roll: roll)
        }

        let metrics = scorer.finalise(end: 3.0)

        XCTAssertEqual(metrics.onset, 1.0, accuracy: 1e-9)
        XCTAssertEqual(metrics.end, 3.0, accuracy: 1e-9)
        XCTAssertEqual(metrics.duration, 2.0, accuracy: 1e-9)
        XCTAssertEqual(metrics.entrySpeed, 18.5)
        // The ramp is `peakPitch * min(progress*3, 1)`, so it saturates at exactly
        // `peakPitch` for the whole back two-thirds of the event — the max is a known
        // value, not merely "positive". The old assertion was `> 0`, which any single
        // positive sample satisfies: it would have passed had the ratcheting max
        // reported the FIRST sample, or half the peak, or any other wrong number. This
        // is the leaderboard figure, so it is worth pinning exactly.
        XCTAssertEqual(metrics.liveMaxAngle, peakPitch, accuracy: 1e-9,
                       "liveMaxAngle must be the true peak of the series")
        XCTAssertLessThan(metrics.rollMin, 0,
                         "Roll oscillation must produce a negative minimum")
        XCTAssertGreaterThan(metrics.rollMax, 0,
                            "Roll oscillation must produce a positive maximum")
    }

    // MARK: - T5.4 Tests

    /// Session summary computes event count, cumulative hold time, best per metric.
    func testSessionSummary() {
        let event1 = EventMetrics(onset: 0, end: 3, duration: 3,
                                  liveMaxAngle: 30 * .pi / 180,
                                  averageHeldAngle: 28 * .pi / 180,
                                  angleStdDev: 0.5 * .pi / 180,
                                  distance: 50, entrySpeed: 15,
                                  rollMin: -0.05, rollMax: 0.05,
                                  flags: [],
                                  holdWindowResolved: true)
        let event2 = EventMetrics(onset: 10, end: 15, duration: 5,
                                  liveMaxAngle: 45 * .pi / 180,
                                  averageHeldAngle: 42 * .pi / 180,
                                  angleStdDev: 1.0 * .pi / 180,
                                  distance: 90, entrySpeed: 20,
                                  rollMin: -0.08, rollMax: 0.03,
                                  flags: [],
                                  holdWindowResolved: true)
        let event3 = EventMetrics(onset: 25, end: 27, duration: 2,
                                  liveMaxAngle: 20 * .pi / 180,
                                  averageHeldAngle: 18 * .pi / 180,
                                  angleStdDev: 0.3 * .pi / 180,
                                  distance: nil, entrySpeed: 12,
                                  rollMin: -0.02, rollMax: 0.02,
                                  flags: [],
                                  holdWindowResolved: true)

        let summary = SessionSummary(events: [event1, event2, event3])

        XCTAssertEqual(summary.eventCount, 3)
        XCTAssertEqual(summary.cumulativeHoldTime, 10.0, accuracy: 1e-9,
                      "Cumulative hold = sum of durations (3+5+2=10)")
        XCTAssertEqual(summary.bestMaxAngle?.liveMaxAngle, 45 * .pi / 180,
                      "Best max angle should be event2 at 45°")
        XCTAssertEqual(summary.bestDuration?.duration, 5.0,
                      "Best duration should be event2 at 5 s")
        XCTAssertEqual(summary.bestDistance?.distance, 90,
                      "Best distance should be event2 at 90 m")
        XCTAssertEqual(summary.bestConsistency?.angleStdDev, 0.3 * .pi / 180,
                      "Best consistency = lowest stdDev, which is event3")
    }

    /// Empty session summary handles the degenerate case.
    func testEmptySessionSummary() {
        let summary = SessionSummary(events: [])
        XCTAssertEqual(summary.eventCount, 0)
        XCTAssertEqual(summary.cumulativeHoldTime, 0)
        XCTAssertNil(summary.bestMaxAngle)
        XCTAssertNil(summary.bestDuration)
        XCTAssertNil(summary.bestDistance)
        XCTAssertNil(summary.bestConsistency)
    }
}
