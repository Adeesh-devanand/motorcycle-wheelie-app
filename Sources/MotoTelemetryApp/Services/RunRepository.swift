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

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.runsDirectory = docs.appendingPathComponent("runs", isDirectory: true)
        ensureDirectory()
        loadAll()
    }

    // MARK: - Queries

    func runsForBike(id bikeProfileID: UUID) -> [WheelieRun] {
        allRuns.filter { $0.configuration.calibrationID == bikeProfileID }
    }

    /// Personal bests by max angle, sorted descending.
    var personalBests: [WheelieRun] {
        allRuns.sorted { $0.maxAngle > $1.maxAngle }
    }

    /// Best run by max angle.
    var allTimeBest: WheelieRun? {
        allRuns.max { $0.maxAngle < $1.maxAngle }
    }

    /// Runs from the last N days.
    func recentRuns(days: Int = 7) -> [WheelieRun] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        return allRuns.filter { $0.startedAt >= cutoff }
            .sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: - Mutations

    func save(_ run: WheelieRun) {
        do {
            let data = try encoder.encode(run)
            let fileURL = url(for: run.id)
            try data.write(to: fileURL, options: .atomic)
            allRuns.append(run)
            allRuns.sort { $0.startedAt > $1.startedAt }
            log.info("Saved run \(run.id): \(run.maxAngle, format: .fixed(precision: 1))° max, \(run.duration, format: .fixed(precision: 1))s")
        } catch {
            log.error("Failed to save run \(run.id): \(error.localizedDescription)")
        }
    }

    func delete(id: UUID) {
        let fileURL = url(for: id)
        do {
            try FileManager.default.removeItem(at: fileURL)
            allRuns.removeAll { $0.id == id }
            log.info("Deleted run \(id)")
        } catch {
            log.error("Failed to delete run \(id): \(error.localizedDescription)")
        }
    }

    func deleteAll() {
        for run in allRuns {
            try? FileManager.default.removeItem(at: url(for: run.id))
        }
        allRuns.removeAll()
        log.info("Deleted all runs")
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
        for file in files where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                let run = try decoder.decode(WheelieRun.self, from: data)
                loaded.append(run)
            } catch {
                log.warning("Skipped corrupt run file: \(file.lastPathComponent)")
            }
        }

        allRuns = loaded.sorted { $0.startedAt > $1.startedAt }
        log.info("Loaded \(self.allRuns.count) runs from disk")
    }
}
