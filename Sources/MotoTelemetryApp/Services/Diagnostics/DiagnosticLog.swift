import Foundation
import MotoTelemetryCore
import os
#if canImport(UIKit)
import UIKit
#endif

/// App-side implementation of the core `DiagnosticSink` seam. Writes one JSON
/// object per line to a unified `recording-*.ndjson` file, including raw samples
/// and replay state. Mirrors diagnostics to OSLog and seals on session stop.
/// Recordings are retained until explicitly deleted; incomplete writes are marked.
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
    private let rotateThresholdBytes: UInt64 = 512 * 1024 * 1024

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
    private var totalDrops = 0
    private var captureActive = false
    private var limitReached = false
    private var diskSize: UInt64 = 0
    private var firstSensorTime: Double?
    private var lastSensorTime: Double?
    private var imuCount = 0
    private var validSpeedCount = 0
    private var maxSpeedKPH: Double?
    private var writeFailure: String?
    var recordingSize: UInt64 { bufferLock.lock(); defer { bufferLock.unlock() }; return diskSize }
    var recordingDrops: Int { bufferLock.lock(); defer { bufferLock.unlock() }; return totalDrops }
    var recordingLimitReached: Bool { bufferLock.lock(); defer { bufferLock.unlock() }; return limitReached }
    var recordingError: String? { bufferLock.lock(); defer { bufferLock.unlock() }; return writeFailure }

    func beginCapture() {
        bufferLock.lock(); captureActive = true; bufferLock.unlock()
    }

    /// The pipeline calls this in processing order. Do not sort by GNSS fix time:
    /// the estimator saw the fix at this position in the stream, not retroactively.
    func appendRecord<T: Encodable>(_ record: T) {
        do {
            let data = try JSONEncoder().encode(record)
            guard let line = String(data: data, encoding: .utf8) else { return }
            bufferLock.lock()
            defer { bufferLock.unlock() }
            guard !limitReached, writeFailure == nil else { return }
            if buffer.count >= maxBufferedLines { droppedCount += 1; totalDrops += 1 }
            else {
                buffer.append(line)
                if let sample = record as? Sample {
                    if case .imu(let imu) = sample {
                        firstSensorTime = firstSensorTime ?? imu.time
                        lastSensorTime = imu.time; imuCount += 1
                    } else if case .gnss(let fix) = sample, fix.isSpeedValid {
                        validSpeedCount += 1
                        maxSpeedKPH = max(maxSpeedKPH ?? 0, fix.speed * 3.6)
                    }
                }
            }
        } catch {
            bufferLock.lock(); writeFailure = "Recording encoding failed: \(error.localizedDescription)"; bufferLock.unlock()
        }
    }

    /// Close a ride and immediately open a new diagnostic file. The closed ride
    /// can now be uploaded without waiting for another launch or guessing a pair.
    func sealCapture() {
        bufferLock.lock(); captureActive = false; bufferLock.unlock()
        flushQueue.sync { self.drain(); self.rotate() }
    }

    /// Last emit time per `(category|message)` key, for coalescing.
    ///
    /// INVARIANT: `message` MUST be a compile-time constant (or a finite enum
    /// rawValue), NEVER a string with an interpolated variable — the numbers belong
    /// in `values`, which is not part of this key. This map is never pruned, so the
    /// key set must be bounded by the finite set of (category, message) pairs the
    /// code emits. A grep of every emit/log call site across app and core (audited
    /// 2026-09) confirmed this holds: all messages are literals, and the two
    /// concatenated ones — `"event " + stateName(state)` and `"gate " +
    /// verdict.reason.rawValue` — append an enum rawValue drawn from a fixed set. If
    /// a future call site interpolates a variable into `message`, this map grows
    /// without bound over a long ride and must be given an LRU cap or periodic clear.
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
            initialState: dir.appendingPathComponent("recording-\(stamp)-\(UUID().uuidString.prefix(8)).ndjson"))

        openCurrentFile()
        writeHeaderLine()
        // Prune at LAUNCH, not only from `rotate()`. See `pruneOldFiles` — the
        // rotate-only call site meant pruning effectively never ran. Safe here
        // because no session (and therefore no RawSampleRecorder file handle) exists
        // yet at construction time.
        // Retain recordings until the rider explicitly deletes them.
        startTimer()
        registerLifecycleObservers()
    }

    // MARK: - DiagnosticSink

    /// Called from the 100 Hz sensor thread. Lock-guarded append only; no I/O.
    func emit(_ event: DiagnosticEvent) {
        let line = encode(event)

        bufferLock.lock()
        guard !limitReached, writeFailure == nil else { bufferLock.unlock(); return }
        // Defence-in-depth coalescing over the core's transition+heartbeat rule.
        let key = event.category + "|" + event.message
        let exemptFromCoalescing = (event.level == .warn || event.level == .error || event.category == "event" || event.values["changed"] == 1)
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
            totalDrops += 1
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

    /// The last `lines` lines of the current file — for an in-app diagnostics
    /// viewer. Returns each line as its NDJSON text.
    ///
    /// Routed through `NDJSONReader.tail(url:maxLines:)`, which seeks from the END
    /// of the file in 64 KB chunks. It previously did `Data(contentsOf:)` then
    /// `suffix(lines)`, pulling the entire file — up to the 20 MB rotation
    /// threshold — into memory just to show the last N lines, which is exactly what
    /// the chunked tail reader exists to avoid. We `flush()` first so the tail
    /// includes everything buffered, then re-serialise each parsed `LogLine`'s
    /// `raw` object back to compact JSON to preserve this method's `[String]`
    /// contract (the reader hands back parsed lines, not the original text).
    func snapshotTail(lines: Int) -> [String] {
        flush()
        let result = NDJSONReader.tail(url: currentFileURL, maxLines: lines)
        return result.lines.compactMap { line in
            guard let data = try? JSONSerialization.data(
                    withJSONObject: line.raw,
                    options: [.sortedKeys, .withoutEscapingSlashes]),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return text
        }
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
        return String(format: "%.17g", locale: Locale(identifier: "en_US_POSIX"), d)
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
        let header = "{\"kind\":\"header\",\"logFormatVersion\":2,\"formatVersion\":2,"
            + "\"sessionID\":\(jsonString(UUID().uuidString)),\"startedAt\":\(Date().timeIntervalSinceReferenceDate),"
            + "\"deviceModel\":\(jsonString(machine)),\"notes\":\"Unified sensor and diagnostic recording\","
            + "\"timestampUnit\":\"monotonic seconds\",\"speedUnit\":\"m/s; negative means unavailable\","
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
        do { try h.write(contentsOf: data) }
        catch {
            bufferLock.lock(); writeFailure = "Recording write failed: \(error.localizedDescription)"; bufferLock.unlock()
            return
        }
        bytesWritten += UInt64(data.count)

        bufferLock.lock()
        diskSize = bytesWritten
        let active = captureActive
        let reached = limitReached
        if bytesWritten >= rotateThresholdBytes && active { limitReached = true }
        bufferLock.unlock()
        if bytesWritten >= rotateThresholdBytes {
            if !active { rotate() }
            else if !reached {
                let marker = "{\"kind\":\"recordingIncomplete\",\"reason\":\"512 MB recording limit reached\"}\n"
                try? h.write(contentsOf: Data(marker.utf8))
                h.synchronizeFile()
            }
        }
        // Bound crash loss to the flush cadence; never depend only on page cache.
        h.synchronizeFile()
    }

    private func rotate() {
        bufferLock.lock()
        let complete = totalDrops == 0 && !limitReached && writeFailure == nil
        let drops = totalDrops
        let duration = max(0, (lastSensorTime ?? 0) - (firstSensorTime ?? 0))
        let samples = imuCount
        let fixes = validSpeedCount
        let maxSpeed = maxSpeedKPH.map { String($0) } ?? "null"
        bufferLock.unlock()
        let footer = "{\"kind\":\"recordingEnd\",\"complete\":\(complete),\"droppedRecords\":\(drops),"
            + "\"duration\":\(duration),\"imuSamples\":\(samples),\"validSpeedFixes\":\(fixes),\"maxSpeedKPH\":\(maxSpeed)}\n"
        try? handle?.write(contentsOf: Data(footer.utf8))
        handle?.synchronizeFile()
        try? handle?.close()
        handle = nil

        let stamp = Self.stamp()
        currentFileURLLock.withLock {
            $0 = logDirectory.appendingPathComponent("recording-\(stamp)-\(UUID().uuidString.prefix(8)).ndjson")
        }
        bufferLock.lock()
        totalDrops = 0; limitReached = false; diskSize = 0; writeFailure = nil
        firstSensorTime = nil; lastSensorTime = nil; imuCount = 0
        validSpeedCount = 0; maxSpeedKPH = nil
        bufferLock.unlock()
        openCurrentFile()
        writeHeaderLine()
        // Retain recordings until the rider explicitly deletes them.
    }

    /// A file modified more recently than this is assumed to still have an open write
    /// handle and is never deleted. `RawSampleRecorder` flushes every 0.5 s, so an
    /// actively-written file is always well inside this window.
    static let activeFileGraceInterval: TimeInterval = 60

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
