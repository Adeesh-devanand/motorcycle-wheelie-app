import Foundation

/// Newline-delimited JSON. One header line, then one measurement per line in
/// monotonic time order.
///
/// The log is RAW and unfiltered by contract. Everything downstream is derived
/// and can be recomputed forever from this file. Filter or downsample before
/// writing and you have destroyed the aliasing evidence and your ability to
/// re-tune anything without another ride.
public struct LogHeader: Codable, Sendable {
    public var formatVersion: Int = 1
    public var sessionID: String
    public var startedAt: Date
    public var deviceModel: String
    public var appVersion: String
    /// The exact parameters that produced this log.
    public var config: Config
    /// Free-text notes and manual event tags added during the ride.
    public var notes: String

    public init(sessionID: String = UUID().uuidString,
                startedAt: Date = Date(),
                deviceModel: String = "unknown",
                appVersion: String = "0.0.0",
                config: Config = Config(),
                notes: String = "") {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.deviceModel = deviceModel
        self.appVersion = appVersion
        self.config = config
        self.notes = notes
    }
}

public enum LogFile {
    public static func encodeHeader(_ h: LogHeader) throws -> Data {
        var d = try JSONEncoder().encode(h)
        d.append(0x0A)
        return d
    }

    public static func encode(_ m: Sample) throws -> Data {
        var d = try JSONEncoder().encode(m)
        d.append(0x0A)
        return d
    }

    /// Reads a whole log into memory. Fine for a 30 min session (~16 KB/s);
    /// switch to streaming if sessions get long.
    public static func read(contentsOf url: URL) throws -> (LogHeader, [Sample]) {
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard let headerLine = lines.first else {
            throw NSError(domain: "LogFile", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "empty log"])
        }
        lines.removeFirst()
        let dec = JSONDecoder()
        let header = try dec.decode(LogHeader.self, from: Data(headerLine.utf8))
        let items = try lines.map { try dec.decode(Sample.self, from: Data($0.utf8)) }
        return (header, items)
    }
}

/// Replays a log through the pipeline. Orders on FIX time, not arrival time,
/// so a run on your desk is identical to the ride that produced it.
public struct ReplaySource: MeasurementSource {
    private var items: [Sample]
    private var index = 0

    public init(samples: [Sample]) {
        self.items = samples.sorted { $0.time < $1.time }
    }

    public mutating func next() -> Sample? {
        guard index < items.count else { return nil }
        defer { index += 1 }
        return items[index]
    }
}
