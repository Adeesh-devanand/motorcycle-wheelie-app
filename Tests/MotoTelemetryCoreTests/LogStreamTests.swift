import XCTest
@testable import MotoTelemetryCore

final class LogStreamTests: XCTestCase {

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/pre-rename-session.ndjson")
    }

    private func makeTempLog(sampleCount: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stream-test-\(UUID().uuidString).ndjson")
        var out = Data()
        out.append(try LogFile.encodeHeader(LogHeader(sessionID: "stream-test")))
        var source = SyntheticSource()
        var written = 0
        while written < sampleCount {
            guard let sample = source.next() else {
                source = SyntheticSource()      // loop the scenario to reach the count
                continue
            }
            out.append(try LogFile.encode(sample))
            written += 1
        }
        try out.write(to: url)
        return url
    }

    func testStreamingMatchesWholeFileRead() throws {
        let (header, samples) = try LogFile.read(contentsOf: fixtureURL)

        var streamed: [Sample] = []
        let result = try LogFile.forEachSample(url: fixtureURL) { streamed.append($0) }

        XCTAssertEqual(result.header.sessionID, header.sessionID)
        XCTAssertEqual(result.header.config, header.config)
        XCTAssertEqual(result.count, samples.count)
        XCTAssertEqual(streamed.count, samples.count)
        XCTAssertFalse(result.endedMidLine)

        // Element-wise equality on the discriminating fields.
        for (a, b) in zip(streamed, samples) {
            XCTAssertEqual(a.time, b.time, accuracy: 0)
            switch (a, b) {
            case (.imu(let x), .imu(let y)):
                XCTAssertEqual(x.rotationRate, y.rotationRate)
                XCTAssertEqual(x.specificForce, y.specificForce)
                XCTAssertEqual(x.saturated, y.saturated)
                XCTAssertEqual(x.fusedAttitude, y.fusedAttitude)
            case (.gnss(let x), .gnss(let y)):
                XCTAssertEqual(x.fixTime, y.fixTime)
                XCTAssertEqual(x.arrivalTime, y.arrivalTime)
                XCTAssertEqual(x.speed, y.speed)
            case (.baro(let x), .baro(let y)):
                XCTAssertEqual(x.relativeAltitude, y.relativeAltitude)
            case (.wheelSpeed(let x), .wheelSpeed(let y)):
                XCTAssertEqual(x.cumulativeRevolutions, y.cumulativeRevolutions)
            default:
                XCTFail("case mismatch between streamed and whole-file read")
            }
        }
    }

    func testTinyChunkSizeStillReadsEverything() throws {
        // A chunk smaller than a single line exercises the remainder handling.
        var streamed = 0
        let result = try LogFile.forEachSample(url: fixtureURL, chunkSize: 7) { _ in
            streamed += 1
        }
        let (_, samples) = try LogFile.read(contentsOf: fixtureURL)
        XCTAssertEqual(streamed, samples.count)
        XCTAssertFalse(result.endedMidLine)
    }

    /// R4.2 — a force-quit leaves a partial trailing line. Only that line is lost.
    func testTruncatedTrailingLineIsReportedAndOnlyItIsLost() throws {
        let url = try makeTempLog(sampleCount: 300)
        defer { try? FileManager.default.removeItem(at: url) }

        let intact = try LogFile.forEachSample(url: url) { _ in }
        XCTAssertEqual(intact.count, 300)
        XCTAssertFalse(intact.endedMidLine)

        // Chop the last 12 bytes: the final JSON object is now unterminated.
        let data = try Data(contentsOf: url)
        let truncatedURL = url.appendingPathExtension("truncated")
        try data.subdata(in: 0..<(data.count - 12)).write(to: truncatedURL)
        defer { try? FileManager.default.removeItem(at: truncatedURL) }

        let repaired = try LogFile.forEachSample(url: truncatedURL) { _ in }
        XCTAssertTrue(repaired.endedMidLine,
                      "a crash signature must be reported, not swallowed")
        XCTAssertEqual(repaired.count, 299,
                       "exactly one sample may be lost to a truncated write")
    }

    func testEmptyFileThrowsEmptyLog() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString).ndjson")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try LogFile.forEachSample(url: url) { _ in }) { error in
            guard case LogStreamReader.Failure.emptyLog = error else {
                return XCTFail("expected emptyLog, got \(error)")
            }
        }
    }

    func testCorruptCompleteLineThrowsWithItsLineNumber() throws {
        let url = try makeTempLog(sampleCount: 10)
        defer { try? FileManager.default.removeItem(at: url) }

        var text = try String(contentsOf: url, encoding: .utf8)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        lines[3] = "{\"imu\":{\"_0\":{\"time\":\"not a number\"}}}"
        text = lines.joined(separator: "\n")
        let corruptURL = url.appendingPathExtension("corrupt")
        try text.write(to: corruptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: corruptURL) }

        XCTAssertThrowsError(try LogFile.forEachSample(url: corruptURL) { _ in }) { error in
            guard case LogStreamReader.Failure.badSample(let line, _) = error else {
                return XCTFail("expected badSample, got \(error)")
            }
            XCTAssertEqual(line, 4, "line number must point at the bad line")
        }
    }

    func testStreamingReplaySourceFeedsThePipelineShape() throws {
        var source = try StreamingReplaySource(url: fixtureURL)
        var imu = 0, gnss = 0
        while let sample = source.next() {
            switch sample {
            case .imu:  imu += 1
            case .gnss: gnss += 1
            default:    break
            }
        }
        XCTAssertNil(source.failure)
        XCTAssertGreaterThan(imu, 100)
        XCTAssertGreaterThan(gnss, 0)
    }

    /// R4.2 / D 15.3 — bounded memory. 180 000 samples is a 30-minute session at
    /// 100 Hz, the case that motivated this reader.
    func testMemoryStaysBoundedOverAFullSessionLengthLog() throws {
        let url = try makeTempLog(sampleCount: 180_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let fileSize = try FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(fileSize, 10_000_000, "expected a multi-MB log")

        let before = Self.currentResidentBytes()
        var count = 0
        let result = try LogFile.forEachSample(url: url) { _ in count += 1 }
        let after = Self.currentResidentBytes()

        XCTAssertEqual(result.count, 180_000)
        XCTAssertEqual(count, 180_000)

        if let before, let after {
            let growth = after - before
            print(String(format: "STREAMING: file %.1f MB, RSS growth %.2f MB",
                         Double(fileSize) / 1_048_576,
                         Double(growth) / 1_048_576))
            XCTAssertLessThan(growth, 20 * 1024 * 1024,
                String(format: "streaming grew RSS by %.1f MB; it must stay "
                       + "bounded regardless of file size (file was %.1f MB)",
                       Double(growth) / 1_048_576, Double(fileSize) / 1_048_576))
        }

        // The whole-file reader on the same log, for the comparison that motivated
        // this class. Not an assertion — a recorded number.
        let beforeWhole = Self.currentResidentBytes()
        let (_, all) = try LogFile.read(contentsOf: url)
        let afterWhole = Self.currentResidentBytes()
        XCTAssertEqual(all.count, 180_000)
        if let beforeWhole, let afterWhole {
            print(String(format: "WHOLE-FILE: RSS growth %.2f MB",
                         Double(afterWhole - beforeWhole) / 1_048_576))
        }
    }

    /// Reads current RSS on Linux. Returns nil elsewhere so the assertion above
    /// simply does not run on a platform without /proc.
    private static func currentResidentBytes() -> Int? {
        guard let status = try? String(contentsOfFile: "/proc/self/status",
                                      encoding: .utf8) else { return nil }
        for line in status.split(separator: "\n") where line.hasPrefix("VmRSS:") {
            let parts = line.split(separator: " ").compactMap { Int($0) }
            if let kb = parts.first { return kb * 1024 }
        }
        return nil
    }
}
