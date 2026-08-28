import Foundation
import MotoTelemetryCore

/// Records the RAW, unprocessed sensor stream — every `IMUSample` and `GNSSFix`
/// exactly as it arrives, at full rate — to `<Documents>/logs/raw-<stamp>.ndjson`,
/// so a bad ride is replayable on the desk.
///
/// ## motolog compatibility (VERIFIED against the core wire format)
///
/// The file is written with **the core `LogFile` encoder itself**: a first line
/// from `LogFile.encodeHeader(LogHeader)`, then one line per `Sample` from
/// `LogFile.encode(Sample)`. That is byte-for-byte the format `LogFile.read`,
/// `LogStreamReader`, `ReplaySource` and `StreamingReplaySource` consume, which is
/// exactly what `motolog` replays. No custom format, no divergence: a `raw-*.ndjson`
/// file drops straight into `motolog` and the pipeline replays it identically to
/// the ride that produced it (`ReplaySource` orders on `Sample.time`).
///
/// This is deliberately NOT the structured `DiagnosticLog` NDJSON — that format is
/// for human/greppable diagnostics; this one is the machine-replayable raw trace,
/// and keeping them separate is what lets `motolog` read this without knowing about
/// the diagnostic sink at all.
///
/// ## Threading
///
/// `record(_:)` is called from the sensor path (via `RunRecorder.processSample`,
/// under its `processLock`). It only appends the pre-encoded bytes into a bounded
/// buffer under a lock; a background serial queue flushes ~every 0.5 s. Encoding
/// (`JSONEncoder`) is cheap and done inline, but no file I/O ever touches the
/// sensor thread.
final class RawSampleRecorder: @unchecked Sendable {

    // MARK: - Tuning

    private let flushInterval: TimeInterval = 0.5
    /// ~120 bytes/sample × 100 Hz × 0.5 s ≈ 6 KB per flush; the cap bounds a stalled
    /// disk to a few seconds of samples before dropping and counting.
    private let maxBufferedChunks = 4_000

    // MARK: - Public

    let fileURL: URL
    /// Current on-disk size in bytes, surfaced so the UI can show how much a ride
    /// is costing. Updated on each flush.
    private(set) var fileSizeBytes: UInt64 = 0
    private(set) var droppedSamples = 0

    // MARK: - Private

    private var buffer: [Data] = []
    private let bufferLock = NSLock()
    private let flushQueue = DispatchQueue(label: "com.mototelemetry.rawrec.flush", qos: .utility)
    private var timerSource: DispatchSourceTimer?
    private var handle: FileHandle?
    private let encoder = JSONEncoder()

    // MARK: - Init

    /// - Parameters:
    ///   - config: the exact `Config` in force, stored in the header so a replay
    ///     runs under the same parameters that produced the trace.
    ///   - bikeProfileID: recorded in the header notes for provenance.
    init(config: Config, bikeProfileID: UUID) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let stamp = Self.stamp()
        self.fileURL = dir.appendingPathComponent("raw-\(stamp).ndjson")

        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        self.handle = try? FileHandle(forWritingTo: fileURL)

        // Header uses the core type verbatim, so motolog decodes it as-is.
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        var sys = utsname(); uname(&sys)
        let machine = withUnsafePointer(to: &sys.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        let header = LogHeader(
            sessionID: UUID().uuidString,
            startedAt: Date(),
            deviceModel: machine,
            appVersion: version,
            config: config,
            notes: "raw device trace; bikeProfileID=\(bikeProfileID.uuidString)"
        )
        if let headerData = try? LogFile.encodeHeader(header) {
            handle?.write(headerData)
            fileSizeBytes = UInt64(headerData.count)
        }

        startTimer()
    }

    // MARK: - Recording

    /// Encode and buffer one raw sample. Called on the sensor path — never blocks
    /// on I/O. Uses the core `LogFile.encode`, so the bytes are wire-identical to a
    /// live session log.
    func record(_ sample: Sample) {
        guard let data = try? LogFile.encode(sample) else { return }
        bufferLock.lock()
        if buffer.count >= maxBufferedChunks {
            droppedSamples += 1
            bufferLock.unlock()
            return
        }
        buffer.append(data)
        bufferLock.unlock()
    }

    /// Synchronously drain to disk (call on stop / background).
    func flush() {
        flushQueue.sync { self.drain() }
    }

    /// Stop recording and close the file.
    func finish() {
        timerSource?.cancel()
        timerSource = nil
        flush()
        flushQueue.sync {
            self.handle?.synchronizeFile()
            try? self.handle?.close()
            self.handle = nil
        }
    }

    // MARK: - Private

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: flushQueue)
        timer.schedule(deadline: .now() + flushInterval, repeating: flushInterval)
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        timerSource = timer
    }

    /// Runs on `flushQueue` only.
    private func drain() {
        bufferLock.lock()
        guard !buffer.isEmpty else { bufferLock.unlock(); return }
        let chunks = buffer
        buffer.removeAll(keepingCapacity: true)
        bufferLock.unlock()

        guard let h = handle else { return }
        for chunk in chunks {
            h.write(chunk)
            fileSizeBytes += UInt64(chunk.count)
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
