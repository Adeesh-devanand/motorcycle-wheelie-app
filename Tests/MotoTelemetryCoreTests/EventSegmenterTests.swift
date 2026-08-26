import XCTest
@testable import MotoTelemetryCore

final class EventSegmenterTests: XCTestCase {
    let config = Config()

    /// Helper: feed a series of (time, pitch, pitchRate) tuples and collect transitions.
    private func feed(_ segmenter: inout EventSegmenter,
                      samples: [(time: TimeInterval, pitch: Double, pitchRate: Double)]) -> [EventSegmenter.Transition] {
        var transitions: [EventSegmenter.Transition] = []
        for s in samples {
            if let t = segmenter.process(time: s.time, pitch: s.pitch, pitchRate: s.pitchRate) {
                transitions.append(t)
            }
        }
        return transitions
    }

    // MARK: - T5.1 Tests

    /// Dwell-not-met produces no onset: pitch crosses entry but drops back before
    /// entryDwell (0.15 s) elapses. The segmenter must not falsely trigger on bumps.
    func testDwellNotMetProducesNoOnset() {
        var seg = EventSegmenter(config: config)
        let entryPitch = config.eventEntryPitch
        let dt = 0.01 // 100 Hz

        // Pitch rises above entry at t=1.0, drops below at t=1.10 (< 0.15 s dwell)
        var samples: [(TimeInterval, Double, Double)] = []
        for i in 0..<100 {
            samples.append((Double(i) * dt, 0, 0))
        }
        // Cross above entry at t=1.0
        samples.append((1.0, entryPitch + 0.01, 0.1))
        // Hold above for only 0.10 s (10 samples)
        for i in 1...10 {
            samples.append((1.0 + Double(i) * dt, entryPitch + 0.02, 0.1))
        }
        // Drop below at t=1.11 — dwell was only 0.10 s < 0.15 s
        samples.append((1.11, entryPitch - 0.01, -0.1))

        let transitions = feed(&seg, samples: samples)
        let onsets = transitions.filter {
            if case .onset = $0.kind { return true }
            return false
        }
        XCTAssertEqual(onsets.count, 0,
                       "A bump shorter than entryDwell must not produce an onset — " +
                       "dwell exists to reject transient vibration spikes")
    }

    /// Jitter across the exit threshold does not end an event: pitch briefly dips
    /// below exitPitch but returns above before exitDwell (0.25 s) elapses.
    func testJitterAcrossExitThresholdDoesNotEndEvent() {
        var seg = EventSegmenter(config: config)
        let dt = 0.01

        // Establish a solid event first
        var samples: [(TimeInterval, Double, Double)] = []
        samples.append((0.0, 0, 0))
        // Cross entry
        samples.append((1.0, config.eventEntryPitch + 0.01, 0.2))
        // Hold above entry for dwell
        for i in 1...20 {
            samples.append((1.0 + Double(i) * dt, config.eventEntryPitch + 0.05, 0.1))
        }
        // Now active — dip below exit briefly
        samples.append((1.5, config.eventExitPitch - 0.01, -0.1))
        // But return above exit before exitDwell (0.25 s)
        for i in 1...15 { // only 0.15 s below
            samples.append((1.5 + Double(i) * dt, config.eventExitPitch - 0.005, 0))
        }
        // Return above exit at t=1.66
        samples.append((1.66, config.eventExitPitch + 0.02, 0.05))
        // Continue active for a while
        for i in 1...50 {
            samples.append((1.66 + Double(i) * dt, config.eventEntryPitch + 0.1, 0))
        }

        let transitions = feed(&seg, samples: samples)
        let ends = transitions.filter {
            if case .end = $0.kind { return true }
            return false
        }
        XCTAssertEqual(ends.count, 0,
                       "Road texture jitter below the exit threshold must not kill " +
                       "the event — exitDwell exists to reject brief dips")
        XCTAssertEqual(seg.state, .active,
                       "Segmenter should return to active after the jitter subsides")
    }

    /// A 0.3 s blip is discarded: event shorter than eventMinDuration (0.4 s).
    func testShortBlipIsDiscarded() {
        var seg = EventSegmenter(config: config)
        let dt = 0.01

        var samples: [(TimeInterval, Double, Double)] = []
        samples.append((0.0, 0, 0))

        // Cross entry at t=1.0
        samples.append((1.0, config.eventEntryPitch + 0.01, 0.2))
        // Hold above for dwell (0.15 s)
        for i in 1...16 {
            samples.append((1.0 + Double(i) * dt, config.eventEntryPitch + 0.05, 0.05))
        }
        // Onset fires. Now quickly drop below exit at t≈1.30 (0.30 s after onset)
        samples.append((1.30, config.eventExitPitch - 0.01, -0.5))
        // Hold below exit for exitDwell
        for i in 1...30 {
            samples.append((1.30 + Double(i) * dt, config.eventExitPitch - 0.02, 0))
        }

        let transitions = feed(&seg, samples: samples)
        let discarded = transitions.filter {
            if case .discarded = $0.kind { return true }
            return false
        }
        XCTAssertFalse(discarded.isEmpty,
                       "An event lasting ~0.3 s (< 0.4 s minDuration) must be discarded — " +
                       "it's a bump, not a wheelie")
        if case .discarded(let dur) = discarded.first?.kind {
            XCTAssertLessThan(dur, config.eventMinDuration,
                             "Discarded event duration must be below the minimum")
        }
    }

    /// Boundary lands strictly BETWEEN two sample times: onset and end must be
    /// interpolated, not snapped to either bracketing sample.
    func testBoundaryInterpolatedBetweenSamples() {
        var seg = EventSegmenter(config: config)

        // Craft two samples that bracket the entryPitch threshold.
        // Sample at t=1.0: pitch=6° (below 8°)
        // Sample at t=1.01: pitch=12° (above 8°)
        // Expected crossing: u = (8° - 6°)/(12° - 6°) = 1/3
        // t = 1.0 + 1/3 * 0.01 ≈ 1.003333
        let below = 6.0 * .pi / 180
        let above = 12.0 * .pi / 180
        let threshold = config.eventEntryPitch // 8°

        var samples: [(TimeInterval, Double, Double)] = []
        samples.append((0.0, 0, 0))
        samples.append((1.0, below, 0.3))
        samples.append((1.01, above, 0.3))
        // Hold above for dwell
        for i in 1...20 {
            samples.append((1.01 + Double(i) * 0.01, above + 0.02, 0.1))
        }

        let transitions = feed(&seg, samples: samples)
        guard let onset = transitions.first,
              case .onset(let onsetTime) = onset.kind else {
            XCTFail("Expected an onset transition")
            return
        }

        // The interpolated time must be strictly between the two bracketing samples.
        XCTAssertGreaterThan(onsetTime, 1.0,
                            "Onset must not snap to the earlier sample — " +
                            "interpolation places the crossing after it")
        XCTAssertLessThan(onsetTime, 1.01,
                         "Onset must not snap to the later sample — " +
                         "interpolation places the crossing before it")

        // Verify the interpolation is approximately correct.
        let expectedU = (threshold - below) / (above - below)
        let expectedTime = 1.0 + expectedU * 0.01
        XCTAssertEqual(onsetTime, expectedTime, accuracy: 1e-9,
                      "Interpolated onset should match u = (threshold - prev)/(curr - prev)")
    }

    // MARK: - T5.2 Tests

    /// A slow deliberate lift registers as an event, marked .weak — the pitch rate
    /// confidence signal must NOT gate the detection.
    func testSlowLiftRegistersAsWeak() {
        var seg = EventSegmenter(config: config)
        let dt = 0.01

        // Slowly ramp pitch from 0 to 15° over 2 seconds.
        // Rate = 15°/2s = 7.5°/s — below eventEntryPitchRate of 15°/s.
        let rampDuration = 2.0
        let peakPitch = 15.0 * .pi / 180
        let rate = peakPitch / rampDuration // ~0.131 rad/s = 7.5°/s

        var samples: [(TimeInterval, Double, Double)] = []
        samples.append((0.0, 0, 0))

        let nSamples = Int(rampDuration / dt)
        for i in 0...nSamples {
            let t = Double(i) * dt
            let pitch = rate * t
            samples.append((t, pitch, rate))
        }
        // Hold high for a while to pass minDuration
        for i in 0...100 {
            samples.append((rampDuration + Double(i) * dt, peakPitch, 0))
        }

        let transitions = feed(&seg, samples: samples)
        let onsets = transitions.filter {
            if case .onset = $0.kind { return true }
            return false
        }
        XCTAssertEqual(onsets.count, 1,
                      "A slow lift must still register as an event — " +
                      "entryPitchRate is a confidence signal, not a gate")
        XCTAssertEqual(onsets.first?.confidence, .weak,
                      "A lift below entryPitchRate must be marked .weak, " +
                      "not rejected outright")
    }

    /// A fast lift registers as .confident.
    func testFastLiftRegistersAsConfident() {
        var seg = EventSegmenter(config: config)
        let dt = 0.01

        // Rate = 20°/s > 15°/s threshold
        let rate = 20.0 * .pi / 180

        var samples: [(TimeInterval, Double, Double)] = []
        samples.append((0.0, 0, 0))
        samples.append((1.0, config.eventEntryPitch - 0.01, rate))
        samples.append((1.01, config.eventEntryPitch + 0.02, rate))
        // Hold for dwell
        for i in 1...20 {
            samples.append((1.01 + Double(i) * dt, config.eventEntryPitch + 0.1, rate))
        }

        let transitions = feed(&seg, samples: samples)
        guard let onset = transitions.first else {
            XCTFail("Expected onset for fast lift")
            return
        }
        XCTAssertEqual(onset.confidence, .confident,
                      "A lift exceeding entryPitchRate must be marked .confident")
    }

    /// Debug bypass: events shorter than minDuration are emitted when the flag is set.
    func testDebugBypassEmitsShortEvents() {
        var seg = EventSegmenter(config: config, debugBypassMinDuration: true)
        let dt = 0.01

        var samples: [(TimeInterval, Double, Double)] = []
        samples.append((0.0, 0, 0))
        samples.append((1.0, config.eventEntryPitch + 0.01, 0.3))
        for i in 1...16 {
            samples.append((1.0 + Double(i) * dt, config.eventEntryPitch + 0.05, 0.05))
        }
        // Drop below exit immediately for a ~0.2 s event
        samples.append((1.20, config.eventExitPitch - 0.01, -0.5))
        for i in 1...30 {
            samples.append((1.20 + Double(i) * dt, config.eventExitPitch - 0.02, 0))
        }

        let transitions = feed(&seg, samples: samples)
        let ends = transitions.filter {
            if case .end = $0.kind { return true }
            return false
        }
        XCTAssertFalse(ends.isEmpty,
                       "Debug bypass must emit events that would normally be discarded")
    }
}
