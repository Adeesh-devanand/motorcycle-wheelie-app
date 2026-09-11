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


extension TelemetryIntegrationHarnessTests {
    @MainActor
    func testIdleRetentionPlateausWithFullRateInput() async {
        let store = TemporaryRunStore()
        defer { store.cleanup() }
        let motion = ScriptedMotionSource(), speed = ScriptedSpeedSource()
        let clock = ManualClock()
        let recorder = await calibratedRecorder(store: store, motion: motion, speed: speed, clock: clock)
        defer { recorder.stopSession() }
        var plateaus: [Int] = []
        for batch in 1...3 {
            for _ in 0..<10000 { motion.yieldIMU(time: clock.advance(by: 0.01)) }
            await consumed(batch * 10000, by: recorder)
            plateaus.append(recorder.retainedSampleCount)
        }
        motion.finish(); speed.finish()
        await recorder.awaitSensorCompletion()
        XCTAssertTrue(plateaus.allSatisfy { $0 <= 102 }, "100/200/300-second idle retention: \(plateaus)")
        XCTAssertGreaterThanOrEqual(recorder.sampleCount, 30000)
        XCTAssertTrue(store.repository.allRuns.isEmpty)
    }
}

extension TelemetryIntegrationHarnessTests {
    @MainActor
    func testBetaConsentAndRecursiveCoordinateRedaction() throws {
        let suite = "privacy-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("synthetic.ndjson")
        let original = Data("{\"gnss\":{\"latitude\":49,\"longitude\":-123,\"speed\":10},\"nested\":[{\"lat\":1,\"value\":2}]}\n".utf8)
        try original.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: file.path)
        let uploader = BetaDiagnosticUploader(apiBase: URL(string: "https://example.invalid")!,
            token: "synthetic", logDirectory: directory, defaults: defaults)
        var scheduled = 0
        uploader.scheduleForTesting = { _ in scheduled += 1 }
        uploader.start()
        XCTAssertEqual(scheduled, 0)
        defaults.set(true, forKey: "beta.uploadConsent")
        defaults.set(Date().addingTimeInterval(-120).timeIntervalSince1970, forKey: "beta.uploadConsentSince")
        uploader.start()
        XCTAssertEqual(scheduled, 1)
        defaults.set(false, forKey: "beta.uploadConsent")
        uploader.start()
        XCTAssertEqual(scheduled, 1)
        let redacted = try BetaDiagnosticUploader.redactedData(original)
        let text = String(decoding: redacted, as: UTF8.self)
        XCTAssertFalse(text.contains("latitude"))
        XCTAssertFalse(text.contains("longitude"))
        XCTAssertFalse(text.contains("\"lat\""))
        XCTAssertTrue(text.contains("\"speed\":10"))
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertThrowsError(try BetaDiagnosticUploader.redactedData(Data("invalid JSON".utf8)))
    }

    func testAnalysisSignalAndStableIntervalsAgree() {
        let samples = (0..<31).map { index in
            TelemetrySample(id: UUID(), elapsed: Double(index) * 0.1,
                angleDegrees: index == 10 ? 80 : 40, blurredAngleDegrees: 40,
                speedKPH: 42, speedValid: index < 10 || index > 20)
        }
        let run = WheelieRun(id: UUID(), startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 3), samples: samples,
            configuration: RunConfigurationSnapshot(angleTarget: MetricRange(lower: 35, upper: 45),
                speedTarget: MetricRange(lower: 35, upper: 50), speedGaugeMaximum: 100, calibrationID: UUID()))
        let vm = RunDetailsViewModel(run: run)
        XCTAssertEqual(run.maxAngle, 40)
        XCTAssertEqual(vm.anglePoints.map(\.y).max(), 40)
        XCTAssertEqual(vm.valuesAtTime(1).angle, 40)
        XCTAssertTrue(vm.valuesAtTime(1.5).speed.isNaN)
        XCTAssertEqual(vm.speedSegments.count, 2)
        XCTAssertEqual(run.angleIntervals.map(\.id), run.angleIntervals.map(\.id))
        XCTAssertEqual(vm.totalSpeedInRange, 1.8, accuracy: 1e-8)
    }
}

extension TelemetryIntegrationHarnessTests {
    func testCachedHistoryStatisticsMatchRawReferenceAndClearNoiseBand() throws {
        let samples = (0..<200).map { i in
            TelemetrySample(id: UUID(), elapsed: Double(i) / 100,
                angleDegrees: Double(i % 75), blurredAngleDegrees: Double(i % 60),
                speedKPH: Double(i % 50), speedValid: i % 3 != 0)
        }
        let config = K02Fixture.run().configuration
        for count in [100, 1000, 10000] {
            let runs = (0..<count).map { _ in
                WheelieRun(id: UUID(), startedAt: .distantPast, endedAt: .distantPast,
                    samples: samples, configuration: config)
            }
            var baseline: [Double] = [], candidate: [Double] = []
            for iteration in 0..<5 {
                func time(_ cached: Bool) -> Double {
                    let start = ProcessInfo.processInfo.systemUptime
                    var sum = 0.0
                    for run in runs {
                        sum += cached ? run.maxAngle : (run.samples.map { $0.blurredAngleDegrees ?? $0.angleDegrees }.max() ?? 0)
                    }
                    XCTAssertEqual(sum, Double(count) * 59)
                    return ProcessInfo.processInfo.systemUptime - start
                }
                if iteration.isMultiple(of: 2) { baseline.append(time(false)); candidate.append(time(true)) }
                else { candidate.append(time(true)); baseline.append(time(false)) }
            }
            let base = baseline.sorted()[2], kept = candidate.sorted()[2]
            let noise = max(base * 0.10, baseline.max()! - baseline.min()!)
            print("HISTORY_RULER count=\(count) baseline=\(baseline) cached=\(candidate) noise=\(noise) stride=\(MemoryLayout<WheelieRun>.stride)")
            if count == 10000 { XCTAssertGreaterThan(base - kept, noise) }
            let data = try JSONEncoder().encode(runs[0])
            let restored = try JSONDecoder().decode(WheelieRun.self, from: data)
            XCTAssertEqual(restored.samples, samples)
            XCTAssertEqual(restored.maxAngle, 59)
            XCTAssertEqual(restored.rawMaxAngle, 74)
        }
    }
}
