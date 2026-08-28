import Foundation

// MARK: - Log File Kinds

/// The two on-disk log kinds defined by the logging contract. We classify from
/// the filename prefix only, so there is ZERO source-level dependency on whoever
/// writes the files — we never reference the writer's types.
enum LogFileKind: String {
    /// `session-<yyyyMMdd-HHmmss>.ndjson` — structured DiagnosticEvent stream.
    case session
    /// `raw-<yyyyMMdd-HHmmss>.ndjson` — raw sensor trace.
    case raw
    /// Any other file that happens to live in the logs directory.
    case other

    var displayName: String {
        switch self {
        case .session: return "Session"
        case .raw: return "Raw sensor"
        case .other: return "File"
        }
    }
}

// MARK: - Log File Entry

/// One enumerated file in the logs directory. Value type, `Identifiable` by URL
/// so a SwiftUI list can diff it without any dependency on the writer.
struct LogFileEntry: Identifiable, Equatable {
    let url: URL
    let name: String
    let byteCount: Int64
    let modifiedDate: Date
    let kind: LogFileKind

    var id: URL { url }

    /// Human-formatted size, e.g. "2.4 MB". Uses the file byte-count style.
    var sizeText: String {
        LogFileBrowser.formatBytes(byteCount)
    }
}

// MARK: - LogFileBrowser

/// Pure-Foundation enumeration of `<Documents>/logs/`. No UIKit, no SwiftUI, no
/// dependency on the log writer — unit-testable in isolation.
///
/// The directory may not exist yet (the writer creates it lazily). In that case
/// we return an empty snapshot and DO NOT create the directory: showing an empty
/// state is correct, creating noise is not.
struct LogFileBrowser {

    /// A single point-in-time reading of the logs directory.
    struct Snapshot: Equatable {
        var files: [LogFileEntry]
        var totalBytes: Int64

        static let empty = Snapshot(files: [], totalBytes: 0)

        var totalBytesText: String { LogFileBrowser.formatBytes(totalBytes) }
        var isEmpty: Bool { files.isEmpty }
    }

    /// ~100 MB soft ceiling from the contract; above this the UI shows a note.
    static let softSizeLimitBytes: Int64 = 100 * 1024 * 1024

    /// The `<Documents>/logs/` directory URL. Does not create it.
    static var logsDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("logs", isDirectory: true)
    }

    let directory: URL

    init(directory: URL = LogFileBrowser.logsDirectory) {
        self.directory = directory
    }

    /// Enumerate the directory, newest first. Never throws: a missing directory
    /// or an unreadable entry yields an empty / partial snapshot rather than an
    /// error, because this is a diagnostics screen and must not itself fail.
    func snapshot(fileManager: FileManager = .default) -> Snapshot {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return .empty
        }

        var entries: [LogFileEntry] = []
        var total: Int64 = 0

        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == false { continue }

            let size = Int64(values?.fileSize ?? 0)
            let modified = values?.contentModificationDate ?? .distantPast
            let entry = LogFileEntry(
                url: url,
                name: url.lastPathComponent,
                byteCount: size,
                modifiedDate: modified,
                kind: Self.classify(url.lastPathComponent)
            )
            entries.append(entry)
            total += size
        }

        entries.sort { $0.modifiedDate > $1.modifiedDate }
        return Snapshot(files: entries, totalBytes: total)
    }

    /// Newest file of a given kind, if any (snapshot is already newest-first).
    func newest(_ kind: LogFileKind, in snapshot: Snapshot) -> LogFileEntry? {
        snapshot.files.first { $0.kind == kind }
    }

    // MARK: - Classification

    /// Kind from the filename prefix only — this is the sole thing the contract
    /// lets us assume about the writer.
    static func classify(_ name: String) -> LogFileKind {
        let lower = name.lowercased()
        if lower.hasPrefix("session-") { return .session }
        if lower.hasPrefix("raw-") { return .raw }
        return .other
    }

    // MARK: - Formatting

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f
    }()

    static func formatBytes(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: bytes)
    }
}
