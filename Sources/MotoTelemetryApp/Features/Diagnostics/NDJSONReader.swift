import Foundation

// MARK: - Parsed Log Line

/// One decoded NDJSON line in the contract's shape:
/// `{"t":123.456,"lvl":"info","cat":"gate","msg":"...","v":{...},"wall":"..."}`
///
/// Decoded DEFENSIVELY: a truncated final line is normal (the writer may be
/// mid-flush). Unparseable lines are skipped and counted, never crash, never
/// alarm. We do NOT depend on the writer's Swift types — we parse the JSON shape
/// the contract fixes.
struct LogLine: Identifiable, Equatable {
    enum Level: String, Comparable {
        case trace, debug, info, warn, error

        private var order: Int {
            switch self {
            case .trace: return 0
            case .debug: return 1
            case .info: return 2
            case .warn: return 3
            case .error: return 4
            }
        }
        static func < (lhs: Level, rhs: Level) -> Bool { lhs.order < rhs.order }

        /// Unknown / missing `lvl` sorts as info so it stays visible.
        init(raw: String?) {
            self = Level(rawValue: (raw ?? "").lowercased()) ?? .info
        }
    }

    let id = UUID()
    let time: Double
    let level: Level
    let category: String
    let message: String
    let values: [String: Double]
    /// Whether this line carried a header payload (first line of a session file).
    let isHeader: Bool
    let raw: [String: Any]

    static func == (lhs: LogLine, rhs: LogLine) -> Bool { lhs.id == rhs.id }

    /// `v` rendered compactly, keys sorted, e.g. "limit 10.10 · mag 9.81".
    var valuesCompact: String {
        values.keys.sorted().map { key in
            "\(key) \(LogLine.trim(values[key] ?? 0))"
        }.joined(separator: "  ·  ")
    }

    static func trim(_ d: Double) -> String {
        if d == d.rounded() && abs(d) < 1e9 {
            return String(Int(d))
        }
        return String(format: "%.3f", d).replacingOccurrences(
            of: #"0+$"#, with: "", options: .regularExpression
        ).replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }
}

// MARK: - NDJSON Reader

/// Reads NDJSON log files without loading the whole file into memory. All calls
/// here are blocking file I/O and MUST be invoked off the main thread by callers.
enum NDJSONReader {

    /// Result of a tail read: the parsed lines plus how many lines could not be
    /// parsed (surfaced quietly in the UI, per the contract's defensive rule).
    struct TailResult: Equatable {
        var lines: [LogLine]
        var skippedCount: Int
        var truncated: Bool   // true if the file had more lines than we read

        static func == (lhs: TailResult, rhs: TailResult) -> Bool {
            lhs.lines == rhs.lines && lhs.skippedCount == rhs.skippedCount && lhs.truncated == rhs.truncated
        }
    }

    /// Read the LAST `maxLines` lines by seeking from the END of the file in
    /// fixed-size chunks, so a 20 MB file never lands in memory. Returns the
    /// lines in file order (oldest-of-the-tail first).
    static func tail(url: URL, maxLines: Int = 500, chunkSize: Int = 64 * 1024) -> TailResult {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return TailResult(lines: [], skippedCount: 0, truncated: false)
        }
        defer { try? handle.close() }

        let fileSize: UInt64 = (try? handle.seekToEnd()) ?? 0
        if fileSize == 0 {
            return TailResult(lines: [], skippedCount: 0, truncated: false)
        }

        let newline = UInt8(0x0A)
        var buffer = Data()
        var offset: UInt64 = fileSize
        var newlineCount = 0
        var reachedStart = false

        // Walk backwards a chunk at a time until we've seen enough newlines.
        // We collect maxLines complete lines; one extra newline is tolerated so
        // a trailing '\n' does not cost us a line.
        while offset > 0 && newlineCount <= maxLines {
            let readLen = UInt64(chunkSize) <= offset ? UInt64(chunkSize) : offset
            offset -= readLen
            do {
                try handle.seek(toOffset: offset)
            } catch {
                break
            }
            guard let chunk = try? handle.read(upToCount: Int(readLen)), !chunk.isEmpty else {
                break
            }
            buffer.insert(contentsOf: chunk, at: 0)
            newlineCount += chunk.reduce(0) { $0 + ($1 == newline ? 1 : 0) }
            if offset == 0 { reachedStart = true }
        }

        // Split into lines, keep only the last maxLines.
        var rawLines = buffer.split(separator: newline, omittingEmptySubsequences: false)
            .map { Data($0) }
        // Drop a trailing empty element from a final newline.
        if rawLines.last?.isEmpty == true { rawLines.removeLast() }

        let truncated = !reachedStart || rawLines.count > maxLines
        if rawLines.count > maxLines {
            rawLines = Array(rawLines.suffix(maxLines))
        }

        var parsed: [LogLine] = []
        var skipped = 0
        for data in rawLines {
            if data.isEmpty { continue }
            if let line = decode(data) {
                parsed.append(line)
            } else {
                skipped += 1
            }
        }
        return TailResult(lines: parsed, skippedCount: skipped, truncated: truncated)
    }

    /// Read EVERY line of a file for full-session parsing (summary card). Still
    /// streams line by line rather than materialising typed objects eagerly.
    /// Must be called off the main thread.
    static func allLines(url: URL) -> TailResult {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return TailResult(lines: [], skippedCount: 0, truncated: false)
        }
        let newline = UInt8(0x0A)
        var parsed: [LogLine] = []
        var skipped = 0
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: newline) ?? data.endIndex
            let slice = data[start..<end]
            if !slice.isEmpty {
                if let line = decode(Data(slice)) {
                    parsed.append(line)
                } else {
                    skipped += 1
                }
            }
            start = end < data.endIndex ? data.index(after: end) : data.endIndex
        }
        return TailResult(lines: parsed, skippedCount: skipped, truncated: false)
    }

    // MARK: - Defensive decode

    /// Decode one NDJSON object into a LogLine. Returns nil for anything that is
    /// not a well-formed object (a truncated mid-flush final line, a header we
    /// still surface, or garbage) — the caller counts nils, never crashes.
    static func decode(_ data: Data) -> LogLine? {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            return nil
        }

        // A session header line has no `lvl`/`cat` but carries config/device
        // fields. We still surface it so the viewer shows the header row.
        let hasEventShape = dict["lvl"] != nil || dict["msg"] != nil
        let isHeader = !hasEventShape && (dict["config"] != nil || dict["device"] != nil
            || dict["appBuild"] != nil || dict["logFormatVersion"] != nil || dict["ios"] != nil)

        if !hasEventShape && !isHeader {
            // Not a shape we recognise — treat as unparseable so it is counted.
            return nil
        }

        let time = (dict["t"] as? Double) ?? (dict["t"] as? NSNumber)?.doubleValue ?? 0
        let level = LogLine.Level(raw: dict["lvl"] as? String)
        let category = (dict["cat"] as? String) ?? (isHeader ? "header" : "")
        let message: String
        if isHeader {
            message = "session header"
        } else {
            message = (dict["msg"] as? String) ?? ""
        }

        var values: [String: Double] = [:]
        if let v = dict["v"] as? [String: Any] {
            for (k, raw) in v {
                if let d = raw as? Double { values[k] = d }
                else if let n = raw as? NSNumber { values[k] = n.doubleValue }
            }
        }

        return LogLine(
            time: time,
            level: level,
            category: category,
            message: message,
            values: values,
            isHeader: isHeader,
            raw: dict
        )
    }
}
