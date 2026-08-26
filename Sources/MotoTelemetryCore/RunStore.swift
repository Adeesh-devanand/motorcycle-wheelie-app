import Foundation

// MARK: - Run Record Models

/// A single display-ready sample point for chart rendering (~30 Hz decimated).
public struct DisplayPoint: Codable, Sendable, Equatable {
    /// Elapsed time since event onset, seconds.
    public var elapsed: TimeInterval
    /// Pitch angle in radians.
    public var pitch: Double
    /// Speed in m/s, nil when GNSS unavailable.
    public var speed: Double?

    public init(elapsed: TimeInterval, pitch: Double, speed: Double? = nil) {
        self.elapsed = elapsed
        self.pitch = pitch
        self.speed = speed
    }
}

/// Time span of a session.
public struct SessionSpan: Codable, Sendable, Equatable {
    public var sessionID: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval

    public init(sessionID: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.sessionID = sessionID
        self.startTime = startTime
        self.endTime = endTime
    }
}

/// A time interval represented as start/end pair (for angle/speed in-range intervals).
public struct TimeSpan: Codable, Sendable, Equatable {
    public var start: TimeInterval
    public var end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }
}

/// Complete persisted record of a single wheelie event (design §13).
public struct RunRecord: Codable, Sendable, Equatable {
    public var id: UUID
    public var sessionID: String
    public var span: SessionSpan
    public var metrics: EventMetrics
    public var display: [DisplayPoint]
    public var angleIntervals: [TimeSpan]
    public var speedIntervals: [TimeSpan]
    public var snapshot: TargetSnapshot
    public var configVersion: Int
    public var flags: QualityFlags

    public init(
        id: UUID = UUID(),
        sessionID: String,
        span: SessionSpan,
        metrics: EventMetrics,
        display: [DisplayPoint],
        angleIntervals: [TimeSpan],
        speedIntervals: [TimeSpan],
        snapshot: TargetSnapshot,
        configVersion: Int,
        flags: QualityFlags
    ) {
        self.id = id
        self.sessionID = sessionID
        self.span = span
        self.metrics = metrics
        self.display = display
        self.angleIntervals = angleIntervals
        self.speedIntervals = speedIntervals
        self.snapshot = snapshot
        self.configVersion = configVersion
        self.flags = flags
    }
}

// MARK: - Run Store

/// Atomic run persistence per design §15.1 / R10.8.
///
/// Writes via temp file + rename(2) so a crash during persistence leaves either
/// no run file or a complete one — never a partial. Pure Foundation, no platform
/// imports.
public struct RunStore {
    /// Directory where run records are stored.
    public let directory: URL

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    public init(directory: URL) {
        self.directory = directory
    }

    // MARK: - Write

    /// Atomically persist a RunRecord. A crash at any point leaves the store
    /// consistent: either the old state or the new file, never partial.
    public func save(_ record: RunRecord) throws {
        // Ensure directory exists.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let data = try encoder.encode(record)
        let finalURL = directory.appendingPathComponent("\(record.id.uuidString).json")

        // Write to a temporary file in the same directory (same filesystem)
        // so rename(2) is atomic.
        let tempURL = directory.appendingPathComponent(".\(record.id.uuidString).tmp")

        // Clean up any leftover temp from a prior crash.
        try? FileManager.default.removeItem(at: tempURL)

        try data.write(to: tempURL, options: .atomic)

        // rename(2) is atomic on POSIX when src and dst are on the same filesystem.
        // FileManager.moveItem uses rename(2) under the hood.
        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: finalURL)
    }

    // MARK: - Read

    /// Load a single RunRecord by ID.
    public func load(id: UUID) throws -> RunRecord {
        let url = directory.appendingPathComponent("\(id.uuidString).json")
        let data = try Data(contentsOf: url)
        return try decoder.decode(RunRecord.self, from: data)
    }

    /// Load all RunRecords from the store directory.
    /// Skips files that cannot be decoded (partial writes from prior crashes
    /// that left temp files, or future format versions).
    public func loadAll() throws -> [RunRecord] {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        var records: [RunRecord] = []
        for url in contents where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url),
               let record = try? decoder.decode(RunRecord.self, from: data) {
                records.append(record)
            }
        }
        return records
    }

    // MARK: - Delete

    /// Remove a single run record by ID.
    public func delete(id: UUID) throws {
        let url = directory.appendingPathComponent("\(id.uuidString).json")
        try FileManager.default.removeItem(at: url)
    }

    /// Remove all run records.
    public func deleteAll() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )
        for url in contents where url.pathExtension == "json" || url.pathExtension == "tmp" {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
