import Foundation

// `TargetSnapshot` was removed here on 2026-09-04. It stored a per-run copy of the
// rider's angle/speed targets (radians, m/s) so historical intervals could never be
// recomputed against changed current preferences. That requirement is real and still
// honoured — but by the app's own `RunConfigurationSnapshot` (degrees, km/h, plus the
// gauge maximum and calibration ID), which `WheelieRun` actually stores and reads.
// This core type was the earlier duplicate and had no non-test caller: it survived the
// reachability check only because a COMMENT in WheelieRun.swift mentioned it by name,
// which is the exact hole that check was tightened to close.

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
    public let maximumInterpolationGap: TimeInterval

    public init(range: ClosedRange<Double>,
                minDuration: TimeInterval = 0.15,
                mergeGap: TimeInterval = 0.10,
                maximumInterpolationGap: TimeInterval = .infinity) {
        self.range = range
        self.minDuration = minDuration
        self.mergeGap = mergeGap
        self.maximumInterpolationGap = maximumInterpolationGap
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

        // Process continuity islands independently: mergeGap must never bridge
        // missing/invalid data, even when the caller requests a large merge gap.
        var result: [Interval] = []
        var chunk: [(time: TimeInterval, value: Double)] = []
        func flush() {
            result += merge(detectRaw(chunk)).filter { $0.duration >= minDuration }
            chunk.removeAll(keepingCapacity: true)
        }
        for point in series {
            guard point.time.isFinite, point.value.isFinite else { flush(); continue }
            if let previous = chunk.last,
               point.time <= previous.time || point.time - previous.time > maximumInterpolationGap { flush() }
            chunk.append(point)
        }
        flush()
        return result
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
        guard series.count >= 2 else { return [] }
        var result: [Interval] = []
        for i in 1..<series.count {
            let a = series[i - 1], b = series[i]
            let delta = b.value - a.value
            if delta == 0 {
                if range.contains(a.value) { result.append(Interval(start: a.time, end: b.time)) }
                continue
            }
            let u0 = (range.lowerBound - a.value) / delta
            let u1 = (range.upperBound - a.value) / delta
            let enter = max(0, min(u0, u1)), exit = min(1, max(u0, u1))
            if exit > enter {
                result.append(Interval(start: a.time + enter * (b.time - a.time),
                                       end: a.time + exit * (b.time - a.time)))
            }
        }
        return result
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
