import XCTest
@testable import MotoTelemetryCore

final class CueEngineTests: XCTestCase {

    // Use a 45-degree (π/4 rad) upper target for most tests.
    private let targetUpper = 45.0 * .pi / 180.0

    // MARK: - Creeping approach stays silent (R13.3)

    /// A 3 deg/s approach is so slow that time-to-threshold exceeds the lead time
    /// and no cue fires. This is the "creep up slowly stays quiet" requirement.
    func testNoCueForSlowApproach() {
        var engine = CueEngine(
            angleTargetUpper: targetUpper,
            timeToThresholdWarn: 0.4,
            audioLatencyCompensation: 0.05,
            loopOutPitchRate: 60.0 * .pi / 180.0,
            cueReleaseTime: 0.15
        )

        let rate = 3.0 * .pi / 180.0  // 3 deg/s in rad/s
        // Lead time L = 0.4 + 0.05 = 0.45s. At 3 deg/s pitch must be within
        // 3 * 0.45 = 1.35 deg of target to trigger — which never happens here.
        // to trigger. Start at 30 deg — far from the target.
        for i in 0..<100 {
            let t = Double(i) * 0.01
            let pitch = 30.0 * .pi / 180.0 + rate * t
            let state = engine.process(pitch: pitch, pitchRate: rate, time: t)

            // ttt = (target - pitch) / rate. At 30 deg with target 45 deg:
            // ttt = (45-30)*π/180 / (3*π/180) = 5.0 s >> 0.45 s lead.
            // So it stays silent the entire time (we only simulate 1s here).
            XCTAssertEqual(state.tone, .silent,
                           "A 3 deg/s creep at t=\(t) must not trigger — ttt is too large")
        }
    }

    // MARK: - Fast approach fires early (self-scaling)

    /// A 60 deg/s approach triggers the cue at least 0.35s before threshold.
    /// This self-scaling is why the cue fires on time-to-threshold: fast moves get
    /// warned early, slow creeps stay silent.
    func testCueFires035sBeforeThresholdAt60DegPerSec() {
        var engine = CueEngine(
            angleTargetUpper: targetUpper,
            timeToThresholdWarn: 0.4,
            audioLatencyCompensation: 0.05,
            loopOutPitchRate: 60.0 * .pi / 180.0,
            cueReleaseTime: 0.15
        )

        let rate = 60.0 * .pi / 180.0  // 60 deg/s
        let L = 0.45  // lead time
        let dt = 0.001  // 1000 Hz sample rate for precision

        // Start from 20 degrees, approaching 45 degrees at 60 deg/s.
        // Time to reach target: (45-20)/60 = 0.4167s
        let startPitch = 20.0 * .pi / 180.0
        var firstCueTime: TimeInterval? = nil
        var thresholdTime: TimeInterval? = nil

        for i in 0..<1000 {
            let t = Double(i) * dt
            let pitch = startPitch + rate * t
            let state = engine.process(pitch: pitch, pitchRate: rate, time: t)

            if state.tone == .approach && firstCueTime == nil {
                firstCueTime = t
            }
            if pitch >= targetUpper && thresholdTime == nil {
                thresholdTime = t
            }
        }

        guard let cueStart = firstCueTime, let threshold = thresholdTime else {
            XCTFail("Cue should have fired before reaching threshold")
            return
        }

        let earlyBy = threshold - cueStart
        XCTAssertGreaterThanOrEqual(earlyBy, 0.35,
            "Cue must fire at least 0.35s before threshold crossing; fired \(earlyBy)s early")
        // Should fire approximately L = 0.45s early.
        XCTAssertLessThan(earlyBy, L + 0.05, "Cue shouldn't fire unreasonably early")
    }

    // MARK: - Loop-out preempts approach

    /// When pitchRate exceeds loopOutPitchRate, .loopOut PREEMPTS .approach.
    func testLoopOutPreemptsApproach() {
        var engine = CueEngine(
            angleTargetUpper: targetUpper,
            timeToThresholdWarn: 0.4,
            audioLatencyCompensation: 0.05,
            loopOutPitchRate: 60.0 * .pi / 180.0,
            cueReleaseTime: 0.15
        )

        // Pitch close to target with a rate that exceeds loopOutPitchRate.
        // This should trigger both approach AND loopOut conditions, but loopOut wins.
        let pitch = 40.0 * .pi / 180.0
        let highRate = 70.0 * .pi / 180.0  // > 60 deg/s threshold

        let state = engine.process(pitch: pitch, pitchRate: highRate, time: 0.0)
        XCTAssertEqual(state.tone, .loopOut, "loopOut must preempt approach when rate exceeds threshold")
        XCTAssertEqual(state.urgency, 1.0)
    }

    // MARK: - Hysteresis prevents chatter at 100 Hz

    /// Without hysteresis, a value oscillating around the cue boundary at 100 Hz
    /// would toggle the tone on/off every 10ms — producing an unusable clicking noise.
    /// The cueReleaseTime (0.15s) holds the tone during brief false periods.
    ///
    /// Test: alternate 5ms in-condition / 5ms out-of-condition (100 Hz boundary crossing).
    /// Each out-of-condition burst is 5ms << 0.15s holdoff, so the tone must NEVER release.
    /// Without hysteresis this would produce 50 toggles; with it, zero.
    func testHysteresisStopsChatter() {
        let cueReleaseTime: TimeInterval = 0.15
        var engine = CueEngine(
            angleTargetUpper: targetUpper,
            timeToThresholdWarn: 0.4,
            audioLatencyCompensation: 0.05,
            loopOutPitchRate: 60.0 * .pi / 180.0,
            cueReleaseTime: cueReleaseTime
        )

        let dt = 0.005  // 200 Hz to get fine granularity
        // Pitch close enough that at high rate, ttt < L (approach fires),
        // and at low rate, ttt > L (approach condition false).
        let pitch = 42.0 * .pi / 180.0  // 3 deg from target
        // Lead time L = 0.45s.
        // ttt = remaining / rate; remaining = (45-42)*pi/180 = 0.05236 rad
        // For approach: need ttt <= 0.45, i.e. rate >= 0.05236/0.45 = 0.1163 rad/s ≈ 6.67 deg/s
        let rateHigh = 50.0 * .pi / 180.0   // ttt = 0.05236/0.873 = 0.06s < L → fires
        let rateLow = 3.0 * .pi / 180.0     // ttt = 0.05236/0.0524 = 1.0s > L → condition false

        // Prime the engine into approach state.
        let s0 = engine.process(pitch: pitch, pitchRate: rateHigh, time: 0.0)
        XCTAssertEqual(s0.tone, .approach, "Precondition: engine should start in approach")
        var prevTone: CueState.Tone = .approach

        var toneChanges = 0
        // Run for 100 samples (0.5s) alternating every sample between condition-true and condition-false.
        // Each false period is only 5ms (one sample at 200Hz) << 0.15s holdoff.
        for i in 1..<100 {
            let t = Double(i) * dt
            let rate = (i % 2 == 0) ? rateHigh : rateLow
            let state = engine.process(pitch: pitch, pitchRate: rate, time: t)

            if state.tone != prevTone {
                toneChanges += 1
                prevTone = state.tone
            }
        }

        // Every false period is 5ms < 0.15s, so hysteresis should suppress ALL releases.
        // The tone must not toggle at all during this 0.5s window.
        XCTAssertEqual(toneChanges, 0,
            "Tone toggled \(toneChanges) times — hysteresis must prevent chatter when false periods (5ms) < cueReleaseTime (150ms)")
    }

    // MARK: - Urgency scaling

    /// Urgency should be 0 at ttt==L and 1 at ttt==0.
    func testUrgencyScaling() {
        var engine = CueEngine(
            angleTargetUpper: targetUpper,
            timeToThresholdWarn: 0.4,
            audioLatencyCompensation: 0.05,
            loopOutPitchRate: 60.0 * .pi / 180.0,
            cueReleaseTime: 0.15
        )

        let L = 0.45
        // At exactly L seconds from threshold: urgency = 1 - L/L = 0
        let rateForTTTatL = (targetUpper - 30.0 * .pi / 180.0) / L
        let state1 = engine.process(pitch: 30.0 * .pi / 180.0, pitchRate: rateForTTTatL, time: 0.0)
        if state1.tone == .approach {
            XCTAssertEqual(state1.urgency, 0.0, accuracy: 0.05)
        }

        // At near-zero ttt: urgency near 1.
        let nearTarget = targetUpper - 0.001
        let state2 = engine.process(pitch: nearTarget, pitchRate: 60.0 * .pi / 180.0, time: 0.1)
        if state2.tone == .approach || state2.tone == .loopOut {
            XCTAssertGreaterThan(state2.urgency, 0.9)
        }
    }

    // MARK: - timeToThreshold passthrough

    func testTimeToThresholdPassedThrough() {
        var engine = CueEngine(
            angleTargetUpper: targetUpper,
            timeToThresholdWarn: 0.4,
            audioLatencyCompensation: 0.05,
            loopOutPitchRate: 60.0 * .pi / 180.0,
            cueReleaseTime: 0.15
        )

        let pitch = 30.0 * .pi / 180.0
        let rate = 50.0 * .pi / 180.0
        let state = engine.process(pitch: pitch, pitchRate: rate, time: 0.0)

        let expectedTTT = (targetUpper - pitch) / rate
        XCTAssertNotNil(state.timeToThreshold)
        XCTAssertEqual(state.timeToThreshold!, expectedTTT, accuracy: 1e-9)
    }

    // MARK: - Not closing → nil ttt → silent

    func testNotClosingStaysSilent() {
        var engine = CueEngine(
            angleTargetUpper: targetUpper,
            timeToThresholdWarn: 0.4,
            audioLatencyCompensation: 0.05,
            loopOutPitchRate: 60.0 * .pi / 180.0,
            cueReleaseTime: 0.15
        )

        // Negative rate (moving away).
        let state = engine.process(pitch: 30.0 * .pi / 180.0, pitchRate: -10.0 * .pi / 180.0, time: 0.0)
        XCTAssertEqual(state.tone, .silent)
        XCTAssertNil(state.timeToThreshold)
    }

    // MARK: - Already past target → silent

    func testAlreadyPastTargetStaysSilent() {
        var engine = CueEngine(
            angleTargetUpper: targetUpper,
            timeToThresholdWarn: 0.4,
            audioLatencyCompensation: 0.05,
            loopOutPitchRate: 60.0 * .pi / 180.0,
            cueReleaseTime: 0.15
        )

        // Already above target, still rising but slowly.
        let state = engine.process(
            pitch: 50.0 * .pi / 180.0,
            pitchRate: 5.0 * .pi / 180.0,
            time: 0.0
        )
        // remaining = target - current < 0, so timeToThreshold returns nil.
        XCTAssertNil(state.timeToThreshold)
        // May be loopOut if rate < threshold, or silent.
        // At 5 deg/s < 60 deg/s loopOut threshold → silent.
        XCTAssertEqual(state.tone, .silent)
    }

    // MARK: - Hysteresis release after cueReleaseTime

    func testHysteresisReleasesAfterTimeout() {
        var engine = CueEngine(
            angleTargetUpper: targetUpper,
            timeToThresholdWarn: 0.4,
            audioLatencyCompensation: 0.05,
            loopOutPitchRate: 60.0 * .pi / 180.0,
            cueReleaseTime: 0.15
        )

        // Trigger approach.
        let pitch = 42.0 * .pi / 180.0
        let rate = 50.0 * .pi / 180.0
        let s1 = engine.process(pitch: pitch, pitchRate: rate, time: 0.0)
        XCTAssertEqual(s1.tone, .approach)

        // Condition goes false (moving away).
        let s2 = engine.process(pitch: pitch, pitchRate: -5.0 * .pi / 180.0, time: 0.01)
        XCTAssertEqual(s2.tone, .approach, "Should hold during hysteresis window")

        // Still within cueReleaseTime.
        let s3 = engine.process(pitch: pitch, pitchRate: -5.0 * .pi / 180.0, time: 0.10)
        XCTAssertEqual(s3.tone, .approach, "Still within 0.15s holdoff")

        // Past cueReleaseTime → released.
        let s4 = engine.process(pitch: pitch, pitchRate: -5.0 * .pi / 180.0, time: 0.20)
        XCTAssertEqual(s4.tone, .silent, "Should release after cueReleaseTime expires")
    }

    // MARK: - CueState Codable

    func testCueStateCodable() throws {
        let state = CueState(tone: .approach, urgency: 0.75, timeToThreshold: 0.23)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(CueState.self, from: data)
        XCTAssertEqual(state, decoded)
    }
}
