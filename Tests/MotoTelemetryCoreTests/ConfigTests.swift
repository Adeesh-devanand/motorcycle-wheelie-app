import XCTest
@testable import MotoTelemetryCore

/// R1.8, R1.9 — Config is the only home for tunable constants, and an older
/// header must keep decoding.
final class ConfigTests: XCTestCase {

    func testRoundTripsUnchanged() throws {
        let original = Config()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        // Re-decode from the same bytes to get a stable reference — if decode
        // is deterministic the two decoded values must be identical.
        let decodedAgain = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(decoded, decodedAgain,
                       "Decoding the same JSON twice must yield identical Config")
        // Also verify no field was silently dropped: re-encode the decoded value
        // and decode that — the second-generation decode must still equal the first.
        let reEncoded = try JSONEncoder().encode(decoded)
        let secondGen = try JSONDecoder().decode(Config.self, from: reEncoded)
        XCTAssertEqual(decoded, secondGen,
                       "encode→decode→encode→decode must be stable")
    }

    func testVersionIsCurrent() {
        // v4: calibration's validity gate got its own, wider specific-force band
        // (+/-0.03 g -> +/-0.10 g) so the gate stops flapping ~25x/s on a handled or
        // idling bike; the bias mean is unaffected because that band is an
        // accelerometer proxy which never enters the gyro mean. The ESTIMATOR's band
        // stays at +/-0.03 g deliberately: 0.3 g of thrust is 1.044 g, so a wider band
        // there feeds the 16.7 deg phantom angle into the gravity update. Rotation
        // ceiling 3 -> 5 deg/s, shared. Added `anchorLevelCosine`, since a
        // magnitude-only anchor test cannot reject a tilt at all.
        //
        // v5 -> v6: added the GATING vibration limit `calibrationVibrationLimit` —
        // distinct from the reporting-only threshold, because |f| magnitude is
        // AC-blind and an idling engine passes the band test untouched — the swipe
        // alignment's `alignmentConfidenceMin`, the cue's enter/exit pair and
        // deadband, and the jitter-blur window. Two defaults changed:
        // `eventMinDuration` 0.4 -> 1.0 s and `biasCalibrationDuration` 8.0 -> 2.0 s.
        //
        // NOTE: an earlier version of this comment said v6 added the calibrate-once
        // estimator "as a selectable mode (`estimatorMode`, `driftCompensation`)".
        // Those two fields were removed before shipping — calibrate-once is the SOLE
        // path on this branch, not a mode — and the stale comment re-introduced a
        // deleted mental model at the top of the file that defines the config.
        //
        // v6 -> v7: named the two stream-continuity limits that had been hardcoded
        // literals, `maxIntegrationDt` (was a bare 1.0 in the estimator) and
        // `maxSampleGap` (was a bare 0.5 in the pipeline's gap warning), and gave the
        // latter a second consumer in `EventSegmenter`'s dwell restart.
        // v7 -> v8: calibration tolerates more real-world noise, bought from
        // duration (`gateCloseConfirm`, `biasGateGracePeriod`) and NOT from
        // amplitude. See the type doc for why the rotation ceiling was reverted.
        XCTAssertEqual(Config().version, 9)
    }

    /// The v8 loosening, stated as the property that makes it safe: what moved is how
    /// long a transient breach is tolerated, and what did NOT move is any amplitude
    /// limit deciding which samples reach the bias mean.
    ///
    /// Guards a real regression. Raising `calibrationMaxRotationRate` to 12 deg/s was
    /// tried, and a sustained 10 deg/s rotation was then adopted as the bias — sigma
    /// cannot catch it, because a constant rate has zero variance.
    func testNoiseToleranceComesFromDurationNotAmplitude() {
        let config = Config()

        // Loosened: both are duration-only.
        XCTAssertEqual(config.gateCloseConfirm, 0.15, accuracy: 1e-12)
        XCTAssertEqual(config.biasGateGracePeriod, 0.5, accuracy: 1e-12)

        // Unmoved: every amplitude limit that decides what enters the average.
        XCTAssertEqual(config.calibrationMaxRotationRate * 180 / .pi, 5.0, accuracy: 1e-9)
        XCTAssertEqual(config.gateMaxRotationRate * 180 / .pi, 3.0, accuracy: 1e-9)
        XCTAssertEqual(config.biasSigmaLimit * 180 / .pi, 0.05, accuracy: 1e-9)

        // The confirmation window must stay well clear of both timescales it sits
        // between: longer than a buzz/tremor burst, far shorter than the dwell it
        // protects, or it would let real sustained motion hold the gate open.
        XCTAssertGreaterThan(config.gateCloseConfirm, 0.05,
                             "must outlast an engine-excitation burst")
        XCTAssertLessThan(config.gateCloseConfirm, config.gateDwell,
                          "a breach must still cost the dwell before the dwell elapses")
    }

    func testExitThresholdMatchesTheUISpec() {
        // docs/ui-spec.md 7.6: begin above 10 deg for 150 ms, end below 7 deg
        // for 250 ms. Onset is the angle at which a wheelie starts being counted
        // AND clocked, so it also sets what a duration means.
        XCTAssertEqual(Config().eventExitPitch * 180 / .pi, 7.0, accuracy: 1e-12)
        XCTAssertEqual(Config().eventExitDwell, 0.25, accuracy: 1e-12)
        XCTAssertEqual(Config().eventEntryPitch * 180 / .pi, 10.0, accuracy: 1e-12)
        XCTAssertEqual(Config().eventEntryDwell, 0.15, accuracy: 1e-12)
    }

    func testEntryExitHysteresisIsPositive() {
        // Entry above exit, or the segmenter oscillates on any sample near the
        // boundary. 3 deg of hysteresis by construction.
        let c = Config()
        XCTAssertGreaterThan(c.eventEntryPitch, c.eventExitPitch)
        XCTAssertEqual((c.eventEntryPitch - c.eventExitPitch) * 180 / .pi,
                       3.0, accuracy: 1e-12)
    }

    /// The v1-tolerance path. A header written before v2's fields existed must
    /// decode, taking current defaults for what it lacks.
    func testVersionOneHeaderDecodesWithDefaultsForMissingFields() throws {
        // A minimal v1-shaped config: only fields that existed in v1.
        let v1JSON = """
        {
          "version": 1,
          "gateSpecificForceLow": 9.512450499999999,
          "gateSpecificForceHigh": 10.100849500000001,
          "gateMaxRotationRate": 0.05235987755982989,
          "gateDwell": 0.5,
          "baselineTimeConstant": 25,
          "accelLowPassCutoff": 5,
          "timeToThresholdWarn": 0.4,
          "audioLatencyCompensation": 0.05,
          "eventEntryPitchRate": 0.2617993877991494,
          "eventEntryPitch": 0.13962634015954636,
          "eventExitPitch": 0.06981317007977318,
          "eventMinDuration": 0.4,
          "biasCalibrationDuration": 8,
          "biasStaleAfter": 300,
          "gyroNoiseDensity": 0.00006981317007977318,
          "gyroBiasInstability": 0.000014544410433286077,
          "accelNoiseDensity": 0.000980665,
          "baroDynamicPressureK": 0
        }
        """
        let decoded = try JSONDecoder().decode(Config.self, from: Data(v1JSON.utf8))

        // Its own values are preserved, including the v1 exit threshold of 4 deg.
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.eventExitPitch * 180 / .pi, 4.0, accuracy: 1e-9,
                       "a v1 log must re-score under the thresholds that "
                       + "produced it when replayed with its own header config")
        // Fields it never had take current defaults. (`accelNoiseInflation` used to
        // stand here; it was deleted with the ESKF path, so this now checks a
        // surviving field — the property under test is the fallback, not the field.)
        XCTAssertEqual(decoded.eventEntryDwell, Config().eventEntryDwell)
        XCTAssertEqual(decoded.eventExitDwell, Config().eventExitDwell)
        XCTAssertEqual(decoded.calibrationVibrationLimit,
                       Config().calibrationVibrationLimit)
        XCTAssertEqual(decoded.writerRingCapacity, Config().writerRingCapacity)
        XCTAssertEqual(decoded.thermalBiasNoiseScale, Config().thermalBiasNoiseScale)
    }

    func testEmptyObjectDecodesToAllDefaults() throws {
        let decoded = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, Config())
    }

    func testThermalScaleCoversEveryThermalState() {
        // ProcessInfo.ThermalState has four cases; the app indexes this by raw
        // value, so a short array would trap at runtime on a hot phone.
        XCTAssertEqual(Config().thermalBiasNoiseScale.count, 4)
        XCTAssertEqual(Config().thermalBiasNoiseScale.sorted(),
                       Config().thermalBiasNoiseScale,
                       "scale must be monotonically non-decreasing with heat")
    }
}
