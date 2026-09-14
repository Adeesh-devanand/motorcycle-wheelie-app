import XCTest
@testable import MotoTelemetryCore

final class UnifiedRecordingTests: XCTestCase {
    func testPausedOrientationContinuesAndResumedRecordingReplays() throws {
        let config = Config()
        let gravity = Vector3(0, 0, -9.80665)
        var pipe = Pipeline(config: config, alignment: .identity(), initialBias: nil,
                            gravityAnchor: gravity)
        _ = pipe.process(.imu(IMUSample(time: 0, rotationRate: .zero, specificForce: gravity)))
        // Reach 20 degrees before pausing.
        for i in 1...100 {
            _ = pipe.process(.imu(IMUSample(time: Double(i) * 0.01,
                rotationRate: Vector3(0, -20 * .pi / 180, 0), specificForce: gravity)))
        }
        XCTAssertEqual(pipe.orientationCheckpoint.estimator.pitch * 180 / .pi, 20, accuracy: 0.001)
        // Hold through a pause, then move another 15 degrees while still paused.
        for i in 101...300 {
            pipe.trackOrientation(IMUSample(time: Double(i) * 0.01,
                rotationRate: i <= 200 ? .zero : Vector3(0, -15 * .pi / 180, 0),
                specificForce: gravity))
            if i == 200 {
                XCTAssertEqual(pipe.orientationCheckpoint.estimator.pitch * 180 / .pi, 20, accuracy: 0.001)
            }
        }
        let checkpoint = pipe.orientationCheckpoint
        XCTAssertEqual(checkpoint.estimator.pitch * 180 / .pi, 35, accuracy: 0.001)
        var resumed = Pipeline(config: config, alignment: .identity(), initialBias: nil,
                               gravityAnchor: gravity)
        resumed.restoreOrientation(checkpoint)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ndjson")
        defer { try? FileManager.default.removeItem(at: url) }
        var header = LogHeader(); header.formatVersion = 2
        var data = try LogFile.encodeHeader(header)
        func append<T: Encodable>(_ value: T) throws {
            data.append(try JSONEncoder().encode(value)); data.append(10)
        }
        try append(RecordingContext(time: 3, config: config, alignment: .identity(),
            initialBias: nil, gravityAnchor: gravity, speedEnabled: false,
            orientationCheckpoint: checkpoint))
        let sample = Sample.imu(IMUSample(time: 3.01, rotationRate: .zero, specificForce: gravity))
        try append(sample)
        let output = try XCTUnwrap(resumed.process(sample))
        XCTAssertEqual(output.pitch * 180 / .pi, 35, accuracy: 0.001)
        try append(RecordedOutput(output))
        data.append(Data("{\"kind\":\"recordingEnd\",\"complete\":true}\n".utf8))
        try data.write(to: url)
        let report = try RecordingAudit.run(url: url)
        XCTAssertEqual(report.comparedOutputs, 1)
        XCTAssertEqual(report.mismatchedOutputs, 0)
        XCTAssertFalse(report.incomplete)
    }

    func testDisplayTracksFastLiftWithoutFrameRateDependentDelay() {
        for hz in [30.0, 60.0, 120.0] {
            var filter = ResponsiveDisplayFilter()
            _ = filter.update(0, time: 0)
            var angle = 0.0
            for i in 1...Int(hz / 10) { angle = filter.update(30, time: Double(i) / hz) }
            XCTAssertGreaterThan(angle, 29, "Fast lift must be visible within 100 ms")
            XCTAssertLessThanOrEqual(angle, 30)
            XCTAssertEqual(filter.update(5, time: 2), 5, "No stale smoothing after a pause")
        }
    }

    func testUnifiedReplayPreservesArrivalOrderMountBiasAndSessionBoundaries() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ndjson")
        defer { try? FileManager.default.removeItem(at: url) }
        var header = LogHeader(); header.formatVersion = 2
        var data = try LogFile.encodeHeader(header)
        let encoder = JSONEncoder()
        func append<T: Encodable>(_ value: T) throws {
            data.append(try encoder.encode(value)); data.append(10)
        }
        let config = Config()
        let anchor = Vector3(0, 0, -9.80665)
        let alignment = MountAlignment.identity()
        // Pre-calibration sample must not become the replay anchor or output.
        try append(Sample.imu(IMUSample(time: 1, rotationRate: .zero, specificForce: anchor)))
        for start in [100.0, 200.0] {
            let context = RecordingContext(time: start, config: config, alignment: alignment,
                initialBias: nil, gravityAnchor: anchor, speedEnabled: true)
            try append(context)
            var pipe = Pipeline(config: config, alignment: alignment, initialBias: nil, gravityAnchor: anchor)
            var seg = EventSegmenter(config: config)
            for i in 0..<120 {
                let t = start + Double(i) * 0.01
                if i == 50 {
                    // A delayed fix belongs here, NOT before the samples at its fix time.
                    let fix = Sample.gnss(GNSSFix(fixTime: start + 0.2, arrivalTime: t, speed: 15, speedAccuracy: 0.2))
                    try append(fix)
                    if seg.state == .idle { pipe.resetQualityFlags() }
                    _ = pipe.process(fix)
                }
                let sample = Sample.imu(IMUSample(time: t, rotationRate: Vector3(0, -0.4, 0), specificForce: anchor))
                try append(sample)
                if seg.state == .idle { pipe.resetQualityFlags() }
                if let output = pipe.process(sample) {
                    try append(RecordedOutput(output))
                    _ = seg.process(time: t, pitch: output.pitch, pitchRate: output.pitchRate)
                    pipe.eventActive = seg.state == .active || seg.state == .disarming
                }
            }
            try append(RecordingControl(time: start + 1.2, action: "stop"))
        }
        data.append(Data("{\"kind\":\"recordingEnd\",\"complete\":true}\n".utf8))
        try data.write(to: url)
        let report = try RecordingAudit.run(url: url)
        XCTAssertEqual(report.pipelineStarts, 2)
        XCTAssertEqual(report.pipelineOutputs, 240)
        XCTAssertEqual(report.comparedOutputs, 240)
        XCTAssertEqual(report.mismatchedOutputs, 0)
        XCTAssertFalse(report.incomplete)
        XCTAssertEqual(report.maxSpeedKPH, 54)
        let (_, samples) = try LogFile.read(contentsOf: url)
        XCTAssertEqual(samples.count, 243)
        var stream = try LogStreamReader(url: url)
        defer { stream.close() }
        var count = 0
        while try stream.next() != nil { count += 1 }
        XCTAssertEqual(count, samples.count)
        data.append(Data("{\"imu\":".utf8))
        try data.write(to: url)
        XCTAssertTrue(try RecordingAudit.run(url: url).incomplete)
    }

    func testCoordinateRedactionRetainsReplayableSpeedWithoutInventingPosition() throws {
        let data = Data("""
        {"fixTime":123.123456789,"arrivalTime":123.4,"speed":18,"speedAccuracy":0.2}
        """.utf8)
        let fix = try JSONDecoder().decode(GNSSFix.self, from: data)
        XCTAssertTrue(fix.coordinatesRedacted)
        XCTAssertEqual(fix.resolvedSpeed, 18)
        XCTAssertEqual(fix.fixTime, 123.123456789)
    }
}
