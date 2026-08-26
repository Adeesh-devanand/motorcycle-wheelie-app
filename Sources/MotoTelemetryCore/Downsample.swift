import Foundation

// MARK: - Downsample

/// Largest-Triangle-Three-Buckets (LTTB) downsampling for time-series chart
/// rendering. Reduces an arbitrarily long sample series to at most `threshold`
/// points while preserving visual shape — particularly extrema — far better
/// than naive every-Nth decimation.
///
/// The caller retains raw samples for exact maxima and scrubber interpolation;
/// this output is for drawing only (ui-spec §9.4).
///
/// The algorithm is deterministic: identical input always produces identical
/// output, regardless of thread or run order.
public enum Downsample {

    /// A point in a 2D time series — x is time, y is the metric value.
    public struct Point: Equatable, Sendable {
        public let x: Double
        public let y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// Reduce `data` to at most `threshold` points using LTTB.
    ///
    /// - First and last points are always preserved.
    /// - If `data.count <= threshold`, returns the input unchanged.
    /// - Deterministic: same input → same output, every time.
    ///
    /// Reference: Sveinn Steinarsson, "Downsampling Time Series for Visual
    /// Representation" (2013), §4.2.
    public static func lttb(_ data: [Point], threshold: Int) -> [Point] {
        // Nothing to reduce.
        guard data.count > threshold, threshold >= 2 else { return data }

        var result = [Point]()
        result.reserveCapacity(threshold)

        // Always keep the first point.
        result.append(data[0])

        // Number of interior buckets (first and last points are fixed).
        let bucketCount = threshold - 2
        let bucketSize = Double(data.count - 2) / Double(bucketCount)

        var previousSelectedIndex = 0

        for bucketIndex in 0 ..< bucketCount {
            // Current bucket boundaries (1-based offset since first point is already taken).
            let bucketStart = Int(floor(Double(bucketIndex) * bucketSize)) + 1
            let bucketEnd = Int(floor(Double(bucketIndex + 1) * bucketSize)) + 1

            // Next bucket average (or last point for the final bucket).
            let nextBucketStart: Int
            let nextBucketEnd: Int
            if bucketIndex + 1 < bucketCount {
                nextBucketStart = Int(floor(Double(bucketIndex + 1) * bucketSize)) + 1
                nextBucketEnd = Int(floor(Double(bucketIndex + 2) * bucketSize)) + 1
            } else {
                // Last bucket's "next" is just the final point.
                nextBucketStart = data.count - 1
                nextBucketEnd = data.count
            }

            // Average of the next bucket (the "C" in the triangle).
            var avgX = 0.0
            var avgY = 0.0
            let nextCount = nextBucketEnd - nextBucketStart
            for i in nextBucketStart ..< nextBucketEnd {
                avgX += data[i].x
                avgY += data[i].y
            }
            avgX /= Double(nextCount)
            avgY /= Double(nextCount)

            // The previously selected point is "A".
            let ax = data[previousSelectedIndex].x
            let ay = data[previousSelectedIndex].y

            // Find the point in the current bucket ("B") that maximises
            // the triangle area with A and C (the average of next bucket).
            var maxArea = -1.0
            var selectedIndex = bucketStart
            let clampedEnd = min(bucketEnd, data.count - 1)
            for i in bucketStart ..< clampedEnd {
                // Triangle area = 0.5 * |Ax(By-Cy) + Bx(Cy-Ay) + Cx(Ay-By)|
                // We skip the 0.5 since we only compare magnitudes.
                let area = abs(
                    (ax - avgX) * (data[i].y - ay) -
                    (ax - data[i].x) * (avgY - ay)
                )
                if area > maxArea {
                    maxArea = area
                    selectedIndex = i
                }
            }

            result.append(data[selectedIndex])
            previousSelectedIndex = selectedIndex
        }

        // Always keep the last point.
        result.append(data[data.count - 1])

        return result
    }

    /// Default chart rendering threshold per ui-spec §9.4.
    public static let defaultThreshold = 300
}
