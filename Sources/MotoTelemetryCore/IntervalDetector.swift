import Foundation

/// A snapshot of the rider's target ranges AS RECORDED at run finalisation.
/// Stored per-run so historical intervals are never recomputed against changed
/// current preferences — changing targets must never retroactively alter a run.
public struct TargetSnapshot: Codable, Sendable, Equatable {
    /// Angle target in radians.
    public var angleRange: ClosedRange<Double>
    /// Speed target in m/s.
    public var speedRange: ClosedRange<Double>

    public init(angleRange: ClosedRange<Double>, speedRange: ClosedRange<Double>) {
        self.angleRange = angleRange
        self.speedRange = speedRange
    }
}

/// Detects time intervals where a series remains within a target range.
///
/// Implements ui-spec §9.6 interval detection exactly:
///   1. Identify in-range spans with linearly-interpolated boundary crossings.
///   2. Merge intervals separated by gaps ≤ mergeGap.
///   3. Drop fragments shorter than minDuration.
///
/// The order is LOAD-BEARING: merge-before-filter prevents jitter around a band
/// edge from being destroyed as separate sub-threshold fragments when they
/// represent a single real interval. Filter-first would delete three tiny
/// fragments and then have nothing to merge — turning one real interval into zero.
public struct IntervalDetector {
    public let range: ClosedRange<Double>
    public let minDuration: TimeInterval
    public let mergeGap: TimeInterval

    public init(range: ClosedRange<Double>,
                minDuration: TimeInterval = 0.15,
                mergeGap: TimeInterval = 0.10) {
        self.range = range
        self.minDuration = minDuration
        self.mergeGap = mergeGap
    }

    /// A detected interval in monotonic seconds.
    public struct Interval: Sendable, Equatable {
        public var start: TimeInterval
        public var end: TimeInterval

        public var duration: TimeInterval { end - start }

        public init(start: TimeInterval, end: TimeInterval) {
            self.start = start
            self.end = end
        }
    }

    /// Detect all intervals where the series stays within `range`.
    ///
    /// The series must be in monotonic time order. Each element provides
    /// a timestamp and a value to compare against the range.
    public func intervals(over series: [(time: TimeInterval, value: Double)]) -> [Interval] {
        guard series.count >= 2 else {
            // Single sample can't form a measurable interval.
            if let s = series.first, range.contains(s.value) {
                return []
            }
            return []
        }

        // Step 1: detect raw in-range spans with interpolated boundaries.
        var raw = detectRaw(series)

        // Step 2: merge gaps ≤ mergeGap. Must happen BEFORE filtering.
        raw = merge(raw)

        // Step 3: drop fragments shorter than minDuration.
        raw = raw.filter { $0.duration >= minDuration }

        return raw
    }

    /// Total time spent in range after cleanup.
    public func totalInRange(over series: [(time: TimeInterval, value: Double)]) -> TimeInterval {
        intervals(over: series).reduce(0.0) { $0 + $1.duration }
    }

    // MARK: - Private

    /// Linear interpolation between two adjacent samples to find the exact time
    /// the value crosses a boundary.
    private func interpolateCrossing(
        t0: TimeInterval, v0: Double,
        t1: TimeInterval, v1: Double,
        boundary: Double
    ) -> TimeInterval {
        guard v1 != v0 else { return t0 }
        let fraction = (boundary - v0) / (v1 - v0)
        return t0 + fraction * (t1 - t0)
    }

    private func detectRaw(_ series: [(time: TimeInterval, value: Double)]) -> [Interval] {
        var intervals: [Interval] = []
        var inRange = range.contains(series[0].value)
        var spanStart: TimeInterval = inRange ? series[0].time : 0

        for i in 1..<series.count {
            let prev = series[i - 1]
            let curr = series[i]
            let currInRange = range.contains(curr.value)

            if !inRange && currInRange {
                // Entered range — interpolate entry point.
                if range.contains(prev.value) {
                    // Edge case: prev was exactly on boundary but not flagged
                    spanStart = prev.time
                } else {
                    // Crossed lower or upper from outside. Determine which boundary.
                    let boundary = prev.value < range.lowerBound ? range.lowerBound : range.upperBound
                    spanStart = interpolateCrossing(
                        t0: prev.time, v0: prev.value,
                        t1: curr.time, v1: curr.value,
                        boundary: boundary
                    )
                }
                inRange = true
            } else if inRange && !currInRange {
                // Exited range — interpolate exit point.
                let boundary = curr.value < range.lowerBound ? range.lowerBound : range.upperBound
                let exitTime = interpolateCrossing(
                    t0: prev.time, v0: prev.value,
                    t1: curr.time, v1: curr.value,
                    boundary: boundary
                )
                intervals.append(Interval(start: spanStart, end: exitTime))
                inRange = false
            }
        }

        // Close any open span at the last sample.
        if inRange {
            intervals.append(Interval(start: spanStart, end: series.last!.time))
        }

        return intervals
    }

    /// Merge intervals whose gap is ≤ mergeGap into a single interval.
    private func merge(_ intervals: [Interval]) -> [Interval] {
        guard var current = intervals.first else { return [] }
        var merged: [Interval] = []

        for i in 1..<intervals.count {
            let next = intervals[i]
            if next.start - current.end <= mergeGap {
                // Gap is small enough — extend the current interval.
                current = Interval(start: current.start, end: next.end)
            } else {
                merged.append(current)
                current = next
            }
        }
        merged.append(current)
        return merged
    }
}
