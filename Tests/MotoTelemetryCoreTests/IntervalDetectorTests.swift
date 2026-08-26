import XCTest
@testable import MotoTelemetryCore

final class IntervalDetectorTests: XCTestCase {

    // MARK: - ui-spec §9.6 worked example

    /// Reproduces ui-spec §9.6's exact worked example:
    ///   Angle intervals: 1.2–2.1, 2.3–3.1, 3.2–5.4
    ///   Speed intervals: 0.4–1.0, 1.6–2.7, 3.1–4.8
    ///
    /// These are the expected OUTPUT intervals. We construct a time-series that
    /// enters and exits the range at these times and verify the detector recovers them.
    func testUISpecWorkedExample_AngleIntervals() {
        // Target: 20–40 degrees (in radians for the detector — but the detector
        // is range-agnostic so we can use arbitrary units and just test timing).
        let detector = IntervalDetector(range: 10.0...30.0, minDuration: 0.15, mergeGap: 0.10)

        // Build a series that is in-range at times: 1.2–2.1, 2.3–3.1, 3.2–5.4
        // with samples at 0.1s intervals. Out-of-range = 5.0, in-range = 20.0
        let series = buildSeries(
            inRangeSpans: [(1.2, 2.1), (2.3, 3.1), (3.2, 5.4)],
            totalDuration: 6.0,
            dt: 0.01,
            rangeValue: 20.0,
            outsideValue: 5.0
        )

        let intervals = detector.intervals(over: series)

        // Gaps: 2.1→2.3 = 0.2s (> mergeGap), 3.1→3.2 = 0.1s (== mergeGap, so merged)
        // After merge: [1.2–2.1], [2.3–5.4]
        // After filter (all > 0.15s): [1.2–2.1], [2.3–5.4]
        XCTAssertEqual(intervals.count, 2, "Gap 3.1→3.2 = 0.1s should be merged")
        XCTAssertEqual(intervals[0].start, 1.2, accuracy: 0.02)
        XCTAssertEqual(intervals[0].end, 2.1, accuracy: 0.02)
        XCTAssertEqual(intervals[1].start, 2.3, accuracy: 0.02)
        XCTAssertEqual(intervals[1].end, 5.4, accuracy: 0.02)
    }

    func testUISpecWorkedExample_SpeedIntervals() {
        let detector = IntervalDetector(range: 10.0...30.0, minDuration: 0.15, mergeGap: 0.10)

        // Speed intervals: 0.4–1.0, 1.6–2.7, 3.1–4.8
        let series = buildSeries(
            inRangeSpans: [(0.4, 1.0), (1.6, 2.7), (3.1, 4.8)],
            totalDuration: 5.5,
            dt: 0.01,
            rangeValue: 20.0,
            outsideValue: 5.0
        )

        let intervals = detector.intervals(over: series)

        // Gaps: 1.0→1.6 = 0.6s (> merge), 2.7→3.1 = 0.4s (> merge)
        // All durations > 0.15s: kept.
        XCTAssertEqual(intervals.count, 3)
        XCTAssertEqual(intervals[0].start, 0.4, accuracy: 0.02)
        XCTAssertEqual(intervals[0].end, 1.0, accuracy: 0.02)
        XCTAssertEqual(intervals[1].start, 1.6, accuracy: 0.02)
        XCTAssertEqual(intervals[1].end, 2.7, accuracy: 0.02)
        XCTAssertEqual(intervals[2].start, 3.1, accuracy: 0.02)
        XCTAssertEqual(intervals[2].end, 4.8, accuracy: 0.02)
    }

    // MARK: - ui-spec §17 fixture 5: partial overlap

    /// Fixture 5: three angle and three speed intervals with partial overlap.
    /// Verifies each metric produces its own independent intervals.
    func testFixture5_PartialOverlap() {
        // Angle range: angle enters at [0.5–1.5, 2.0–3.0, 4.0–5.0]
        // Speed range: speed enters at [0.8–1.8, 2.5–3.5, 4.5–5.5]
        // Partial overlap between the two sets (different metrics, same timeline).
        let angleDetector = IntervalDetector(range: 10.0...30.0, minDuration: 0.15, mergeGap: 0.10)
        let speedDetector = IntervalDetector(range: 5.0...15.0, minDuration: 0.15, mergeGap: 0.10)

        let angleSeries = buildSeries(
            inRangeSpans: [(0.5, 1.5), (2.0, 3.0), (4.0, 5.0)],
            totalDuration: 6.0, dt: 0.01, rangeValue: 20.0, outsideValue: 5.0
        )
        let speedSeries = buildSeries(
            inRangeSpans: [(0.8, 1.8), (2.5, 3.5), (4.5, 5.5)],
            totalDuration: 6.0, dt: 0.01, rangeValue: 10.0, outsideValue: 20.0
        )

        let angleIntervals = angleDetector.intervals(over: angleSeries)
        let speedIntervals = speedDetector.intervals(over: speedSeries)

        XCTAssertEqual(angleIntervals.count, 3)
        XCTAssertEqual(speedIntervals.count, 3)

        // Verify partial overlap: angle[0] overlaps with speed[0] from 0.8–1.5.
        XCTAssertTrue(angleIntervals[0].end > speedIntervals[0].start)
        XCTAssertTrue(angleIntervals[0].start < speedIntervals[0].start)
    }

    // MARK: - ui-spec §17 fixture 6: no intervals

    /// Fixture 6: valid run that never enters either configured range.
    func testFixture6_NeverEntersRange() {
        let detector = IntervalDetector(range: 10.0...30.0, minDuration: 0.15, mergeGap: 0.10)

        // All values below the range.
        let series: [(time: TimeInterval, value: Double)] = (0..<500).map { i in
            (time: Double(i) * 0.01, value: 5.0)
        }

        let intervals = detector.intervals(over: series)
        XCTAssertEqual(intervals.count, 0, "Run that never enters range should produce no intervals")
        XCTAssertEqual(detector.totalInRange(over: series), 0.0, accuracy: 1e-9)
    }

    // MARK: - ui-spec §17 fixture 7: complete overlap

    /// Fixture 7: angle and speed intervals cover the same time span.
    func testFixture7_CompleteOverlap() {
        let angleDetector = IntervalDetector(range: 10.0...30.0, minDuration: 0.15, mergeGap: 0.10)
        let speedDetector = IntervalDetector(range: 5.0...15.0, minDuration: 0.15, mergeGap: 0.10)

        // Both metrics in-range from 1.0 to 4.0.
        let angleSeries = buildSeries(
            inRangeSpans: [(1.0, 4.0)],
            totalDuration: 5.0, dt: 0.01, rangeValue: 20.0, outsideValue: 5.0
        )
        let speedSeries = buildSeries(
            inRangeSpans: [(1.0, 4.0)],
            totalDuration: 5.0, dt: 0.01, rangeValue: 10.0, outsideValue: 20.0
        )

        let angleIntervals = angleDetector.intervals(over: angleSeries)
        let speedIntervals = speedDetector.intervals(over: speedSeries)

        XCTAssertEqual(angleIntervals.count, 1)
        XCTAssertEqual(speedIntervals.count, 1)
        XCTAssertEqual(angleIntervals[0].start, speedIntervals[0].start, accuracy: 0.02)
        XCTAssertEqual(angleIntervals[0].end, speedIntervals[0].end, accuracy: 0.02)
    }

    // MARK: - Merge-before-filter proof

    /// Three sub-0.15s fragments separated by sub-0.10s gaps MUST yield ONE interval.
    ///
    /// This is the proof that merge-before-filter is correct:
    /// - Fragment A: 0.12s duration
    /// - Gap: 0.08s
    /// - Fragment B: 0.10s duration
    /// - Gap: 0.06s
    /// - Fragment C: 0.13s duration
    ///
    /// Correct order (merge then filter):
    ///   Merge: all gaps ≤ 0.10s → single interval of 0.12+0.08+0.10+0.06+0.13 = 0.49s
    ///   Filter: 0.49s > 0.15s → KEPT. Result: 1 interval.
    ///
    /// Wrong order (filter then merge):
    ///   Filter: 0.12 < 0.15 → deleted; 0.10 < 0.15 → deleted; 0.13 < 0.15 → deleted
    ///   Merge: nothing left → 0 intervals.
    ///   // filter-first yields ZERO intervals — this comment documents the failure mode.
    func testMergeBeforeFilter_JitterCase() {
        let detector = IntervalDetector(range: 10.0...30.0, minDuration: 0.15, mergeGap: 0.10)

        // Build: in-range for [1.0–1.12], out [1.12–1.20], in [1.20–1.30], out [1.30–1.36], in [1.36–1.49]
        // Each fragment < 0.15s; each gap < 0.10s.
        let series = buildJitterSeries()

        let intervals = detector.intervals(over: series)

        // Merge-before-filter: single interval spanning 1.0–1.49 = 0.49s > 0.15s
        XCTAssertEqual(intervals.count, 1, "Three sub-threshold fragments with sub-mergeGap separations must merge into one interval")
        XCTAssertEqual(intervals[0].start, 1.0, accuracy: 0.02)
        XCTAssertEqual(intervals[0].end, 1.49, accuracy: 0.02)
        XCTAssertGreaterThanOrEqual(intervals[0].duration, 0.15)
    }

    /// Prove filter-first would fail: apply filter before merge and assert it gives zero.
    func testFilterFirstWouldFail_Proof() {
        let range: ClosedRange<Double> = 10.0...30.0
        let minDuration: TimeInterval = 0.15
        let mergeGap: TimeInterval = 0.10

        let series = buildJitterSeries()

        // Manually replicate detection + filter-first + merge (the WRONG order).
        let detector = IntervalDetector(range: range, minDuration: minDuration, mergeGap: mergeGap)
        // Get raw intervals (before any cleanup) by using a detector with no cleanup.
        let noCleanup = IntervalDetector(range: range, minDuration: 0.0, mergeGap: 0.0)
        let rawIntervals = noCleanup.intervals(over: series)

        // Filter first: drop anything < 0.15s
        let afterFilter = rawIntervals.filter { $0.duration >= minDuration }

        // Then merge
        var merged: [IntervalDetector.Interval] = []
        for interval in afterFilter {
            if let last = merged.last, interval.start - last.end <= mergeGap {
                merged[merged.count - 1] = IntervalDetector.Interval(start: last.start, end: interval.end)
            } else {
                merged.append(interval)
            }
        }

        XCTAssertEqual(merged.count, 0, "Filter-first MUST yield zero — this proves merge-before-filter is necessary")
    }

    // MARK: - Preserves all intervals (never reduces to longest)

    func testPreservesAllIntervals() {
        let detector = IntervalDetector(range: 10.0...30.0, minDuration: 0.15, mergeGap: 0.10)

        // Three well-separated intervals of different durations.
        let series = buildSeries(
            inRangeSpans: [(0.5, 1.0), (2.0, 4.0), (5.0, 5.5)],
            totalDuration: 6.0, dt: 0.01, rangeValue: 20.0, outsideValue: 5.0
        )

        let intervals = detector.intervals(over: series)
        XCTAssertEqual(intervals.count, 3, "All intervals must be preserved, not reduced to longest")
    }

    // MARK: - Total in-range duration

    func testTotalInRange() {
        let detector = IntervalDetector(range: 10.0...30.0, minDuration: 0.15, mergeGap: 0.10)

        let series = buildSeries(
            inRangeSpans: [(1.0, 2.0), (3.0, 4.5)],
            totalDuration: 5.0, dt: 0.01, rangeValue: 20.0, outsideValue: 5.0
        )

        let total = detector.totalInRange(over: series)
        XCTAssertEqual(total, 2.5, accuracy: 0.05)
    }

    // MARK: - TargetSnapshot

    func testTargetSnapshotImmutability() {
        let snapshot = TargetSnapshot(
            angleRange: (20.0 * .pi / 180)...(40.0 * .pi / 180),
            speedRange: 5.0...15.0
        )
        // Verify it holds the original values regardless of what current preferences say.
        XCTAssertEqual(snapshot.angleRange.lowerBound, 20.0 * .pi / 180, accuracy: 1e-10)
        XCTAssertEqual(snapshot.speedRange.upperBound, 15.0)
    }

    func testTargetSnapshotCodable() throws {
        let original = TargetSnapshot(
            angleRange: 0.35...0.70,
            speedRange: 8.0...14.0
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TargetSnapshot.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    // MARK: - Interpolated boundaries

    func testInterpolatedBoundaries() {
        // Verify that boundary crossings are interpolated, not quantized to sample times.
        let detector = IntervalDetector(range: 10.0...30.0, minDuration: 0.0, mergeGap: 0.0)

        // Value goes from 5 at t=0 to 20 at t=1 (crosses 10 at t=0.5),
        // then from 20 at t=1 to 35 at t=2 (crosses 30 at t=1.667).
        let series: [(time: TimeInterval, value: Double)] = [
            (time: 0.0, value: 5.0),
            (time: 1.0, value: 20.0),
            (time: 2.0, value: 35.0)
        ]

        let intervals = detector.intervals(over: series)
        XCTAssertEqual(intervals.count, 1)
        // Crosses lower=10 between t=0 (v=5) and t=1 (v=20): t = 0 + (10-5)/(20-5) * 1 = 0.333
        XCTAssertEqual(intervals[0].start, 1.0 / 3.0, accuracy: 0.001)
        // Crosses upper=30 between t=1 (v=20) and t=2 (v=35): t = 1 + (30-20)/(35-20) * 1 = 1.667
        XCTAssertEqual(intervals[0].end, 5.0 / 3.0, accuracy: 0.001)
    }

    // MARK: - Helpers

    /// Build a time series that is in-range during the specified spans and out-of-range otherwise.
    private func buildSeries(
        inRangeSpans: [(Double, Double)],
        totalDuration: Double,
        dt: Double,
        rangeValue: Double,
        outsideValue: Double
    ) -> [(time: TimeInterval, value: Double)] {
        let sampleCount = Int(totalDuration / dt) + 1
        return (0..<sampleCount).map { i in
            let t = Double(i) * dt
            let inRange = inRangeSpans.contains { t >= $0.0 && t <= $0.1 }
            return (time: t, value: inRange ? rangeValue : outsideValue)
        }
    }

    /// Build the jitter test case: three sub-0.15s fragments with sub-0.10s gaps.
    /// Fragment layout (all at 1ms sample rate):
    ///   IN [1.000–1.120] (0.12s), OUT [1.120–1.200] (0.08s),
    ///   IN [1.200–1.300] (0.10s), OUT [1.300–1.360] (0.06s),
    ///   IN [1.360–1.490] (0.13s)
    private func buildJitterSeries() -> [(time: TimeInterval, value: Double)] {
        let dt = 0.001
        let totalDuration = 2.0
        let sampleCount = Int(totalDuration / dt) + 1
        let inRangeSpans: [(Double, Double)] = [
            (1.000, 1.120),
            (1.200, 1.300),
            (1.360, 1.490)
        ]
        return (0..<sampleCount).map { i in
            let t = Double(i) * dt
            let inRange = inRangeSpans.contains { t >= $0.0 && t <= $0.1 }
            return (time: t, value: inRange ? 20.0 : 5.0)
        }
    }
}
