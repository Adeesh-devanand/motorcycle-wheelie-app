import Foundation
import MotoTelemetryCore
import os

/// Writes raw samples to an NDJSON session log with bounded latency.
///
/// Design constraints:
/// - SPSC ring buffer (sensor callback → disk writer), capacity from Config.
/// - Overwrite is FORBIDDEN: a full buffer increments `dropCount` and the
///   sample is lost. This surfaces in the integrity report; zero drops is the
///   contract for a trusted session.
/// - Batched O_APPEND writes; fsync every `config.fsyncInterval` so a force-quit
///   loses at most 1 second.
/// - Atomic manifest: write to temp, then rename.
///
/// Session directory layout:
///   <sessionID>/
///     samples.ndjson   — header + raw samples
///     manifest.json    — metadata, sizes, completion flag
///     audio.caf        — optional external mic recording
public actor SessionWriter {

    // MARK: - Public state

    public private(set) var dropCount: Int = 0
    public private(set) var sampleCount: Int = 0
    public private(set) var meanEnqueueLatency: TimeInterval = 0
    public private(set) var maxEnqueueLatency: TimeInterval = 0

    // MARK: - Private

    private let config: Config
    private let sessionDir: URL
    private let samplesURL: URL
    private let manifestURL: URL
    private let fileHandle: FileHandle
    private let log = Logger(subsystem: "com.mototelemetry.app", category: "SessionWriter")

    private let capacity: Int
    private var ring: [Data?]
    private var head: Int = 0  // next write position (producer)
    private var tail: Int = 0  // next read position (consumer)
    private var count: Int = 0 // items in ring

    private var lastFsync: TimeInterval = 0
    private var totalEnqueueLatency: TimeInterval = 0

    private var flushTask: Task<Void, Never>?

    // MARK: - Manifest

    private struct Manifest: Codable {
        var sessionID: String
        var startedAt: Date
        var sampleCount: Int
        var dropCount: Int
        var bytesWritten: Int64
        var complete: Bool
        var recovered: Bool
    }

    private var manifest: Manifest
    private let encoder = JSONEncoder()

    // MARK: - Init

    /// Creates a new session directory and opens the samples file.
    public init(sessionID: String, header: LogHeader, config: Config = Config()) throws {
        self.config = config
        self.capacity = config.writerRingCapacity

        // Session directory
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.sessionDir = docs.appendingPathComponent("Sessions/\(sessionID)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        self.samplesURL = sessionDir.appendingPathComponent("samples.ndjson")
        self.manifestURL = sessionDir.appendingPathComponent("manifest.json")

        // Write header
        let headerData = try LogFile.encodeHeader(header)
        try headerData.write(to: samplesURL)

        self.fileHandle = try FileHandle(forWritingTo: samplesURL)
        fileHandle.seekToEndOfFile()

        // Ring buffer
        self.ring = [Data?](repeating: nil, count: capacity)

        // Initial manifest
        self.manifest = Manifest(
            sessionID: sessionID,
            startedAt: header.startedAt,
            sampleCount: 0,
            dropCount: 0,
            bytesWritten: Int64(headerData.count),
            complete: false,
            recovered: false
        )

        self.encoder.outputFormatting = []

        log.info("SessionWriter opened: \(sessionID), ring capacity: \(self.capacity)")
    }

    // MARK: - Write

    /// Enqueue a sample. Called from the sensor callback path; must be fast.
    public func write(_ sample: Sample) {
        let start = ProcessInfo.processInfo.systemUptime

        if count >= capacity {
            // FORBIDDEN overwrite — drop
            dropCount += 1
            manifest.dropCount = dropCount
            log.warning("Ring full, dropped sample. Total drops: \(self.dropCount)")
            return
        }

        do {
            let data = try LogFile.encode(sample)
            ring[head] = data
            head = (head + 1) % capacity
            count += 1
            sampleCount += 1
        } catch {
            log.error("Encode failed: \(error.localizedDescription)")
            return
        }

        // Latency tracking
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        totalEnqueueLatency += elapsed
        meanEnqueueLatency = totalEnqueueLatency / Double(sampleCount)
        if elapsed > maxEnqueueLatency { maxEnqueueLatency = elapsed }

        // Drain if fsync interval elapsed
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastFsync >= config.fsyncInterval {
            drainAndSync()
        }
    }

    // MARK: - Flush

    /// Force-drain the ring and fsync. Call at session end.
    public func flush() {
        drainAndSync()
        writeManifest(complete: true)
        try? fileHandle.close()
        log.info("SessionWriter flushed. Samples: \(self.sampleCount), Drops: \(self.dropCount)")
    }

    // MARK: - Internals

    private func drainAndSync() {
        var batch = Data()
        while count > 0 {
            if let data = ring[tail] {
                batch.append(data)
                ring[tail] = nil
            }
            tail = (tail + 1) % capacity
            count -= 1
        }

        guard !batch.isEmpty else { return }

        fileHandle.write(batch)
        // fsync via file descriptor
        let fd = fileHandle.fileDescriptor
        Darwin.fsync(fd)
        lastFsync = ProcessInfo.processInfo.systemUptime

        manifest.sampleCount = sampleCount
        manifest.bytesWritten += Int64(batch.count)

        writeManifest(complete: false)
    }

    private func writeManifest(complete: Bool) {
        manifest.complete = complete
        do {
            let data = try encoder.encode(manifest)
            let tempURL = sessionDir.appendingPathComponent("manifest.json.tmp")
            try data.write(to: tempURL, options: .atomic)
            // Atomic rename
            _ = try FileManager.default.replaceItemAt(manifestURL, withItemAt: tempURL)
        } catch {
            // Fallback: direct write (non-atomic but better than nothing)
            if let data = try? encoder.encode(manifest) {
                try? data.write(to: manifestURL)
            }
            log.error("Manifest write failed: \(error.localizedDescription)")
        }
    }
}
