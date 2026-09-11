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

extension TelemetryIntegrationHarnessTests {
    @MainActor
    private func calibratedRecorder(store: TemporaryRunStore, motion: ScriptedMotionSource,
                                    speed: ScriptedSpeedSource, clock: ManualClock) async -> RunRecorder {
        let calibration = CalibrationService()
        for i in 0..<500 {
            calibration.feedIMU(IMUSample(time: clock.current - 10 + Double(i) * 0.01,
                rotationRate: .zero, specificForce: Vector3(0, 0, -9.80665)))
        }
        for _ in 0..<1000 {
            if calibration.estimate != nil { break }
            await Task.yield()
        }
        XCTAssertNotNil(calibration.estimate)
        let recorder = RunRecorder(motionService: motion, speedService: speed,
            calibrationService: calibration, repository: store.repository,
            monotonicNow: { clock.current })
        recorder.rawRecordingEnabled = false
        recorder.startSensing(bikeProfileID: UUID())
        recorder.startSession(bikeProfileID: UUID(), mountAlignment: .identity(),
            angleTarget: MetricRange(lower: 35, upper: 45),
            speedTarget: MetricRange(lower: 35, upper: 50),
            speedGaugeMaximum: 100, speedEnabled: true)
        return recorder
    }

    @MainActor
    private func consumed(_ count: Int, by recorder: RunRecorder) async {
        for _ in 0..<10000 {
            recorder.flushDisplay()
            if recorder.sampleCount >= count { return }
            await Task.yield()
        }
        XCTFail("recorder did not consume \(count) samples")
    }

    @MainActor
    func testSettingsFreezeThroughDisarmingAndSaveFailureRetriesOnce() async throws {
        let store = TemporaryRunStore()
        defer { store.cleanup() }
        let motion = ScriptedMotionSource(), speed = ScriptedSpeedSource()
        let clock = ManualClock()
        let recorder = await calibratedRecorder(store: store, motion: motion, speed: speed, clock: clock)
        defer { recorder.stopSession() }
        XCTAssertEqual(motion.startCalls, 1, "sensing promotion must reuse acquisition")
        recorder.updateSettings(angleTarget: MetricRange(lower: 45, upper: 55),
            speedTarget: MetricRange(lower: 40, upper: 60), speedGaugeMaximum: 120, speedEnabled: true)
        motion.yieldIMU(time: clock.current)
        var count = 1
        func feed(_ n: Int, rate: Double = 0, saturated: Bool = false) {
            for _ in 0..<n {
                motion.yieldIMU(time: clock.advance(by: 0.01),
                    rotationRate: Vector3(0, rate * .pi / 180, 0), saturated: saturated)
                count += 1
            }
        }
        feed(50, rate: -80)
        feed(150)
        await consumed(count, by: recorder)
        XCTAssertTrue(recorder.eventActive)
        // Mid-attempt edits must not change this attempt's onset configuration.
        recorder.updateSettings(angleTarget: MetricRange(lower: 5, upper: 15),
            speedTarget: MetricRange(lower: 0, upper: 0), speedGaugeMaximum: 60, speedEnabled: false)
        feed(1, saturated: true)
        feed(35, rate: 100) // 40 -> 5 degrees, just entering disarming
        feed(5)
        await consumed(count, by: recorder)
        XCTAssertTrue(recorder.eventActive, "exit confirmation is still this attempt")
        feed(35, rate: -100)
        feed(100)
        store.repository.writeInterceptor = { _, _ in throw InjectedWriteFailure() }
        feed(50, rate: 80)
        feed(50)
        motion.finish(); speed.finish()
        await recorder.awaitSensorCompletion()
        recorder.flushDisplay()
        XCTAssertTrue(store.repository.allRuns.isEmpty)
        XCTAssertEqual(recorder.unsavedRuns.count, 1)
        let failed = try XCTUnwrap(recorder.unsavedRuns.first)
        XCTAssertEqual(failed.configuration.angleTarget.lower, 45)
        XCTAssertEqual(failed.configuration.speedGaugeMaximum, 120)
        XCTAssertTrue(failed.qualityFlags.contains(.saturatedInEvent))
        store.repository.writeInterceptor = nil
        recorder.retryUnsavedRuns(); recorder.retryUnsavedRuns()
        XCTAssertTrue(recorder.unsavedRuns.isEmpty)
        XCTAssertEqual(store.repository.allRuns.count, 1)
        XCTAssertEqual(store.fileCount(), 1)
        XCTAssertNil(store.repository.allTimeBest, "degraded attempt remains visible, not a verified best")
    }

    @MainActor
    func testStopRejectsQueuedSamplesAndHealthUsesAcquisitionClock() async {
        let store = TemporaryRunStore()
        defer { store.cleanup() }
        let motion = ScriptedMotionSource(), speed = ScriptedSpeedSource()
        let clock = ManualClock()
        let recorder = RunRecorder(motionService: motion, speedService: speed,
            calibrationService: CalibrationService(), repository: store.repository,
            monotonicNow: { clock.current })
        recorder.rawRecordingEnabled = false
        recorder.startSensing(bikeProfileID: UUID())
        clock.advance(by: 5.1)
        recorder.evaluateSensorHealth()
        XCTAssertFalse(recorder.sensorHealthy)
        recorder.stopSession()
        motion.yieldIMU(time: clock.current)
        motion.finish(); speed.finish()
        await Task.yield()
        recorder.flushDisplay()
        XCTAssertEqual(recorder.recordingState, .idle)
        XCTAssertEqual(recorder.sampleCount, 0)
        XCTAssertFalse(recorder.sensorHealthy)
        XCTAssertTrue(store.repository.allRuns.isEmpty)
    }

    func testPartialDeleteRetainsFailedFileAndIdempotentSave() {
        let store = TemporaryRunStore()
        defer { store.cleanup() }
        let a = K02Fixture.run(), b = K02Fixture.run()
        XCTAssertTrue(store.repository.save(a))
        XCTAssertTrue(store.repository.save(a))
        XCTAssertTrue(store.repository.save(b))
        XCTAssertEqual(store.repository.allRuns.count, 2)
        store.repository.deleteInterceptor = { url in
            if url.lastPathComponent == a.id.uuidString + ".json" { throw InjectedWriteFailure() }
            try FileManager.default.removeItem(at: url)
        }
        XCTAssertFalse(store.repository.deleteAll())
        XCTAssertEqual(store.repository.allRuns.map(\.id), [a.id])
        XCTAssertEqual(store.fileCount(), 1)
        XCTAssertNotNil(store.repository.lastError)
    }

    func testHistoricalSpeedHasUnknownValidity() throws {
        let sample = TelemetrySample(id: UUID(), elapsed: 0, angleDegrees: 10, speedKPH: 40)
        let decoded = try JSONDecoder().decode(TelemetrySample.self, from: JSONEncoder().encode(sample))
        XCTAssertNil(decoded.speedValid)
    }
}
