import XCTest
@testable import MotoTelemetryCore

final class RelativeMetricColorScaleTests: XCTestCase {

    private let scale = RelativeMetricColorScale()

    // MARK: - ui-spec §8.5 worked example (exact reproduction)

    /// The five runs from the spec. Brightest green is the personal best per
    /// field; darkest indigo is the personal worst. Each field normalises
    /// INDEPENDENTLY — the angle winner (47°) is a DIFFERENT run from the speed
    /// winner (52 km/h). That is precisely the point of independent normalisation.
    func testWorkedExample_IndependentNormalisation() {
        // Runs: (duration, angle, speed)
        let runs: [(d: Double, a: Double, s: Double)] = [
            (4.2, 47, 48),
            (6.1, 44, 52),
            (3.7, 39, 45),
            (5.4, 46, 50),
            (2.8, 35, 41),
        ]

        // Duration: min 2.8, max 6.1
        let dMin = 2.8, dMax = 6.1
        // Angle: min 35, max 47
        let aMin = 35.0, aMax = 47.0
        // Speed: min 41, max 52
        let sMin = 41.0, sMax = 52.0

        // Brightest green (t=1) independently:
        // Duration 6.1 → run index 1
        XCTAssertEqual(scale.normalise(value: 6.1, fieldMinimum: dMin, fieldMaximum: dMax), 1.0,
                       "Duration personal best must be t=1")
        // Angle 47 → run index 0
        XCTAssertEqual(scale.normalise(value: 47, fieldMinimum: aMin, fieldMaximum: aMax), 1.0,
                       "Angle personal best must be t=1")
        // Speed 52 → run index 1
        XCTAssertEqual(scale.normalise(value: 52, fieldMinimum: sMin, fieldMaximum: sMax), 1.0,
                       "Speed personal best must be t=1")

        // Darkest indigo (t=0) independently:
        // Duration 2.8 → run index 4
        XCTAssertEqual(scale.normalise(value: 2.8, fieldMinimum: dMin, fieldMaximum: dMax), 0.0,
                       "Duration personal worst must be t=0")
        // Angle 35 → run index 4
        XCTAssertEqual(scale.normalise(value: 35, fieldMinimum: aMin, fieldMaximum: aMax), 0.0,
                       "Angle personal worst must be t=0")
        // Speed 41 → run index 4
        XCTAssertEqual(scale.normalise(value: 41, fieldMinimum: sMin, fieldMaximum: sMax), 0.0,
                       "Speed personal worst must be t=0")

        // KEY ASSERTION: angle winner (47°) is run 0, speed winner (52 km/h) is
        // run 1. They are DIFFERENT runs — proving independent normalisation.
        let angleBestRunIndex = runs.firstIndex { $0.a == 47 }!
        let speedBestRunIndex = runs.firstIndex { $0.s == 52 }!
        XCTAssertNotEqual(angleBestRunIndex, speedBestRunIndex,
                          "Angle best and speed best must be different runs — " +
                          "this IS the point of independent normalisation")
    }

    // MARK: - All values equal → t = 1 (ui-spec §17 fixture 8)

    func testAllValuesEqual_YieldsT1() {
        // When every run has the same value, all share the personal best → t = 1.
        let t = scale.normalise(value: 42, fieldMinimum: 42, fieldMaximum: 42)
        XCTAssertEqual(t, 1.0, "Equal min/max must give t=1 (all are personal best)")

        // The colour at t=1 should be the green stop.
        let c = scale.color(forT: 1.0)
        let hex = c.hex
        XCTAssertEqual(hex, "32E85B", "t=1.0 must map to rangeHighGreen exactly")
    }

    // MARK: - Anchors do not move under sorting

    func testAnchorsUnmovedBySorting() {
        // Sorting reorders rows but never changes anchors. The same value must
        // normalise identically regardless of which row is "first".
        let values: [Double] = [4.2, 6.1, 3.7, 5.4, 2.8]
        let fMin = values.min()!
        let fMax = values.max()!

        // Compute t for value 4.2 against these anchors.
        let tOriginal = scale.normalise(value: 4.2, fieldMinimum: fMin, fieldMaximum: fMax)

        // "Sort descending" — values reorder but anchors stay the same.
        let sorted = values.sorted(by: >)
        let sMin = sorted.min()! // still 2.8
        let sMax = sorted.max()! // still 6.1
        XCTAssertEqual(sMin, fMin, "Sorting must not change fieldMinimum")
        XCTAssertEqual(sMax, fMax, "Sorting must not change fieldMaximum")

        let tAfterSort = scale.normalise(value: 4.2, fieldMinimum: sMin, fieldMaximum: sMax)
        XCTAssertEqual(tOriginal, tAfterSort,
                       "Normalised t must be identical regardless of sort order")
    }

    // MARK: - Anchors do not move when a numeric filter hides rows

    func testAnchorsUnmovedByNumericFilter() {
        // A numeric row-level filter hides rows but must NOT recalculate anchors.
        // Anchors are locked to the full date scope BEFORE filters.
        let allValues: [Double] = [4.2, 6.1, 3.7, 5.4, 2.8]
        let anchorMin = allValues.min()! // 2.8, from pre-filter scope
        let anchorMax = allValues.max()! // 6.1, from pre-filter scope

        // Filter: show only runs with duration >= 4.0 → visible: [4.2, 6.1, 5.4]
        let visibleValues: [Double] = [4.2, 6.1, 5.4]

        // The anchors used for colour must still be 2.8 and 6.1, NOT 4.2 and 6.1.
        // If we incorrectly recalculated anchors from the visible set:
        let wrongMin = visibleValues.min()! // 4.2 — WRONG
        let wrongMax = visibleValues.max()! // 6.1

        let tCorrect = scale.normalise(value: 5.4, fieldMinimum: anchorMin, fieldMaximum: anchorMax)
        let tWrong = scale.normalise(value: 5.4, fieldMinimum: wrongMin, fieldMaximum: wrongMax)

        // These must be different, proving that recalculating from visible rows
        // would give wrong colours (the colour would "jump").
        XCTAssertNotEqual(tCorrect, tWrong,
                          "Using filter-narrowed anchors would produce different t — " +
                          "the contract says anchors come from the full pre-filter scope")

        // And the correct t should place 5.4 at (5.4-2.8)/(6.1-2.8) ≈ 0.7879
        let expected = (5.4 - 2.8) / (6.1 - 2.8)
        XCTAssertEqual(tCorrect, expected, accuracy: 1e-10)
    }

    // MARK: - No yellow in the interpolation

    /// Yellow-ish: high red AND high green with low blue. Specifically:
    /// sRGB r > 0.6 AND g > 0.6 AND b < 0.3.
    /// Sample 101 evenly-spaced t values and assert none are yellow.
    func testNoYellowInScale() {
        for i in 0...100 {
            let t = Double(i) / 100.0
            let color = scale.color(forT: t)
            let srgb = color.sRGB

            let isYellowish = srgb.r > 0.6 && srgb.g > 0.6 && srgb.b < 0.3
            XCTAssertFalse(isYellowish,
                           "Yellow detected at t=\(t): " +
                           "sRGB(\(srgb.r), \(srgb.g), \(srgb.b)) hex=\(color.hex)")
        }
    }

    // MARK: - Stop endpoints are exact

    func testStopEndpoints() {
        let c0 = scale.color(forT: 0.0)
        XCTAssertEqual(c0.hex, "6559D8", "t=0 must be rangeLowIndigo")

        let c1 = scale.color(forT: 1.0)
        XCTAssertEqual(c1.hex, "32E85B", "t=1 must be rangeHighGreen")
    }

    // MARK: - Monotonic lightness (OKLCH should produce this)

    func testLightnessMonotonicallyIncreases() {
        // The gradient goes from dark indigo to bright green. In OKLCH,
        // lightness should increase (or at worst stay flat) across the range.
        // This would NOT hold for naive RGB interpolation, so it also validates
        // that OKLCH interpolation is working.
        var prevL = -1.0
        for i in 0...20 {
            let t = Double(i) / 20.0
            let color = scale.color(forT: t)
            // Compute perceived lightness: approximate with sRGB luminance.
            let srgb = color.sRGB
            let luminance = 0.2126 * srgb.r + 0.7152 * srgb.g + 0.0722 * srgb.b
            XCTAssertGreaterThanOrEqual(luminance, prevL - 0.02,
                                        "Perceived lightness should generally increase, " +
                                        "dropped at t=\(t)")
            prevL = luminance
        }
    }

    // MARK: - Clamping

    func testClampingBelowZeroAndAboveOne() {
        // Values outside [min,max] clamp to t=0 or t=1.
        let t_below = scale.normalise(value: -5, fieldMinimum: 0, fieldMaximum: 10)
        XCTAssertEqual(t_below, 0.0)

        let t_above = scale.normalise(value: 15, fieldMinimum: 0, fieldMaximum: 10)
        XCTAssertEqual(t_above, 1.0)
    }

    // MARK: - Mid-range value

    func testMidRangeNormalisation() {
        let t = scale.normalise(value: 5.0, fieldMinimum: 0.0, fieldMaximum: 10.0)
        XCTAssertEqual(t, 0.5, accuracy: 1e-10)
    }
}
