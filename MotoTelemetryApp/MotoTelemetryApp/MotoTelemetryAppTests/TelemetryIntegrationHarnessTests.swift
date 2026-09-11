import XCTest
import MotoTelemetryCore
@testable import MotoTelemetryApp

final class TelemetryIntegrationHarnessTests: XCTestCase {
    @MainActor
    func testScriptedRecorderPersistsRealEvent() async throws {
        let store = TemporaryRunStore()
        defer { store.cleanup() }
        let motion = ScriptedMotionSource()
        let speed = ScriptedSpeedSource()
        let calibration = CalibrationService()
        // A real still-window, no calibration override or wall-clock sleep.
        for i in 0..<500 {
            calibration.feedIMU(IMUSample(time: 990 + Double(i) * 0.01,
                rotationRate: .zero, specificForce: Vector3(0, 0, -9.80665)))
        }
        // Allow the coalesced main-actor calibration publication to run.
        for _ in 0..<1000 {
            if calibration.estimate != nil { break }
            await Task.yield()
        }
        XCTAssertNotNil(calibration.estimate)
        let clock = ManualClock()
        let recorder = RunRecorder(motionService: motion, speedService: speed,
            calibrationService: calibration, repository: store.repository,
            monotonicNow: { clock.current })
        recorder.rawRecordingEnabled = false
        recorder.startSession(bikeProfileID: UUID(), mountAlignment: .identity(),
            angleTarget: MetricRange(lower: 35, upper: 45),
            speedTarget: MetricRange(lower: 35, upper: 50),
            speedGaugeMaximum: 100, speedEnabled: true)
        defer { recorder.stopSession() }
        // Lift 40 degrees, hold for two seconds, lower, confirm exit.
        motion.yieldIMU(time: clock.current)
        for i in 0..<400 {
            let rate: Double = i < 50 ? -80 : (i >= 250 && i < 300 ? 80 : 0)
            motion.yieldIMU(time: clock.advance(by: 0.01),
                rotationRate: Vector3(0, rate * .pi / 180, 0))
        }
        motion.finish()
        speed.finish()
        await recorder.awaitSensorCompletion()
        recorder.flushDisplay()
        XCTAssertGreaterThan(recorder.sampleCount, 350)
        XCTAssertEqual(store.repository.allRuns.count, 1,
            "must traverse recorder/event finalization, not repository.save directly")
        let run = try XCTUnwrap(store.repository.allRuns.first)
        XCTAssertGreaterThan(run.samples.count, 150)
        XCTAssertGreaterThan(run.maxAngle, 35)
        XCTAssertEqual(store.fileCount(), 1)
        let reloaded = RunRepository(runsDirectory: store.directory)
        XCTAssertEqual(reloaded.allRuns.first?.id, run.id)
        XCTAssertEqual(reloaded.allRuns.first?.samples.count, run.samples.count)
    }

    func testInjectedWriteFailureDoesNotPublishAndCanRecover() {
        let store = TemporaryRunStore()
        defer { store.cleanup() }
        let run = K02Fixture.run()
        store.repository.writeInterceptor = { _, _ in throw InjectedWriteFailure() }
        store.repository.save(run)
        XCTAssertTrue(store.repository.allRuns.isEmpty)
        XCTAssertEqual(store.fileCount(), 0)
        store.repository.writeInterceptor = nil
        store.repository.save(run)
        XCTAssertEqual(store.repository.allRuns.map(\.id), [run.id])
        XCTAssertEqual(store.fileCount(), 1)
    }
}
