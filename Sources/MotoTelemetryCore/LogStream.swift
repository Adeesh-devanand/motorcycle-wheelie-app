import Foundation

/// Bounded-memory reader for an NDJSON session log.
///
/// `LogFile.read(contentsOf:)` loads the whole file into a `String`, which is
/// fine for its documented case and for tests but wrong for three jobs the app
/// has: repairing a truncated file after a crash, hydrating one event's span out
/// of a half-hour session, and running the smoother over a window. This reader
/// holds one chunk plus one line at a time regardless of file size.
///
/// It also reports whether the file ended mid-line, which is exactly what
/// crash recovery needs to know: a session killed by a force-quit ends with a
/// partial JSON object, and that line — and only that line — must be discarded.
public struct LogStreamReader {

    public enum Failure: Error, CustomStringConvertible {
        case emptyLog
        case badHeader(underlying: Error)
        case badSample(line: Int, underlying: Error)

        public var description: String {
            switch self {
            case .emptyLog:
                return "log contains no header line"
            case .badHeader(let e):
                return "header line is not decodable: \(e)"
            case .badSample(let line, let e):
                return "sample on line \(line) is not decodable: \(e)"
            }
        }
    }

    public let header: LogHeader

    /// True when the file's final line had no terminating newline, i.e. writing
    /// was interrupted. The reader stops before that line rather than failing.
    public private(set) var endedMidLine = false

    /// Number of sample lines successfully decoded.
    public private(set) var decodedCount = 0

    /// Byte offset just past the last complete line. A repair truncates here.
    public private(set) var lastCompleteOffset: Int = 0

    private let handle: FileHandle
    private let chunkSize: Int
    private var buffer = Data()
    private var pendingLines: [Data] = []
    private var pendingIndex = 0
    private var reachedEOF = false
    private var lineNumber = 1              // header is line 1
    private let decoder = JSONDecoder()

    public init(url: URL, chunkSize: Int = 64 * 1024) throws {
        self.handle = try FileHandle(forReadingFrom: url)
        self.chunkSize = chunkSize

        // The header is the first line; read only as far as needed to get it.
        var headerLine: Data?
        while headerLine == nil {
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                break
            }
            buffer.append(chunk)
            if let newline = buffer.firstIndex(of: 0x0A) {
                headerLine = buffer[buffer.startIndex..<newline]
                let consumed = newline - buffer.startIndex + 1
                buffer = buffer.subdata(in: newline + 1..<buffer.endIndex)
                lastCompleteOffset = consumed
            }
        }
        guard let line = headerLine, !line.isEmpty else {
            try? handle.close()
            throw Failure.emptyLog
        }
        do {
            self.header = try decoder.decode(LogHeader.self, from: line)
        } catch {
            try? handle.close()
            throw Failure.badHeader(underlying: error)
        }

        // Whatever followed the header inside that first chunk is already in the
        // buffer and must be queued now. Forgetting this makes a log that fits
        // entirely in one chunk look like a single unterminated line, i.e. an
        // empty session with a false crash signature.
        splitCompleteLines()
    }

    /// Next sample, or nil at end of file. Throws on a malformed COMPLETE line;
    /// a malformed trailing PARTIAL line is reported through `endedMidLine`
    /// instead, because that is a crash artefact rather than corruption.
    public mutating func next() throws -> Sample? {
        while true {
            if pendingIndex < pendingLines.count {
                let line = pendingLines[pendingIndex]
                pendingIndex += 1
                lineNumber += 1
                lastCompleteOffset += line.count + 1
                if line.isEmpty { continue }
                do {
                    let sample = try decoder.decode(Sample.self, from: line)
                    decodedCount += 1
                    return sample
                } catch {
                    throw Failure.badSample(line: lineNumber, underlying: error)
                }
            }

            pendingLines.removeAll(keepingCapacity: true)
            pendingIndex = 0

            if reachedEOF {
                // Whatever remains has no terminating newline.
                if !buffer.isEmpty {
                    endedMidLine = true
                    buffer.removeAll(keepingCapacity: false)
                }
                return nil
            }

            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                reachedEOF = true
                continue
            }
            buffer.append(chunk)
            splitCompleteLines()
        }
    }

    /// Moves every complete line out of `buffer` into `pendingLines`, leaving the
    /// unterminated remainder behind. This is what bounds memory: the buffer never
    /// exceeds one chunk plus one line.
    private mutating func splitCompleteLines() {
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            pendingLines.append(buffer[start..<newline])
            start = newline + 1
        }
        if start > buffer.startIndex {
            buffer = buffer.subdata(in: start..<buffer.endIndex)
        }
    }

    public mutating func close() {
        try? handle.close()
    }
}

extension LogFile {
    /// Streaming counterpart to `read(contentsOf:)`. Prefer this on device.
    public static func stream(url: URL, chunkSize: Int = 64 * 1024) throws -> LogStreamReader {
        try LogStreamReader(url: url, chunkSize: chunkSize)
    }

    /// Reads a log with bounded memory, invoking `body` per sample. Returns the
    /// header and whether the file ended mid-line (a crash signature).
    @discardableResult
    public static func forEachSample(
        url: URL,
        chunkSize: Int = 64 * 1024,
        _ body: (Sample) throws -> Void
    ) throws -> (header: LogHeader, endedMidLine: Bool, count: Int) {
        var reader = try LogStreamReader(url: url, chunkSize: chunkSize)
        defer { reader.close() }
        while let sample = try reader.next() {
            try body(sample)
        }
        return (reader.header, reader.endedMidLine, reader.decodedCount)
    }
}

/// A `MeasurementSource` backed by the streaming reader, for feeding the pipeline
/// straight off disk without materialising the session.
///
/// `MeasurementSource.next()` cannot throw, so a decode failure is captured in
/// `failure` and the stream ends. Callers that care must check it — silently
/// truncating a replay would make a corrupt log look like a short ride.
public struct StreamingReplaySource: MeasurementSource {
    private var reader: LogStreamReader
    public private(set) var failure: Error?

    public var header: LogHeader { reader.header }
    public var endedMidLine: Bool { reader.endedMidLine }

    public init(url: URL, chunkSize: Int = 64 * 1024) throws {
        self.reader = try LogStreamReader(url: url, chunkSize: chunkSize)
    }

    public mutating func next() -> Sample? {
        guard failure == nil else { return nil }
        do {
            return try reader.next()
        } catch {
            failure = error
            return nil
        }
    }
}
