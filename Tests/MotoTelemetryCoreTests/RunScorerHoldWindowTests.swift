import XCTest
@testable import MotoTelemetryCore

/// Review addition to the delegated M5 work.
///
/// `angleStdDev` means two different things depending on whether the hold window was
/// actually located: over a real plateau it is the rider's steadiness, which is the
/// metric's entire purpose, while over an arbitrary middle slice of a ramp-shaped
/// event it is mostly the ramp's slope. The original implementation substituted a
/// middle-60% heuristic silently, which would let an unmeasurable consistency number
/// compete for a personal best against properly measured ones.
final class RunScorerHoldWindowTests: XCTestCase {

    private func scorer() -> RunScorer { RunScorer(config: Config()) }

    /// A well-formed event: rise, plateau, descent. The window is locatable, so the
    /// metric means what it claims.
    func testResolvedHoldWindowOnAWellFormedEvent() {
        var s = scorer()
        s.beginEvent(onset: 0, entrySpeed: 12)

        let rate = 30.0 * .pi / 180
        // Rise 0.0-1.0 s, plateau 1.0-4.0 s, descent 4.0-5.0 s.
        for i in 0...500 {
            let t = Double(i) / 100
            let pitch: Double
            let pitchRate: Double
            if t < 1.0 {
                pitch = 30 * .pi / 180 * t
                pitchRate = rate
            } else if t < 4.0 {
                pitch = 30 * .pi / 180
                pitchRate = 0
            } else {
                pitch = 30 * .pi / 180 * (5.0 - t)
                pitchRate = -rate
            }
            s.addSample(time: t, pitch: pitch, pitchRate: pitchRate, roll: 0)
        }

        let m = s.finalise(end: 5.0)
        XCTAssertTrue(m.holdWindowResolved,
                      "rise/plateau/descent must yield a located hold window")
        XCTAssertLessThan(m.angleStdDev * 180 / .pi, 0.1,
                          "a flat plateau is maximally steady")
    }

    /// A ramp-shaped event with no plateau: the window cannot be located, so the
    /// heuristic fires and MUST declare itself.
    func testHeuristicWindowIsReportedNotHidden() {
        var s = scorer()
        s.beginEvent(onset: 0, entrySpeed: 12)

        // Monotonic rise the whole way, no plateau, no descent crossing.
        let rate = 20.0 * .pi / 180
        for i in 0...200 {
            let t = Double(i) / 100
            s.addSample(time: t, pitch: rate * t, pitchRate: rate, roll: 0)
        }

        let m = s.finalise(end: 2.0)
        XCTAssertFalse(m.holdWindowResolved,
            "no rate crossings means the window is a heuristic slice; reporting it as "
            + "resolved would let a ramp's slope masquerade as a consistency score")
        // The number still exists — it is simply labelled.
        XCTAssertGreaterThan(m.angleStdDev, 0)
    }

    func testMetricsRoundTripIncludingTheNewFlag() throws {
        var s = scorer()
        s.beginEvent(onset: 0, entrySpeed: 10)
        for i in 0...100 {
            let t = Double(i) / 100
            s.addSample(time: t, pitch: 0.5, pitchRate: 0, roll: 0.1)
        }
        let m = s.finalise(end: 1.0)
        let data = try JSONEncoder().encode(m)
        let decoded = try JSONDecoder().decode(EventMetrics.self, from: data)
        XCTAssertEqual(m, decoded)
    }
}
