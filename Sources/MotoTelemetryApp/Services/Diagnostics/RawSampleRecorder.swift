import Foundation
import MotoTelemetryCore
#if canImport(UIKit)
import UIKit
#endif

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
    /// fsync cadence, from `Config.fsyncInterval`. This is what bounds "a force-quit
    /// loses at most N seconds".
    ///
    /// That guarantee used to be documented on `SessionWriter`, the only writer that
    /// honoured `Config.fsyncInterval` — and `SessionWriter` had ZERO callers, so the
    /// guarantee was false for every ride ever recorded: the live path is this class,
    /// and this class only fsynced on `finish()`. `SessionWriter` has now been deleted
    /// and the guarantee moved here, to the writer that actually runs. A periodic
    /// `synchronizeFile()` is the whole substance of it; a `write()` alone leaves the
    /// bytes in the page cache, where a kill loses them.
    private let fsyncInterval: TimeInterval
    /// Monotonic time of the last successful fsync, `flushQueue` only.
    private var lastSyncTime: TimeInterval = 0
    /// ~120 bytes/sample × 100 Hz × 0.5 s ≈ 6 KB per flush; the cap bounds a stalled
    /// disk to a few seconds of samples before dropping and counting. From
    /// `Config.writerRingCapacity`, which was likewise orphaned by `SessionWriter`'s
    /// deletion and is the same concept under the old writer's name.
    private let maxBufferedChunks: Int
    /// Hard ceiling on one raw trace, bytes.
    ///
    /// The recorder defaults ON and had no cap at all: a device log measured
    /// `rawLogBytes=1,579,503` in a 44 s session, which is ~129 MB **per hour** of
    /// riding, written into `<Documents>` where nothing ages it out. 64 MB is roughly
    /// half an hour of continuous recording — long enough to cover any session worth
    /// replaying, and bounded enough that forgetting the toggle cannot fill a phone.
    /// `DiagnosticLog` is a separate file and already rotates at 20 MB keeping the
    /// newest few; this is the raw trace's equivalent, except that truncating a
    /// replay trace mid-stream is the honest behaviour — a rotated raw file would be
    /// an unreplayable fragment with no header.
    private let maxFileBytes: UInt64 = 64 * 1024 * 1024

    // MARK: - Public

    let fileURL: URL
    /// Current on-disk size in bytes, surfaced so the UI can show how much a ride
    /// is costing. Updated on each flush.
    ///
    /// These three are the "your trace is incomplete" signals: current size, how
    /// many samples were dropped when the buffer was full, and whether the hard
    /// size cap truncated the trace. They are written under `bufferLock` (from the
    /// sensor path and the flush queue) and read from the UI thread. A plain
    /// `private(set) var` read is a torn/stale cross-thread read of a value whose
    /// whole job is to say whether the data can be trusted — so they are `private`
    /// backing storage exposed ONLY through accessors that take the same
    /// `bufferLock`. The hot `record` path's locking is unchanged: it already holds
    /// `bufferLock` when it touches these, and these accessors add no work to it.
    private var _fileSizeBytes: UInt64 = 0
    private var _droppedSamples = 0
    private var _sizeCapReached = false

    /// Bytes on disk as of the last flush. Read under `bufferLock`.
    var fileSizeBytes: UInt64 { bufferLock.lock(); defer { bufferLock.unlock() }; return _fileSizeBytes }
    /// Samples dropped because the flush buffer was full. Read under `bufferLock`.
    var droppedSamples: Int { bufferLock.lock(); defer { bufferLock.unlock() }; return _droppedSamples }
    /// True once `maxFileBytes` was hit and recording stopped. Surfaced so the UI can
    /// say the trace is truncated rather than silently ending it. Read under `bufferLock`.
    var sizeCapReached: Bool { bufferLock.lock(); defer { bufferLock.unlock() }; return _sizeCapReached }

    // MARK: - Private

    private var buffer: [Data] = []
    private let bufferLock = NSLock()
    private let flushQueue = DispatchQueue(label: "com.mototelemetry.rawrec.flush", qos: .utility)
    private var timerSource: DispatchSourceTimer?
    private var handle: FileHandle?
    private let encoder = JSONEncoder()
    /// Guards `finish()` against a second call and against racing the flush queue.
    /// Only ever touched on `flushQueue`, so no separate lock is needed.
    private var finished = false
    /// Tokens for the background/terminate observers, removed in `finish()`.
    ///
    /// `DiagnosticLog` is a process-lifetime singleton and never removes its block
    /// observers; this recorder is created and destroyed per session, so its
    /// observers MUST be torn down or they would fire against a finished recorder.
    /// The blocks capture `[weak self]` (same as `DiagnosticLog`) so they never
    /// retain the recorder — the tokens exist for teardown, not to break a cycle.
    private var lifecycleObservers: [NSObjectProtocol] = []

    // MARK: - Init

    /// - Parameters:
    ///   - config: the exact `Config` in force, stored in the header so a replay
    ///     runs under the same parameters that produced the trace.
    ///   - bikeProfileID: recorded in the header notes for provenance.
    init(config: Config, bikeProfileID: UUID) {
        self.fsyncInterval = config.fsyncInterval
        self.maxBufferedChunks = config.writerRingCapacity

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
            _fileSizeBytes = UInt64(headerData.count)
        }

        startTimer()
        registerLifecycleObservers()
    }

    // MARK: - Recording

    /// Encode and buffer one raw sample. Called on the sensor path — never blocks
    /// on I/O. Uses the core `LogFile.encode`, so the bytes are wire-identical to a
    /// live session log.
    func record(_ sample: Sample) {
        guard let data = try? LogFile.encode(sample) else { return }
        bufferLock.lock()
        if _sizeCapReached {
            bufferLock.unlock()
            return
        }
        if buffer.count >= maxBufferedChunks {
            _droppedSamples += 1
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

    /// Drain the buffer AND force the bytes to disk. Used by the background /
    /// terminate observers: the OS may kill a backgrounded app moments later, so a
    /// plain `flush()` (which only `write`s) is not enough — the last samples must
    /// actually reach the file, which is what `synchronizeFile()` guarantees.
    /// No-op after `finish()` has closed the handle.
    private func flushAndSync() {
        flushQueue.sync {
            guard !self.finished else { return }
            self.drain()
            self.handle?.synchronizeFile()
        }
    }

    /// Stop recording and close the file. Idempotent: a second call (e.g. an
    /// explicit stop after a terminate observer already ran) is a no-op, and the
    /// timer cancel/nil and the synchronize/close all happen on `flushQueue` so
    /// they cannot race a concurrent `drain()`.
    func finish() {
        timerSource?.cancel()
        timerSource = nil
        removeLifecycleObservers()
        flush()
        flushQueue.sync {
            guard !self.finished else { return }
            self.finished = true
            self.handle?.synchronizeFile()
            try? self.handle?.close()
            self.handle = nil
        }
    }

    // MARK: - Background / terminate flush

    /// Mirror of `DiagnosticLog.registerLifecycleObservers`: flush when the app is
    /// backgrounded or terminated so a kill never loses the buffered tail.
    ///
    /// `RawSampleRecorder` writes the MORE important file (the replayable raw
    /// trace) yet registered NONE of these — it flushed only on its 0.5 s timer and
    /// on explicit `finish()`, so an OS kill of a backgrounded app dropped up to
    /// 0.5 s of samples even though the code to save them existed. These observers
    /// close that gap, and unlike `DiagnosticLog` they also `synchronizeFile()`
    /// (via `flushAndSync`) because a raw trace killed mid-flush must have its
    /// bytes on disk, not merely handed to the OS write buffer.
    private func registerLifecycleObservers() {
        #if canImport(UIKit)
        let nc = NotificationCenter.default
        lifecycleObservers.append(
            nc.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                           object: nil, queue: nil) { [weak self] _ in self?.flushAndSync() })
        lifecycleObservers.append(
            nc.addObserver(forName: UIApplication.willTerminateNotification,
                           object: nil, queue: nil) { [weak self] _ in self?.flushAndSync() })
        #endif
    }

    private func removeLifecycleObservers() {
        let nc = NotificationCenter.default
        for token in lifecycleObservers { nc.removeObserver(token) }
        lifecycleObservers.removeAll()
    }

    // MARK: - Private

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: flushQueue)
        timer.schedule(deadline: .now() + flushInterval, repeating: flushInterval)
        timer.setEventHandler { [weak self] in self?.drainAndMaybeSync() }
        timer.resume()
        timerSource = timer
    }

    /// The timer's tick: always drain, and fsync once `fsyncInterval` has elapsed.
    ///
    /// The two cadences are deliberately separate. Draining is cheap and frequent so
    /// the in-memory buffer cannot grow into the drop threshold; fsync is expensive
    /// (it waits on the device) so it runs on the slower `Config.fsyncInterval`. The
    /// gap between them IS the durability bound: a kill loses at most one fsync
    /// interval of samples, which is exactly what `Config.fsyncInterval` claims.
    ///
    /// Runs on `flushQueue` only.
    private func drainAndMaybeSync() {
        drain()
        guard !finished else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastSyncTime >= fsyncInterval {
            handle?.synchronizeFile()
            lastSyncTime = now
        }
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
            // Size accounting is read AND written under `bufferLock` so the UI
            // accessors above never see a torn `_fileSizeBytes` / `_sizeCapReached`.
            // This runs on `flushQueue`, never on the 100 Hz `record` path, so it
            // adds no lock work to the sensor thread.
            bufferLock.lock()
            let projected = _fileSizeBytes + UInt64(chunk.count)
            if projected > maxFileBytes {
                let alreadyReported = _sizeCapReached
                _sizeCapReached = true
                bufferLock.unlock()
                if !alreadyReported {
                    DiagnosticLog.shared.log(.warn, "rawrec",
                                             "raw trace hit its size cap — recording stopped",
                                             ["bytes": Double(projected - UInt64(chunk.count)),
                                              "capBytes": Double(maxFileBytes)])
                }
                return
            }
            bufferLock.unlock()

            h.write(chunk)

            bufferLock.lock()
            _fileSizeBytes += UInt64(chunk.count)
            bufferLock.unlock()
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
