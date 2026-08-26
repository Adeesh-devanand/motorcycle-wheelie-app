import XCTest
@testable import MotoTelemetryCore

final class DownsampleTests: XCTestCase {

    // MARK: - 10,000-sample series reduces to ≤ 300 points (ui-spec §17 fixture 9)

    func testLongSeriesReducesToThreshold() {
        let data = Self.makeSyntheticSeries(count: 10_000)

        let result = Downsample.lttb(data, threshold: 300)

        XCTAssertLessThanOrEqual(result.count, 300,
                                 "LTTB must reduce 10,000 samples to at most 300")
        XCTAssertEqual(result.count, 300,
                       "With 10,000 input and threshold 300, output should be exactly 300")
    }

    // MARK: - First and last points preserved

    func testFirstAndLastPreserved() {
        let data = Self.makeSyntheticSeries(count: 10_000)

        let result = Downsample.lttb(data, threshold: 300)

        XCTAssertEqual(result.first, data.first,
                       "First point must always be preserved")
        XCTAssertEqual(result.last, data.last,
                       "Last point must always be preserved")
    }

    // MARK: - Deterministic across two runs

    func testDeterministic() {
        let data = Self.makeSyntheticSeries(count: 10_000)

        let run1 = Downsample.lttb(data, threshold: 300)
        let run2 = Downsample.lttb(data, threshold: 300)

        XCTAssertEqual(run1, run2,
                       "LTTB must be deterministic — identical input yields identical output")
    }

    // MARK: - Preserves visible extrema better than naive every-Nth

    func testPreservesExtremaBetterThanNaive() {
        let data = Self.makeSyntheticSeries(count: 10_000)
        let trueMax = data.map(\.y).max()!

        let lttbResult = Downsample.lttb(data, threshold: 300)
        let lttbMax = lttbResult.map(\.y).max()!

        // Naive every-Nth decimation.
        let naiveResult = naiveDecimate(data, threshold: 300)
        let naiveMax = naiveResult.map(\.y).max()!

        // LTTB's retained max should be closer to the true max than naive's.
        let lttbError = abs(trueMax - lttbMax)
        let naiveError = abs(trueMax - naiveMax)

        XCTAssertLessThanOrEqual(lttbError, naiveError,
                                 "LTTB (error \(lttbError)) must preserve extrema at least as " +
                                 "well as naive decimation (error \(naiveError)). " +
                                 "True max: \(trueMax), LTTB max: \(lttbMax), Naive max: \(naiveMax)")
    }

    // MARK: - Input smaller than threshold returns unchanged

    func testSmallInputPassesThrough() {
        let data = (0..<50).map { Downsample.Point(x: Double($0), y: Double($0) * 2) }

        let result = Downsample.lttb(data, threshold: 300)

        XCTAssertEqual(result, data, "Input smaller than threshold must pass through unchanged")
    }

    // MARK: - Input equal to threshold returns unchanged

    func testExactThresholdPassesThrough() {
        let data = (0..<300).map { Downsample.Point(x: Double($0), y: sin(Double($0) * 0.1)) }

        let result = Downsample.lttb(data, threshold: 300)

        XCTAssertEqual(result, data, "Input exactly at threshold must pass through unchanged")
    }

    // MARK: - Edge cases

    func testEmptyInput() {
        let result = Downsample.lttb([], threshold: 300)
        XCTAssertTrue(result.isEmpty)
    }

    func testSinglePoint() {
        let data = [Downsample.Point(x: 0, y: 1)]
        let result = Downsample.lttb(data, threshold: 300)
        XCTAssertEqual(result, data)
    }

    func testTwoPoints() {
        let data = [Downsample.Point(x: 0, y: 1), Downsample.Point(x: 1, y: 5)]
        let result = Downsample.lttb(data, threshold: 2)
        XCTAssertEqual(result, data)
    }

    func testThresholdOfTwo() {
        // With threshold 2, only first and last should remain.
        let data = (0..<100).map { Downsample.Point(x: Double($0), y: Double($0)) }
        let result = Downsample.lttb(data, threshold: 2)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], data[0])
        XCTAssertEqual(result[1], data[99])
    }

    // MARK: - Helpers

    /// Builds a synthetic series with a sine wave plus a sharp spike, ensuring
    /// there is a clear maximum that naive decimation can easily miss.
    private static func makeSyntheticSeries(count: Int) -> [Downsample.Point] {
        (0..<count).map { i in
            let x = Double(i) * 0.01 // 100 seconds total
            var y = sin(x * 2.0 * .pi / 10.0) * 50 + 50 // sine 0..100

            // Sharp spike at index 3737 — a visually important extremum that
            // naive every-Nth is likely to skip (3737 % 33 ≠ 0).
            if i == 3737 {
                y = 150.0
            }
            return Downsample.Point(x: x, y: y)
        }
    }

    /// Naive every-Nth decimation as a comparison baseline.
    private func naiveDecimate(_ data: [Downsample.Point], threshold: Int) -> [Downsample.Point] {
        guard data.count > threshold, threshold >= 2 else { return data }
        let step = Double(data.count - 1) / Double(threshold - 1)
        return (0..<threshold).map { i in
            let index = Int(round(Double(i) * step))
            return data[min(index, data.count - 1)]
        }
    }
}
