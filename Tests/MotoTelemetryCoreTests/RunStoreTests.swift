import XCTest
@testable import MotoTelemetryCore

final class RunStoreTests: XCTestCase {

    private var tempDir: URL!
    private var store: RunStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunStoreTests-\(UUID().uuidString)")
        store = RunStore(directory: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeRecord(id: UUID = UUID()) -> RunRecord {
        RunRecord(
            id: id,
            sessionID: "session-1",
            span: SessionSpan(sessionID: "session-1", startTime: 100.0, endTime: 105.0),
            metrics: EventMetrics(
                onset: 100.0,
                end: 105.0,
                duration: 5.0,
                liveMaxAngle: 0.6,
                averageHeldAngle: 0.55,
                angleStdDev: 0.02,
                distance: 25.0,
                entrySpeed: 12.0,
                rollMin: -0.05,
                rollMax: 0.03,
                flags: [],
                holdWindowResolved: true
            ),
            display: [
                DisplayPoint(elapsed: 0.0, pitch: 0.0, speed: 12.0),
                DisplayPoint(elapsed: 0.03125, pitch: 0.1, speed: 12.125),
                DisplayPoint(elapsed: 0.0625, pitch: 0.3, speed: 12.25),
                DisplayPoint(elapsed: 5.0, pitch: 0.0, speed: 12.5),
            ],
            angleIntervals: [
                TimeSpan(start: 100.5, end: 104.5)
            ],
            speedIntervals: [
                TimeSpan(start: 100.0, end: 105.0)
            ],
            snapshot: TargetSnapshot(
                angleRange: 0.35...0.70,
                speedRange: 8.9...22.4
            ),
            configVersion: 3,
            flags: []
        )
    }

    // MARK: - Round-trip encode/decode

    func testRoundTrip() throws {
        let original = makeRecord()

        try store.save(original)
        let loaded = try store.load(id: original.id)

        XCTAssertEqual(loaded, original)
    }

    func testRoundTripWithFlags() throws {
        var record = makeRecord()
        record.flags = [.highVibration, .lowRate]
        record.metrics.flags = [.highVibration, .lowRate]

        try store.save(record)
        let loaded = try store.load(id: record.id)

        XCTAssertEqual(loaded.flags, [.highVibration, .lowRate])
        XCTAssertEqual(loaded.metrics.flags, [.highVibration, .lowRate])
    }

    func testLoadAll() throws {
        let r1 = makeRecord(id: UUID())
        let r2 = makeRecord(id: UUID())

        try store.save(r1)
        try store.save(r2)

        let all = try store.loadAll()
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(all.contains(r1))
        XCTAssertTrue(all.contains(r2))
    }

    // MARK: - Atomic write guarantees

    func testAtomicWrite_fileExistsOnlyAfterCompletion() throws {
        let record = makeRecord()
        let finalPath = tempDir.appendingPathComponent("\(record.id.uuidString).json").path

        // Before save: file must not exist.
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalPath))

        try store.save(record)

        // After save: file exists and is complete.
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalPath))

        // No temp files should remain.
        let tempPath = tempDir.appendingPathComponent(".\(record.id.uuidString).tmp").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempPath))
    }

    func testAtomicWrite_noTempFilesRemainAfterSave() throws {
        let record = makeRecord()
        try store.save(record)

        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        let tempFiles = contents.filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(tempFiles.count, 0, "No temp files should remain after successful save")
    }

    func testOverwrite_existingRecord() throws {
        let id = UUID()
        var original = makeRecord(id: id)
        try store.save(original)

        original.configVersion = 99
        try store.save(original)

        let loaded = try store.load(id: id)
        XCTAssertEqual(loaded.configVersion, 99)
    }

    func testLoadAll_emptyDirectory() throws {
        let all = try store.loadAll()
        XCTAssertEqual(all.count, 0)
    }

    func testLoadAll_skipsCorruptFiles() throws {
        // Create the directory.
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Write a valid record.
        let valid = makeRecord()
        try store.save(valid)

        // Write a corrupt file.
        let corruptURL = tempDir.appendingPathComponent("corrupt.json")
        try "not valid json {{{{".data(using: .utf8)!.write(to: corruptURL)

        let all = try store.loadAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first, valid)
    }

    func testDelete() throws {
        let record = makeRecord()
        try store.save(record)
        XCTAssertEqual(try store.loadAll().count, 1)

        try store.delete(id: record.id)
        XCTAssertEqual(try store.loadAll().count, 0)
    }
}
