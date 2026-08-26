import XCTest
@testable import MotoTelemetryCore

final class QualityMonitorTests: XCTestCase {

    /// Stationary bike with `amplitude` of sinusoidal excitation at `frequency`,
    /// sampled at 100 Hz — so anything above 50 Hz is already aliased on arrival.
    private func vibratingSamples(frequency: Double,
                                  amplitude: Double,
                                  duration: TimeInterval = 3.0,
                                  rate: Double = 100) -> [IMUSample] {
        let n = Int(duration * rate)
        return (0..<n).map { i in
            let t = Double(i) / rate
            let phase = 2 * .pi * frequency * t
            let f = Vector3(amplitude * sin(phase),
                            0,
                            -Conventions.g + amplitude * sin(phase + 1.1))
            return IMUSample(time: t, rotationRate: .zero, specificForce: f)
        }
    }

    private func measure(_ samples: [IMUSample], config: Config = Config())
        -> (rms: Double, stdDev: Double) {
        var indicator = HighFrequencyIndicator(config: config)
        var peakRMS = 0.0, peakStdDev = 0.0
        for sample in samples {
            indicator.process(sample)
            peakRMS = max(peakRMS, indicator.instantaneousRMS)
            peakStdDev = max(peakStdDev, indicator.magnitudeStdDev)
        }
        return (peakRMS, peakStdDev)
    }

    /// THE finding. A 20 Hz high-pass cannot see engine vibration that aliases
    /// below its corner, which is the majority of the cases that matter.
    ///
    /// Sampled at 100 Hz: 83 Hz folds to 17 Hz (under the corner, attenuated) and
    /// 100 Hz folds to DC (invisible). Any future change that reintroduces the
    /// high-pass as the primary vibration detector must fail here.
    func testHighPassIsBlindToAliasedExcitationButStdDevIsNot() {
        let amplitude = 0.2   // m/s^2, small enough to sit inside the gate band

        // 130 Hz folds to 30 Hz, ABOVE the 20 Hz corner: the high-pass sees it.
        let above = measure(vibratingSamples(frequency: 130, amplitude: amplitude))
        // 83 Hz folds to 17 Hz, BELOW the corner: the high-pass is attenuating the
        // very thing it exists to detect.
        let below = measure(vibratingSamples(frequency: 83, amplitude: amplitude))
        // 100 Hz folds to DC: nothing periodic remains at all.
        let toDC = measure(vibratingSamples(frequency: 100, amplitude: amplitude))

        XCTAssertGreaterThan(above.rms, below.rms,
            "the aliased image of 83 Hz lands under the corner, so the high-pass "
            + "must report LESS energy than for 130 Hz despite identical amplitude")
        XCTAssertGreaterThan(above.rms, toDC.rms)

        // The stationary detector is frequency-agnostic: on a bike that is not
        // moving, all spread in |f| is vibration, wherever it aliased from.
        XCTAssertGreaterThan(below.stdDev, 0.05,
            "std dev must catch the 17 Hz aliased image")
        XCTAssertGreaterThan(above.stdDev, 0.05)
        // Within a factor of ~2 across all three, unlike the high-pass.
        XCTAssertLessThan(max(above.stdDev, below.stdDev) /
                          min(above.stdDev, below.stdDev), 2.0,
            "std dev must not depend strongly on which frequency aliased")
    }

    func testDCAliasedVibrationIsTheHardestCase() {
        // A twin at 6000 rpm folds to exactly DC: it becomes a constant offset,
        // which is a phantom TILT rather than a vibration. Nothing in a single
        // stationary window can distinguish it from the bike being on a slope —
        // which is precisely why the once-per-bike audio profile exists.
        let toDC = measure(vibratingSamples(frequency: 100, amplitude: 0.2))
        XCTAssertLessThan(toDC.rms, 0.05,
            "documented limitation: DC-aliased content carries no high-frequency "
            + "signature at all. Detection needs unaliased audio, not the IMU.")
    }

    func testQuietMountReadsNearZeroOnBothMeasures() {
        let quiet = measure(vibratingSamples(frequency: 83, amplitude: 0.0))
        XCTAssertLessThan(quiet.rms, 1e-6)
        XCTAssertLessThan(quiet.stdDev, 1e-6)
    }

    func testStdDevScalesWithAmplitude() {
        let small = measure(vibratingSamples(frequency: 83, amplitude: 0.1))
        let large = measure(vibratingSamples(frequency: 83, amplitude: 0.4))
        XCTAssertGreaterThan(large.stdDev, small.stdDev * 2,
                             "detector must be monotone in vibration amplitude")
    }

    func testWindowedRMSPublishesOnWindowBoundaries() {
        var indicator = HighFrequencyIndicator(cutoff: 20, sampleRate: 100,
                                               windowDuration: 1.0)
        var published = 0
        for sample in vibratingSamples(frequency: 130, amplitude: 0.5, duration: 5.0) {
            if indicator.process(sample) != nil { published += 1 }
        }
        XCTAssertEqual(published, 4, "one publication per closed 1 s window")
        XCTAssertNotNil(indicator.rms)
        XCTAssertGreaterThan(indicator.peakRMS, 0)
    }

    // MARK: - QualityFlags

    func testDisqualifyingFlagsExcludeARunFromPersonalBests() {
        XCTAssertTrue(QualityFlags().isTrustworthy)
        XCTAssertFalse(QualityFlags.saturatedInEvent.isTrustworthy)
        XCTAssertFalse(QualityFlags.aliasingSuspect.isTrustworthy)
        XCTAssertFalse(QualityFlags.lowConfidence.isTrustworthy)
        // `recovered` alone is a provenance note, not a disqualification: the data
        // is intact, one second at the end is missing.
        XCTAssertTrue(QualityFlags.recovered.isTrustworthy)
        XCTAssertTrue(QualityFlags.smoothingUnavailable.isTrustworthy)
    }

    func testFlagsRoundTripThroughCoding() throws {
        let flags: QualityFlags = [.highVibration, .lowRate, .lowConfidence]
        let data = try JSONEncoder().encode(flags)
        XCTAssertEqual(try JSONDecoder().decode(QualityFlags.self, from: data), flags)
    }
}
