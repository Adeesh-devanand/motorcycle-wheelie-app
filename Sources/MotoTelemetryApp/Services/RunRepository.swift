import Foundation
import Observation
import os

/// File-backed repository for completed wheelie runs. Each run is stored as an
/// individual JSON file under `Documents/runs/<id>.json`, enabling incremental
/// writes and per-run export without loading the entire history into memory.
@Observable
final class RunRepository: @unchecked Sendable {

    // MARK: - Published

    private(set) var allRuns: [WheelieRun] = []
    private(set) var lastError: String?
    var deleteInterceptor: ((URL) throws -> Void)?

    // MARK: - Private

    private let runsDirectory: URL
    private let log = Logger(subsystem: "com.mototelemetry.app", category: "RunRepository")
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Init

    /// Test-only write interceptor. When set, it is invoked in place of the real
    /// `Data.write(to:)` inside `save`, so a test can force a persistence failure
    /// without filling the disk. `nil` in production — the `save` path is then
    /// byte-for-byte identical to before this seam existed. Introduced for the K02
    /// integration harness; do NOT rely on it from production code.
    var writeInterceptor: ((Data, URL) throws -> Void)?

    /// Production initializer: runs live under `Documents/runs`, exactly as before.
    /// The optional `runsDirectory` exists ONLY so the K02 integration harness can
    /// point the repository at an isolated temporary directory. When `nil` (the
    /// default, and the only value production ever passes) the path resolution is
    /// identical to the original hardcoded behaviour.
    init(runsDirectory: URL? = nil) {
        if let runsDirectory {
            self.runsDirectory = runsDirectory
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.runsDirectory = docs.appendingPathComponent("runs", isDirectory: true)
        }
        ensureDirectory()
        loadAll()
    }

    // MARK: - Queries

    func runsForBike(id bikeProfileID: UUID) -> [WheelieRun] {
        allRuns.filter { $0.configuration.calibrationID == bikeProfileID }
    }

    /// Personal bests by max angle, sorted descending.
    var personalBests: [WheelieRun] {
        allRuns.filter { $0.qualityFlags.isTrustworthy }.sorted { $0.maxAngle > $1.maxAngle }
    }

    /// Best run by max angle.
    var allTimeBest: WheelieRun? {
        allRuns.filter { $0.qualityFlags.isTrustworthy }.max { $0.maxAngle < $1.maxAngle }
    }

    /// Runs from the last N days.
    func recentRuns(days: Int = 7) -> [WheelieRun] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        return allRuns.filter { $0.startedAt >= cutoff }
            .sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: - Mutations

    @discardableResult
    func save(_ run: WheelieRun) -> Bool {
        do {
            let data = try encoder.encode(run)
            let fileURL = url(for: run.id)
            if let writeInterceptor {
                // K02 test seam: the interceptor stands in for the real write so a
                // harness can inject a failure. It throws to simulate a failed write;
                // on success it is responsible for the write (or a no-op the test
                // then verifies). nil in production — the `else` branch is the
                // original behaviour, unchanged.
                try writeInterceptor(data, fileURL)
            } else {
                try data.write(to: fileURL, options: .atomic)
            }
            allRuns.removeAll { $0.id == run.id }
            allRuns.append(run)
            allRuns.sort { $0.startedAt > $1.startedAt }
            log.info("Saved run \(run.id): \(run.maxAngle, format: .fixed(precision: 1))° max, \(run.duration, format: .fixed(precision: 1))s")
            lastError = nil
            return true
        } catch {
            lastError = "Could not save the attempt. Free storage and retry."
            log.error("Failed to save run \(run.id): \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func delete(id: UUID) -> Bool {
        let fileURL = url(for: id)
        do {
            if let deleteInterceptor { try deleteInterceptor(fileURL) }
            else if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            allRuns.removeAll { $0.id == id }
            lastError = nil
            return true
        } catch {
            lastError = "Some attempts could not be deleted. They remain in your history."
            log.error("Failed to delete run: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func deleteAll() -> Bool {
        let ids = allRuns.map(\.id)
        var succeeded = true
        for id in ids { if !delete(id: id) { succeeded = false } }
        if !succeeded { lastError = "Some attempts could not be deleted. They remain in your history." }
        return succeeded
    }

    // MARK: - Export

    /// Returns the JSON data for a single run, suitable for sharing.
    func exportData(for id: UUID) -> Data? {
        guard let run = allRuns.first(where: { $0.id == id }) else { return nil }
        return try? encoder.encode(run)
    }

    /// Returns the file URL for a run's JSON, for UIActivityViewController.
    func exportURL(for id: UUID) -> URL? {
        let fileURL = url(for: id)
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    // MARK: - Private

    private func url(for id: UUID) -> URL {
        runsDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private func ensureDirectory() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: runsDirectory.path) {
            do {
                try fm.createDirectory(at: runsDirectory, withIntermediateDirectories: true)
            } catch {
                log.error("Failed to create runs directory: \(error.localizedDescription)")
            }
        }
    }

    private func loadAll() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: runsDirectory,
                                                      includingPropertiesForKeys: nil) else {
            allRuns = []
            return
        }

        var loaded: [WheelieRun] = []
        var recoveredCount = 0
        var failedCount = 0
        for file in files where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                let run = try decoder.decode(WheelieRun.self, from: data)
                if run.qualityFlags.contains(.qualityRecordMissing) { recoveredCount += 1 }
                loaded.append(run)
            } catch {
                // Was `log.warning("Skipped corrupt run file: \(name)")` — a label that
                // named a CAUSE it had not established, and then swallowed the error
                // that would have disproved it. 27 files carried that message for three
                // sessions while the actual reason was one absent key. Report what the
                // decoder said, so the next schema break is diagnosable from the log
                // instead of from a guess.
                failedCount += 1
                log.warning("""
                    Could not read run file \(file.lastPathComponent, privacy: .public): \
                    \(Self.describe(error), privacy: .public)
                    """)
            }
        }

        allRuns = loaded.sorted { $0.startedAt > $1.startedAt }
        log.info("Loaded \(self.allRuns.count) runs from disk (\(recoveredCount) with no quality record, \(failedCount) unreadable)")
    }

    /// A short, greppable reason for a decode failure — the coding path and the kind of
    /// problem, which is what identifies a schema break. `localizedDescription` on a
    /// `DecodingError` returns a generic "data couldn't be read", naming neither.
    private static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else {
            return error.localizedDescription
        }
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map(\.stringValue).filter { !$0.isEmpty }
            return keys.isEmpty ? "<root>" : keys.joined(separator: ".")
        }
        switch decoding {
        case .keyNotFound(let key, let context):
            return "missing key '\(key.stringValue)' at \(path(context))"
        case .typeMismatch(let type, let context):
            return "type mismatch, expected \(type) at \(path(context))"
        case .valueNotFound(let type, let context):
            return "null where \(type) required at \(path(context))"
        case .dataCorrupted(let context):
            return "malformed JSON at \(path(context)): \(context.debugDescription)"
        @unknown default:
            return "unrecognized decoding error"
        }
    }
}
