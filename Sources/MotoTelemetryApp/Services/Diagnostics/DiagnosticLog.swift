import Foundation
import MotoTelemetryCore
import os
#if canImport(UIKit)
import UIKit
#endif

/// App-side implementation of the core `DiagnosticSink` seam. Writes one JSON
/// object per line (NDJSON) to `<Documents>/logs/session-<stamp>.ndjson`, mirrors
/// `.info` and above into OSLog, rotates at ~20 MB keeping the newest 5 files, and
/// flushes on background / terminate so a kill never loses the tail.
///
/// ## The clock (`t`)
///
/// Every line's `t` is **`ProcessInfo.processInfo.systemUptime`** — the process
/// monotonic uptime clock, in seconds. This is the SAME clock the pipeline runs
/// on: CoreMotion sample timestamps are `systemUptime`, `RunRecorder` stamps its
/// session origin with `systemUptime`, and `SpeedService` maps each GNSS fix into
/// the `systemUptime` domain via its `monotonicOffset`. Core log lines therefore
/// carry the SAMPLE's time (already `systemUptime`-domain, passed straight through
/// `DiagnosticEvent.time`) and app log lines carry `systemUptime` captured at the
/// call — so app and core lines interleave correctly on one axis. `wall` is a
/// human-readable ISO-8601 wall clock added only for the reader's convenience and
/// is never used for ordering.
///
/// ## Threading
///
/// `emit` is called from the 100 Hz sensor thread. It NEVER touches the
/// filesystem inline: it appends into a bounded in-memory ring under a lock and a
/// background serial queue flushes ~every 0.25 s. Dropped events (buffer full or
/// per-message coalescing) are counted and reported, never silently lost.
final class DiagnosticLog: DiagnosticSink {

    // MARK: - Singleton

    static let shared = DiagnosticLog()

    // MARK: - Tuning

    /// Bounded in-memory buffer. At ~120 bytes/line this is ~1.2 MB worst case,
    /// far more than 0.25 s of transition+heartbeat traffic ever produces; it only
    /// fills if the disk stalls, in which case we drop and count rather than grow.
    private let maxBufferedLines = 10_000
    /// Coalesce any identical `(category, message)` pair arriving faster than this,
    /// as defence in depth over the core's own rate discipline.
    private let coalesceWindow: TimeInterval = 0.05     // ~20/s
    private let flushInterval: TimeInterval = 0.25
    private let rotateThresholdBytes: UInt64 = 20 * 1024 * 1024
    private let keepFiles = 3   // set to 5 total via retention below

    // MARK: - Paths

    let logDirectory: URL

    /// The file currently being written, held INSIDE its lock.
    ///
    /// `rotate()` reassigns this on the flush queue while the UI may be reading it,
    /// and `URL` is a struct over refcounted storage, so an unsynchronised read
    /// during reassignment can tear. Storing the value inside
    /// `OSAllocatedUnfairLock` rather than in a `var` guarded by a separate lock
    /// makes the property itself immutable, which is also what satisfies
    /// `Sendable` — Swift 5.9 flags a mutable stored property on a
    /// `Sendable`-conforming class no matter how carefully it is locked, and has no
    /// `nonisolated(unsafe)` escape hatch.
    private let currentFileURLLock: OSAllocatedUnfairLock<URL>

    var currentFileURL: URL { currentFileURLLock.withLock { $0 } }

    // MARK: - OSLog mirror (one Logger per category, made lazily)

    private var loggers: [String: Logger] = [:]
    private let loggersLock = NSLock()

    // MARK: - Buffer

    private var buffer: [String] = []
    private let bufferLock = NSLock()
    private var droppedCount = 0
    /// Last emit time per `(category|message)` key, for coalescing.
    private var lastEmitByKey: [String: TimeInterval] = [:]

    // MARK: - Flush machinery

    private let flushQueue = DispatchQueue(label: "com.mototelemetry.diaglog.flush", qos: .utility)
    private var timerSource: DispatchSourceTimer?
    private var handle: FileHandle?
    private var bytesWritten: UInt64 = 0

    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - Init

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.logDirectory = dir

        let stamp = Self.stamp()
        self.currentFileURLLock = OSAllocatedUnfairLock(
            initialState: dir.appendingPathComponent("session-\(stamp).ndjson"))

        openCurrentFile()
        writeHeaderLine()
        startTimer()
        registerLifecycleObservers()
    }

    // MARK: - DiagnosticSink

    /// Called from the 100 Hz sensor thread. Lock-guarded append only; no I/O.
    func emit(_ event: DiagnosticEvent) {
        let line = encode(event)

        bufferLock.lock()
        // Defence-in-depth coalescing over the core's transition+heartbeat rule.
        let key = event.category + "|" + event.message
        let exemptFromCoalescing = (event.level == .warn || event.level == .error)
        if let last = lastEmitByKey[key], event.time - last < coalesceWindow,
           !exemptFromCoalescing {
            droppedCount += 1
            bufferLock.unlock()
            return
        }
        lastEmitByKey[key] = event.time

        let bufferFull = buffer.count >= maxBufferedLines
        if bufferFull {
            droppedCount += 1
        } else {
            buffer.append(line)
        }
        bufferLock.unlock()

        // OSLog mirror for .info and above; trace/debug stay file-only so the
        // Console stays readable.
        //
        // This runs AFTER the coalescing check, not before it. It used to be the
        // first thing `emit` did, so the on-disk NDJSON was correctly held to 20/s
        // while every `.info` event reached the Xcode console unthrottled — the
        // device log that prompted this audit IS the OSLog stream, which is why it
        // measured ~100/s against a coalescer that was working correctly. The two
        // numbers were never in conflict; they were two different sinks. `.warn` and
        // `.error` are exempt from coalescing above, so the mirror still receives
        // every one of them.
        if event.level.osLogEligible {
            mirror(event)
        }
    }

    // MARK: - Convenience for app code (no core sample time available)

    /// For app-side call sites that have no core sample time — stamps `t` with the
    /// shared `systemUptime` clock so the line interleaves with core lines.
    func log(_ level: DiagnosticEvent.Level,
             _ category: String,
             _ message: String,
             _ values: [String: Double] = [:]) {
        emit(DiagnosticEvent(time: ProcessInfo.processInfo.systemUptime,
                             level: level, category: category,
                             message: message, values: values))
    }

    // MARK: - Public control

    /// Synchronously drains the buffer to disk. Safe to call from any thread.
    func flush() {
        flushQueue.sync { self.drain() }
    }

    /// The last `lines` lines of the current file plus anything still buffered —
    /// for an in-app diagnostics viewer.
    func snapshotTail(lines: Int) -> [String] {
        flush()
        var result: [String] = []
        if let data = try? Data(contentsOf: currentFileURL),
           let text = String(data: data, encoding: .utf8) {
            let all = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            result = Array(all.suffix(lines))
        }
        return result
    }

    // MARK: - Encoding

    /// Builds the exact contract line:
    /// `{"t":..,"lvl":"..","cat":"..","msg":"..","v":{..},"wall":".."}`
    private func encode(_ e: DiagnosticEvent) -> String {
        var v = "{"
        var first = true
        // Deterministic key order so lines diff cleanly and greps are stable.
        for k in e.values.keys.sorted() {
            if !first { v += "," }
            v += "\(jsonString(k)):\(number(e.values[k]!))"
            first = false
        }
        v += "}"
        let wall = iso.string(from: Date())
        return "{\"t\":\(number(e.time)),\"lvl\":\(jsonString(e.level.rawValue)),"
            + "\"cat\":\(jsonString(e.category)),\"msg\":\(jsonString(e.message)),"
            + "\"v\":\(v),\"wall\":\(jsonString(wall))}"
    }

    private func number(_ d: Double) -> String {
        if d.isNaN || d.isInfinite { return "null" }
        // Trim to milli-precision-ish without locale surprises.
        return String(format: "%.6g", d)
    }

    private func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }

    // MARK: - OSLog mirror

    private func mirror(_ e: DiagnosticEvent) {
        let logger: Logger = {
            loggersLock.lock(); defer { loggersLock.unlock() }
            if let existing = loggers[e.category] { return existing }
            let made = Logger(subsystem: "com.mototelemetry.app", category: e.category)
            loggers[e.category] = made
            return made
        }()
        let vals = e.values.isEmpty ? "" : " " + e.values.map { "\($0)=\($1)" }.joined(separator: " ")
        let msg = "\(e.message)\(vals)"
        switch e.level {
        case .info:  logger.info("\(msg, privacy: .public)")
        case .warn:  logger.warning("\(msg, privacy: .public)")
        case .error: logger.error("\(msg, privacy: .public)")
        case .trace, .debug: break   // file-only
        }
    }

    // MARK: - File lifecycle

    private func openCurrentFile() {
        FileManager.default.createFile(atPath: currentFileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: currentFileURL)
        bytesWritten = 0
    }

    /// First line of every session file: app version + build, device model, iOS
    /// version, thermal state, low-power flag, the full `Config` as JSON, and the
    /// log format version. This is what makes a remote TestFlight log usable.
    private func writeHeaderLine() {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        let build = (info?["CFBundleVersion"] as? String) ?? "0"
        var sys = utsname(); uname(&sys)
        let machine = withUnsafePointer(to: &sys.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

        #if canImport(UIKit)
        let osVersion = UIDevice.current.systemVersion
        #else
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        #endif

        // Encode the full Config as JSON; Config is Codable.
        let configJSON: String = {
            if let d = try? JSONEncoder().encode(Config()),
               let s = String(data: d, encoding: .utf8) { return s }
            return "{}"
        }()

        let wall = iso.string(from: Date())
        let header = "{\"kind\":\"header\",\"logFormatVersion\":1,"
            + "\"t\":\(number(ProcessInfo.processInfo.systemUptime)),"
            + "\"appVersion\":\(jsonString(version)),\"build\":\(jsonString(build)),"
            + "\"device\":\(jsonString(machine)),\"os\":\(jsonString(osVersion)),"
            + "\"thermalState\":\(thermal),\"lowPower\":\(lowPower ? "true" : "false"),"
            + "\"config\":\(configJSON),\"wall\":\(jsonString(wall))}\n"
        if let data = header.data(using: .utf8) {
            handle?.write(data)
            bytesWritten += UInt64(data.count)
        }
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: flushQueue)
        timer.schedule(deadline: .now() + flushInterval, repeating: flushInterval)
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        timerSource = timer
    }

    /// Runs on `flushQueue` only. Swaps the buffer out under the lock, writes it,
    /// appends a dropped-count marker if any were shed, and rotates if oversized.
    private func drain() {
        bufferLock.lock()
        guard !buffer.isEmpty || droppedCount > 0 else { bufferLock.unlock(); return }
        let lines = buffer
        buffer.removeAll(keepingCapacity: true)
        let dropped = droppedCount
        droppedCount = 0
        bufferLock.unlock()

        var blob = lines.joined(separator: "\n")
        if !lines.isEmpty { blob += "\n" }
        if dropped > 0 {
            let t = ProcessInfo.processInfo.systemUptime
            blob += "{\"t\":\(number(t)),\"lvl\":\"warn\",\"cat\":\"log\","
                + "\"msg\":\"events dropped\",\"v\":{\"dropped\":\(dropped)},"
                + "\"wall\":\(jsonString(iso.string(from: Date())))}\n"
        }
        guard let data = blob.data(using: .utf8), let h = handle else { return }
        h.write(data)
        bytesWritten += UInt64(data.count)

        if bytesWritten >= rotateThresholdBytes { rotate() }
    }

    private func rotate() {
        handle?.synchronizeFile()
        try? handle?.close()
        handle = nil

        let stamp = Self.stamp()
        currentFileURLLock.withLock {
            $0 = logDirectory.appendingPathComponent("session-\(stamp).ndjson")
        }
        openCurrentFile()
        writeHeaderLine()
        pruneOldFiles(keepNewest: 5)
    }

    /// Keep the newest `keepNewest` session files, delete the rest.
    private func pruneOldFiles(keepNewest: Int) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let sessions = urls
            .filter { $0.lastPathComponent.hasPrefix("session-") && $0.pathExtension == "ndjson" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da > db
            }
        for stale in sessions.dropFirst(keepNewest) {
            try? fm.removeItem(at: stale)
        }
    }

    // MARK: - Background / terminate flush

    private func registerLifecycleObservers() {
        #if canImport(UIKit)
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                       object: nil, queue: nil) { [weak self] _ in self?.flush() }
        nc.addObserver(forName: UIApplication.willTerminateNotification,
                       object: nil, queue: nil) { [weak self] _ in self?.flush() }
        #endif
    }

    // MARK: - Helpers

    private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}

private extension DiagnosticEvent.Level {
    /// `.info` and above mirror to OSLog; `.trace`/`.debug` stay file-only.
    var osLogEligible: Bool {
        switch self {
        case .trace, .debug: return false
        case .info, .warn, .error: return true
        }
    }
}
