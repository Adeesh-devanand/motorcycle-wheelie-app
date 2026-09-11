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

    /// A run whose quality was never recorded is not a clean run — it is an unknown
    /// one. `WheelieRun`'s decoder sets this when the `qualityFlags` key is absent
    /// (runs saved before the field existed), and it must keep those runs out of
    /// personal bests: they cannot be shown to be trustworthy, so they must not take a
    /// record from a run that can.
    func testAMissingQualityRecordIsNotTrustworthy() {
        XCTAssertFalse(QualityFlags.qualityRecordMissing.isTrustworthy)
        XCTAssertTrue(QualityFlags.disqualifying.contains(.qualityRecordMissing))
    }

    /// The new bit must not collide with an existing one, or a recovered run would
    /// silently claim a problem it never measured.
    func testQualityRecordMissingOccupiesItsOwnBit() {
        let existing: QualityFlags = [
            .saturatedInEvent, .highVibration, .aliasingSuspect, .lowRate,
            .gapExceeded, .recovered, .smoothingUnavailable, .estimatorDegraded,
            .lowConfidence
        ]
        XCTAssertTrue(existing.isDisjoint(with: .qualityRecordMissing))
        XCTAssertEqual(QualityFlags.qualityRecordMissing.rawValue, 1 << 9)
    }

    func testFlagsRoundTripThroughCoding() throws {
        let flags: QualityFlags = [.highVibration, .lowRate, .lowConfidence]
        let data = try JSONEncoder().encode(flags)
        XCTAssertEqual(try JSONDecoder().decode(QualityFlags.self, from: data), flags)
    }

    // MARK: - Pipeline integration: aliasing disclosure (R14.1-R14.3, R21.3)

    /// A vibration that aliases INTO the detectable band (above the high-pass
    /// corner) MUST set `highVibration` when run through the full pipeline.
    ///
    /// 130 Hz at 100 Hz sample rate folds to |130-100| = 30 Hz, which is ABOVE
    /// the 20 Hz corner and IS visible to the high-pass RMS indicator.
    ///
    /// This test does NOT assert pitch accuracy - the aliased channel is
    /// corrupted. The flag's job is to DISCLOSE corruption, not fix it.
    func testPipelineFlagsHighVibrationForDetectableAlias() {
        var scenario = SyntheticSource.Scenario()
        scenario.duration = 5.0
        scenario.eventStart = 100.0  // no event - just vibration
        scenario.vibrationFrequency = 130.0  // aliases to 30 Hz (above 20 Hz cutoff)
        scenario.vibrationAmplitude = 15.0   // m/s^2, must be large relative to g to produce
                                             // enough variation in |f| magnitude for the RMS
        scenario.emitGNSS = false

        var source = SyntheticSource(scenario: scenario)
        let config = Config()
        let alignment = MountAlignment.identity()
        // Isolate vibration disclosure from the newly explicit missing-calibration
        // condition. Keep every original flag assertion unchanged.
        let bias = BiasEstimate(bias: .zero, sigma: Vector3(1e-6, 1e-6, 1e-6),
            sampleCount: 200, monotonicTime: 0, bikeProfileID: UUID())
        var pipeline = Pipeline(config: config, alignment: alignment, initialBias: bias,
                                gravityAnchor: Conventions.restSpecificForce)

        let outputs = runPipeline(source: &source, pipeline: &pipeline)
        guard let last = outputs.last else {
            XCTFail("Pipeline produced no output"); return
        }

        // The pipeline MUST flag this run.
        let finalFlags = last.flags
        XCTAssertTrue(finalFlags.contains(.highVibration),
            "Pipeline must set .highVibration when aliased content exceeds the "
            + "RMS threshold - this IS the aliasing disclosure mechanism")

        // Prove the assertion is load-bearing: without the flag the run would
        // incorrectly appear trustworthy.
        let withoutFlag = QualityFlags(rawValue: finalFlags.rawValue & ~QualityFlags.highVibration.rawValue)
        XCTAssertTrue(withoutFlag.isTrustworthy,
            "Without .highVibration the run would incorrectly appear trustworthy")
        XCTAssertFalse(finalFlags.isTrustworthy,
            "With .highVibration the run is correctly disqualified")
    }

    /// 100 Hz vibration at 100 Hz sample rate aliases PERFECTLY to DC - the
    /// hardest case, invisible to any frequency-domain detector.
    ///
    /// Detection of the DC-aliased case requires the once-per-bike audio profile
    /// (sampled at 44.1 kHz, not subject to aliasing). That is a separate path.
    func testDCAliasingIsDocumentedLimitationOfRMSDetector() {
        var scenario = SyntheticSource.Scenario()
        scenario.duration = 5.0
        scenario.eventStart = 100.0  // no event
        scenario.vibrationFrequency = 100.0  // aliases to DC (0 Hz)
        scenario.vibrationAmplitude = 3.0    // same amplitude as above
        scenario.emitGNSS = false

        var source = SyntheticSource(scenario: scenario)
        let config = Config()
        let alignment = MountAlignment.identity()
        // Isolate vibration disclosure from the newly explicit missing-calibration
        // condition. Keep every original flag assertion unchanged.
        let bias = BiasEstimate(bias: .zero, sigma: Vector3(1e-6, 1e-6, 1e-6),
            sampleCount: 200, monotonicTime: 0, bikeProfileID: UUID())
        var pipeline = Pipeline(config: config, alignment: alignment, initialBias: bias,
                                gravityAnchor: Conventions.restSpecificForce)

        let outputs = runPipeline(source: &source, pipeline: &pipeline)
        guard let last = outputs.last else {
            XCTFail("Pipeline produced no output"); return
        }
        let finalFlags = last.flags

        // The high-pass RMS path CANNOT detect this - documented limitation.
        XCTAssertFalse(finalFlags.contains(.highVibration),
            "Documented limitation: DC-aliased vibration is invisible to the "
            + "high-pass RMS detector. Detection needs unaliased audio.")
    }
}
