import Foundation
import MotoTelemetryCore
import os

/// Recovers sessions interrupted by a force-quit or crash.
///
/// On launch, scans the Sessions directory for any session whose manifest lacks
/// `"complete": true`. For each:
/// 1. Drops the trailing partial line from samples.ndjson (if any).
/// 2. Recomputes the actual byte size.
/// 3. Marks the manifest `recovered: true` and updates `sampleCount`.
///
/// Guarantees: a force-quit loses at most 1 second of data (bounded by the
/// writer's fsync interval), and never corrupts previously-synced samples.
public struct SessionRecovery {

    private let log = Logger(subsystem: "com.mototelemetry.app", category: "SessionRecovery")

    // MARK: - Manifest (matches SessionWriter's layout)

    private struct Manifest: Codable {
        var sessionID: String
        var startedAt: Date
        var sampleCount: Int
        var dropCount: Int
        var bytesWritten: Int64
        var complete: Bool
        var recovered: Bool
    }

    // MARK: - Public

    public struct RecoveryResult: Sendable {
        public let sessionID: String
        public let linesRecovered: Int
        public let linesTruncated: Int
        public let wasAlreadyComplete: Bool
    }

    public init() {}

    /// Scans all sessions and repairs incomplete ones. Safe to call on every launch.
    public func recoverAll() -> [RecoveryResult] {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let sessionsDir = docs.appendingPathComponent("Sessions", isDirectory: true)

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: nil
        ) else {
            log.info("No Sessions directory found; nothing to recover")
            return []
        }

        var results: [RecoveryResult] = []

        for dir in contents where dir.hasDirectoryPath {
            let sessionID = dir.lastPathComponent
            let result = recover(sessionDir: dir, sessionID: sessionID)
            results.append(result)
        }

        let incomplete = results.filter { !$0.wasAlreadyComplete }
        if !incomplete.isEmpty {
            log.warning("Recovered \(incomplete.count) incomplete session(s)")
        }

        return results
    }

    // MARK: - Per-session recovery

    private func recover(sessionDir: URL, sessionID: String) -> RecoveryResult {
        let manifestURL = sessionDir.appendingPathComponent("manifest.json")
        let samplesURL = sessionDir.appendingPathComponent("samples.ndjson")

        // Read manifest
        guard let manifestData = try? Data(contentsOf: manifestURL),
              var manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData) else {
            log.error("Cannot read manifest for session \(sessionID)")
            return RecoveryResult(sessionID: sessionID, linesRecovered: 0,
                                  linesTruncated: 0, wasAlreadyComplete: false)
        }

        // Already complete — skip
        if manifest.complete {
            return RecoveryResult(sessionID: sessionID, linesRecovered: 0,
                                  linesTruncated: 0, wasAlreadyComplete: true)
        }

        // Repair samples file: drop trailing partial line
        guard var samplesData = try? Data(contentsOf: samplesURL) else {
            log.error("Cannot read samples.ndjson for session \(sessionID)")
            return RecoveryResult(sessionID: sessionID, linesRecovered: 0,
                                  linesTruncated: 0, wasAlreadyComplete: false)
        }

        let originalSize = samplesData.count
        var truncatedLines = 0

        // If the file doesn't end with newline, the last line is partial — drop it
        if !samplesData.isEmpty && samplesData.last != 0x0A {
            // Find last newline
            if let lastNewline = samplesData.lastIndex(of: 0x0A) {
                let removed = samplesData.count - lastNewline - 1
                samplesData = samplesData[..<(lastNewline + 1)]
                truncatedLines = 1
                log.info("Truncated \(removed) bytes (partial trailing line) from \(sessionID)")
            }
        }

        // Count valid sample lines (first line is header)
        let lineCount = samplesData.withUnsafeBytes { buffer -> Int {
            buffer.reduce(0) { count, byte in count + (byte == 0x0A ? 1 : 0) }
        }
        let sampleLines = max(0, lineCount - 1) // subtract header

        // Write repaired file if truncated
        if truncatedLines > 0 {
            do {
                try samplesData.write(to: samplesURL, options: .atomic)
            } catch {
                log.error("Failed to write repaired samples for \(sessionID): \(error.localizedDescription)")
            }
        }

        // Update manifest
        manifest.sampleCount = sampleLines
        manifest.bytesWritten = Int64(samplesData.count)
        manifest.recovered = true
        // Do NOT mark complete — the session was interrupted, not finished.

        do {
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            log.error("Failed to write recovered manifest for \(sessionID): \(error.localizedDescription)")
        }

        log.info("Recovered session \(sessionID): \(sampleLines) samples, \(truncatedLines) lines truncated")

        return RecoveryResult(
            sessionID: sessionID,
            linesRecovered: sampleLines,
            linesTruncated: truncatedLines,
            wasAlreadyComplete: false
        )
    }
}
