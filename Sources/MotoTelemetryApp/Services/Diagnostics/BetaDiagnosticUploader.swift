// Optional beta diagnostic uploads. Consent gates every scheduling boundary.
// Upload copies omit coordinate fields; originals remain subject to local cleanup.
#if BETA
import Foundation
import Combine
import SwiftUI
import MotoTelemetryCore
import UIKit
import os

// MARK: - Anonymous per-install ID

/// Persistent installation identifier. Pseudonymous, not anonymous.
enum BetaInstallID {

    /// UserDefaults key holding the persisted install UUID string.
    static let defaultsKey = "beta.installID"

    /// The stable per-install UUID, created on first read and reused thereafter.
    static var current: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: defaultsKey), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: defaultsKey)
        return fresh
    }
}

// MARK: - Uploader

/// Uploads not-yet-uploaded NDJSON diagnostic logs to the beta backend on app
/// background. `@MainActor` so its `start()` can be called directly from the
/// SwiftUI scene-phase hook; the actual work hops onto URLSession's background
/// configuration, so nothing blocks the main thread beyond kicking off tasks.
///
/// See the file header for the full contract and the `#if BETA` gating rationale.
@MainActor
final class BetaDiagnosticUploader: NSObject, ObservableObject {
    @Published private(set) var connectionTitle = "Not checked"
    @Published private(set) var connectionDetail = "Test the API and a small S3 upload over Wi-Fi."
    @Published private(set) var checkingConnection = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var uploadStatus = "No upload attempted this launch."
    @Published private(set) var pendingCount = 0
    @Published private(set) var activeCount = 0

    var endpointHost: String { apiBase.host ?? "Invalid endpoint" }


    // MARK: Configuration read from Info.plist (empty in production → no-op)

    private let apiBase: URL
    private let token: String
    private let defaults: UserDefaults
    var scheduleForTesting: ((URL) -> Void)?

    /// The directory whose `.ndjson` files are candidates for upload.
    private let logDirectory: URL

    // MARK: Persistence of what has been sent

    /// UserDefaults key: the set of file names already uploaded (stored as an array).
    private static let uploadedKey = "beta.uploadedLogFiles"

    /// File names whose presign/PUT has been kicked off but has NOT yet completed.
    ///
    /// This closes a duplicate-upload race that was caught live on the first device
    /// run: `start()` fired twice ~50 ms apart (a single backgrounding can deliver
    /// more than one `.background` scene phase), and because a file is only recorded
    /// in `uploadedKey` when its PUT *completes* via the delegate, the second pass
    /// re-scanned, still saw all 16 files as un-uploaded, and re-sent every one of
    /// them — 32 objects in S3 and double a tester's cellular data for nothing.
    /// Membership here is claimed synchronously on the main actor before any network
    /// call, so the second pass sees the claim immediately, and is released on
    /// completion or failure so a genuine failure still retries next cycle.
    /// In-memory only: a relaunch legitimately re-tries anything left unmarked.
    private var inFlight: Set<String> = []

    /// Background-task assertion held while presigns are outstanding.
    ///
    /// The PUT runs on the background `URLSession` and survives suspension by design,
    /// but the presign GET runs on `presignSession`, an ordinary ephemeral session
    /// that simply stops when iOS suspends the app. The upload trigger is the
    /// `.background` transition, and by then a stopped session means neither the audio
    /// engine nor location updates are holding the process awake — so it can be
    /// suspended within seconds, before a batch of presigns completes. This assertion
    /// buys the normal few tens of seconds; anything unfinished when iOS expires it
    /// stays unmarked and is retried on the next background cycle.
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    // MARK: URLSession (background configuration → survives suspension)

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(
            withIdentifier: "com.mototelemetry.beta.diagupload")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = false
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// SEPARATE, standard session used ONLY for the small presign GET.
    ///
    /// This is not a style choice. Creating a completion-handler task on a
    /// *background*-configured `URLSession` raises an uncaught `NSGenericException`
    /// — "Completion handler blocks are not supported in background sessions. Use a
    /// delegate instead." — which terminates the app. The original code called
    /// `dataTask(with:completionHandler:)` on the background `session` above, so the
    /// very first background transition in a BETA build crashed on the spot. The
    /// background session is now reserved for `uploadTask(with:fromFile:)`, which is
    /// the only kind of task it may legally be given here, and which is also the
    /// only part that needs to survive suspension.
    private let presignSession: URLSession

    nonisolated private static func makeRequestSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.allowsCellularAccess = false
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }

    private let log = Logger(subsystem: "com.mototelemetry.app", category: "beta.upload")

    // MARK: Init

    nonisolated static var configurationIssue: String {
        let info = Bundle.main.infoDictionary ?? [:]
        do {
            _ = try DiagnosticUploadProtocol.endpoint(base: info["BetaUploadAPIBase"] as? String ?? "",
                                                      token: info["BetaUploadToken"] as? String ?? "")
            return "Uploader is not available. Relaunch the app."
        } catch { return DiagnosticUploadProtocol.networkMessage(error) }
    }

    /// Builds an uploader ONLY if both Info.plist keys are present and non-empty.
    /// Returns nil in production (empty settings) so callers get a clean no-op.
    ///
    /// `nonisolated` because the call site is a stored-property initializer on the
    /// `App` struct (`@State private var betaUploader = ...makeUploader()`), which is
    /// a synchronous *nonisolated* context — calling a `@MainActor` member from there
    /// is a hard compile error ("call to main actor-isolated static method ... in a
    /// synchronous nonisolated context"). Reading `Bundle.main.infoDictionary` and
    /// storing three immutable values touches no actor-protected state, so opting
    /// this one entry point out of the isolation is safe.
    nonisolated static func makeUploader(
        logDirectory: URL = DiagnosticLog.shared.logDirectory
    ) -> BetaDiagnosticUploader? {
        let info = Bundle.main.infoDictionary
        let baseString = (info?["BetaUploadAPIBase"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let token = (info?["BetaUploadToken"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard let base = try? DiagnosticUploadProtocol.endpoint(base: baseString, token: token) else {
            return nil
        }
        return BetaDiagnosticUploader(apiBase: base, token: token,
                                      logDirectory: logDirectory)
    }

    /// `nonisolated` for the same reason as `makeUploader` — it only assigns
    /// immutable stored properties, so it needs no main-actor hop.
    nonisolated init(apiBase: URL, token: String, logDirectory: URL, defaults: UserDefaults = .standard, requestSession: URLSession? = nil) {
        self.presignSession = requestSession ?? Self.makeRequestSession()
        self.defaults = defaults
        self.apiBase = apiBase
        self.token = token
        self.logDirectory = logDirectory
        super.init()
    }

    // MARK: Public entry point

    /// Record a scene-phase transition. Exists purely for observability: with the
    /// upload keyed off `.background`, a phase that never arrives is otherwise
    /// invisible, and looks identical to a cycle that ran and found nothing to send.
    func noteScenePhase(_ phase: String) {
        log.info("scene phase \(phase, privacy: .public)")
    }

    /// Scan the log directory and upload every `.ndjson` file that has not already
    /// been uploaded and is not the currently-open log file. Fire-and-forget:
    /// per-file failures are logged and left for the next cycle.
    func start(selectedFiles: [URL]? = nil) {
        guard Self.consentDate(defaults: defaults) != nil else {
            uploadStatus = "Sharing is off. Enable Share diagnostics in Settings to upload logs."
            return
        }
        let installID = BetaInstallID.current

        // Unconditional entry line. Without it, "the scene-phase trigger never fired"
        // and "it fired and found nothing to send" are indistinguishable in the log —
        // which is exactly the ambiguity that made a no-upload run undiagnosable.
        log.info("upload cycle start")

        let candidates = pendingFiles(selectedFiles: selectedFiles)
        pendingCount = candidates.count
        guard !candidates.isEmpty else { return }
        uploadStatus = "Preparing \(candidates.count) file(s) for upload over Wi-Fi."

        if scheduleForTesting == nil { beginBackgroundAssertion() }

        for fileURL in candidates {
            // Claim the file BEFORE any async work so a second `start()` in the same
            // backgrounding cannot pick it up again (see `inFlight`).
            inFlight.insert(fileURL.lastPathComponent)
            activeCount = inFlight.count

            if let scheduleForTesting { scheduleForTesting(fileURL) }
            else { presignThenUpload(fileURL: fileURL, installID: installID) }
        }
    }

    private func presignRequest(installID: String, sessionID: String, timestamp: Int) throws -> URLRequest {
        let endpoint = try DiagnosticUploadProtocol.endpoint(base: apiBase.absoluteString, token: token)
        let url = try DiagnosticUploadProtocol.requestURL(endpoint: endpoint, installID: installID,
                                                        session: sessionID, timestamp: timestamp)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(token, forHTTPHeaderField: "X-Beta-Key")
        return request
    }

    /// Tests the SAME authenticated route and content type as real uploads. The
    /// explicit button writes one synthetic record, never sensor data or coordinates.
    func testConnection() async {
        guard !checkingConnection else { return }
        checkingConnection = true
        connectionTitle = "Checking API…"
        connectionDetail = "Requesting permission for a small test upload."
        defer { checkingConnection = false; lastChecked = Date() }
        do {
            let request = try presignRequest(installID: "connectivity-" + UUID().uuidString,
                sessionID: "connection-test", timestamp: Int(Date().timeIntervalSince1970 * 1000))
            let (data, response) = try await presignSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let url = try DiagnosticUploadProtocol.uploadURL(data: data, status: status)
            connectionTitle = "API reachable — testing S3…"
            connectionDetail = "Verifying that S3 accepts an upload."
            var put = URLRequest(url: url)
            put.httpMethod = "PUT"
            put.setValue("application/x-ndjson", forHTTPHeaderField: "Content-Type")
            let payload = Data("{\"kind\":\"connectivity-test\",\"synthetic\":true}\n".utf8)
            put.httpBody = payload
            let (_, result) = try await presignSession.data(for: put)
            let putStatus = (result as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(putStatus) else {
                throw DiagnosticUploadProtocol.Failure.http(stage: "S3", status: putStatus)
            }
            connectionTitle = "Reachable"
            connectionDetail = "API authenticated and S3 accepted the test file."
        } catch {
            connectionTitle = "Upload path unavailable"
            connectionDetail = DiagnosticUploadProtocol.networkMessage(error)
        }
    }

    /// The `session` component of the S3 key, derived from the SOURCE FILE NAME rather
    /// than a random UUID.
    ///
    /// `session` is an opaque client-chosen string as far as the backend cares — its
    /// only constraint is `^[A-Za-z0-9_\-]{1,64}$` — and the app's own file names
    /// already encode both the kind and the time: `session-20260910-204842`,
    /// `raw-20260910-211100`. Using them makes every object self-describing, so you can
    /// tell a diagnostic log from a raw sample trace, and which device session produced
    /// it, from the key alone. A UUID told you nothing without downloading the object.
    nonisolated static func sessionIdentifier(for fileURL: URL) -> String {
        let base = fileURL.deletingPathExtension().lastPathComponent
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        let cleaned = String(base.map { allowed.contains($0) ? $0 : "-" }).prefix(64)
        return cleaned.isEmpty ? UUID().uuidString : String(cleaned)
    }

    /// The `ts` component, taken from the file's modification date rather than "now".
    ///
    /// Combined with a filename-derived `session` this makes the whole key
    /// DETERMINISTIC for a given file, which makes re-uploading idempotent: a retry
    /// after a failed cycle overwrites the same object instead of laying down a
    /// near-duplicate under a fresh timestamp. Only a file still being appended to
    /// could shift its own key, and those are excluded from candidates anyway.
    nonisolated static func timestampMillis(for fileURL: URL) -> Int {
        let modified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
        return Int(modified.timeIntervalSince1970 * 1000)
    }

    // MARK: File discovery

    /// `.ndjson` files in the log directory that are NOT already uploaded, NOT in
    /// flight, NOT the file currently being written by `DiagnosticLog`, and NOT
    /// recently modified.
    ///
    /// The recency check matters because uploaded files are now DELETED locally.
    /// `RawSampleRecorder` keeps an open `FileHandle` on its `raw-*.ndjson` for the
    /// whole session, and this app has `UIBackgroundModes = audio, location`, so
    /// backgrounding mid-ride — the exact upload trigger — leaves that file open and
    /// growing. Uploading a partial file would merely be untidy; deleting it would
    /// unlink the inode the recorder is still writing to, and the recording would
    /// vanish with no error. Excluding anything touched in the last
    /// `activeFileGraceInterval` costs only a one-cycle delay: the file is picked up
    /// on the next background transition after the session ends.
    private func pendingFiles(selectedFiles: [URL]? = nil) -> [URL] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]) else {
            uploadStatus = "Log folder could not be read. No files were uploaded."
            return []
        }

        let uploaded = uploadedFileNames()
        let liveFileName = DiagnosticLog.shared.currentFileURL.lastPathComponent
        let now = Date()

        // Per-reason counters, logged below. A no-upload run is otherwise impossible to
        // explain from the outside: "already sent", "still being written" and "nothing
        // there at all" produce the same silence.
        var skippedLive = 0, skippedUploaded = 0, skippedInFlight = 0, skippedRecent = 0, skippedConsent = 0

        let selected = selectedFiles.map { Set($0.map(\.standardizedFileURL)) }
        let result = urls.filter { url in
            if let selected, !selected.contains(url.standardizedFileURL) { return false }
            guard url.pathExtension == "ndjson", let consent = Self.consentDate(defaults: defaults) else {
                skippedConsent += 1; return false
            }
            // Explicit selection authorizes uploading older recordings too. Automatic
            // background uploads remain restricted to files created after consent.
            if selected == nil {
                guard let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
                      created >= consent else { skippedConsent += 1; return false }
            }
            if url.lastPathComponent == liveFileName { skippedLive += 1; return false }
            if uploaded.contains(url.lastPathComponent) { skippedUploaded += 1; return false }
            if inFlight.contains(url.lastPathComponent) { skippedInFlight += 1; return false }

            // Unknown modification date → treat as possibly open and skip.
            guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate else { skippedRecent += 1; return false }
            if !url.lastPathComponent.hasPrefix("recording-"),
               now.timeIntervalSince(modified) < DiagnosticLog.activeFileGraceInterval {
                skippedRecent += 1
                return false
            }
            return true
        }

        log.info("""
            upload scan pending=\(result.count, privacy: .public) \
            skippedUploaded=\(skippedUploaded, privacy: .public) \
            skippedRecent=\(skippedRecent, privacy: .public) \
            skippedInFlight=\(skippedInFlight, privacy: .public) \
            skippedLive=\(skippedLive, privacy: .public)
            """)

        if result.isEmpty {
            uploadStatus = "No eligible closed logs. Active: \(skippedLive), recent (wait 60s): \(skippedRecent), before consent/unavailable date: \(skippedConsent), sent: \(skippedUploaded), queued: \(skippedInFlight)."
        }
        return result
    }

    // MARK: Presign + PUT

    private func presignThenUpload(fileURL: URL, installID: String) {
        guard let consent = Self.consentDate(defaults: defaults) else { releaseClaim(fileURL.lastPathComponent); return }
        let sessionID = Self.sessionIdentifier(for: fileURL)
        let ts = Self.timestampMillis(for: fileURL)   // unix millis, from the file

        let request: URLRequest
        do { request = try presignRequest(installID: installID, sessionID: sessionID, timestamp: ts) }
        catch {
            uploadStatus = DiagnosticUploadProtocol.networkMessage(error)
            releaseClaim(fileURL.lastPathComponent)
            return
        }

        // The presign GET runs on `presignSession` (a standard ephemeral session), NOT
        // on the background session: a background session rejects completion-handler
        // tasks by raising an uncaught exception. The presign is small and completes
        // promptly while the app still has background execution time; if it is
        // interrupted the file is simply retried next cycle. Only the file PUT below
        // needs to survive suspension, and that one uses the background session.
        let task = presignSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            Task { @MainActor in
                do {
                    if let error { throw error }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    let url = try DiagnosticUploadProtocol.uploadURL(data: data ?? Data(), status: status)
                    self.putFile(fileURL: fileURL, to: url, consent: consent)
                } catch {
                    self.uploadStatus = DiagnosticUploadProtocol.networkMessage(error)
                    self.log.error("presign failed: \(self.uploadStatus, privacy: .public)")
                    self.releaseClaim(fileURL.lastPathComponent)
                }
            }
        }
        task.resume()
    }

    /// PUT a coordinate-redacted copy; the local source remains unchanged. On a background URLSession, `uploadTask(with:fromFile:)`
    /// is what survives suspension — the upload continues (and can relaunch the app)
    /// after the user leaves. Completion is handled in the delegate, which marks the
    /// file uploaded only on a 2xx.
    private func putFile(fileURL: URL, to uploadURL: URL, consent: Date) {
        guard Self.consentDate(defaults: defaults) == consent, uploadURL.scheme == "https" else {
            releaseClaim(fileURL.lastPathComponent); return
        }
        Task { @MainActor [weak self] in
        guard let self else { return }
        let copy: URL
        do { copy = try await Task.detached(priority: .utility) { try Self.redactedCopy(of: fileURL) }.value }
        catch {
            uploadStatus = "Could not prepare a redacted log. The original is kept on this phone."
            releaseClaim(fileURL.lastPathComponent); return
        }
        guard Self.consentDate(defaults: defaults) == consent else {
            releaseClaim(fileURL.lastPathComponent); return
        }
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Content-Type")

        uploadStatus = "Uploading \(fileURL.lastPathComponent) over Wi-Fi."
        let task = session.uploadTask(with: request, fromFile: copy)
        // Stash the source file name so the delegate can mark it uploaded on success.
        task.taskDescription = fileURL.lastPathComponent
        task.resume()
        }
    }

    nonisolated static func consentDate(defaults: UserDefaults = .standard) -> Date? {
        guard defaults.bool(forKey: "beta.uploadConsent"),
              defaults.double(forKey: "beta.uploadConsentSince") > 0 else { return nil }
        return Date(timeIntervalSince1970: defaults.double(forKey: "beta.uploadConsentSince"))
    }

    func privacyDidChange() {
        guard Self.consentDate(defaults: defaults) == nil else { return }
        presignSession.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        inFlight.removeAll()
        activeCount = 0
        uploadStatus = "Sharing is off. Pending transfers were cancelled."
        endBackgroundAssertion()
    }

    /// Fail closed on malformed NDJSON; never fall back to uploading raw bytes.
    nonisolated static func redactedData(_ data: Data) throws -> Data {
        func scrub(_ value: Any) -> Any {
            if let object = value as? [String: Any] {
                let blocked: Set<String> = ["latitude", "longitude", "lat", "lon", "lng", "altitude", "coordinate", "coordinates"]
                return object.reduce(into: [String: Any]()) { result, pair in
                    if !blocked.contains(pair.key.lowercased()) { result[pair.key] = scrub(pair.value) }
                }
            }
            if let array = value as? [Any] { return array.map(scrub) }
            return value
        }
        var result = Data()
        for line in data.split(separator: 10) where !line.isEmpty {
            let object = try JSONSerialization.jsonObject(with: Data(line))
            result.append(try JSONSerialization.data(withJSONObject: scrub(object), options: [.sortedKeys]))
            result.append(10)
        }
        return result
    }

    nonisolated private static func redactedCopy(of source: URL) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("beta-redacted", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appendingPathComponent(source.lastPathComponent)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: copy.path, contents: nil)
        let output = try FileHandle(forWritingTo: copy)
        defer { try? output.close() }
        var pending = Data()
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            pending.append(chunk)
            if let last = pending.lastIndex(of: 10) {
                try output.write(contentsOf: redactedData(Data(pending[...last])))
                pending = Data(pending[pending.index(after: last)...])
            }
        }
        if !pending.isEmpty { try output.write(contentsOf: redactedData(pending)) }
        return copy
    }

    // MARK: Uploaded-set persistence

    private func uploadedFileNames() -> Set<String> {
        let arr = defaults.stringArray(forKey: Self.uploadedKey) ?? []
        return Set(arr)
    }

    fileprivate func markUploaded(_ fileName: String) {
        var set = uploadedFileNames()
        set.insert(fileName)
        defaults.set(Array(set), forKey: Self.uploadedKey)
    }

    /// Release an `inFlight` claim. Called on completion (success or failure) and on
    /// every presign bail-out, so a file that genuinely failed becomes a candidate
    /// again on the next background cycle rather than being stuck forever.
    fileprivate func releaseClaim(_ fileName: String) {
        inFlight.remove(fileName)
        activeCount = inFlight.count
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("beta-redacted")
            .appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: copy)
        // Cycle drained — stop asking iOS to keep us awake.
        if inFlight.isEmpty { endBackgroundAssertion() }
    }

    // MARK: Background-task assertion

    private func beginBackgroundAssertion() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "beta.diagupload"
        ) { [weak self] in
            // iOS is out of patience. Release the assertion so we are not killed for
            // holding it; unfinished files stay unmarked and retry next cycle.
            Task { @MainActor in
                self?.log.error("background assertion expired with uploads outstanding")
                self?.endBackgroundAssertion()
            }
        }
    }

    private func endBackgroundAssertion() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    /// Delete a log file whose upload S3 confirmed with a 2xx.
    ///
    /// The bytes are durable in the bucket — an S3 PUT is atomic, so a 200 means the
    /// whole object is stored — and the bucket's lifecycle rule owns retention from
    /// there. Keeping a second copy on the phone only grows `<Documents>/logs`, which
    /// is what let it reach 16 files before the first upload ever ran.
    ///
    /// Re-checks that the file is neither the live session file nor recently modified
    /// before unlinking. `pendingFiles()` already applied both tests when the file was
    /// claimed, so this should never fire — it is here because the cost of being wrong
    /// is a rider's in-progress raw recording being written to a vanished inode.
    fileprivate func deleteUploadedFile(named fileName: String) {
        guard fileName != DiagnosticLog.shared.currentFileURL.lastPathComponent else { return }

        let url = logDirectory.appendingPathComponent(fileName)
        guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate,
              Date().timeIntervalSince(modified) >= DiagnosticLog.activeFileGraceInterval
        else { return }

        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - URLSessionTaskDelegate

extension BetaDiagnosticUploader: URLSessionTaskDelegate {

    /// A background upload task completed. Mark the source file uploaded only on a
    /// 2xx response; anything else is left un-marked so it is retried next cycle.
    nonisolated func urlSession(_ session: URLSession,
                                task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        let fileName = task.taskDescription
        let statusCode = (task.response as? HTTPURLResponse)?.statusCode ?? -1
        let succeeded = (error == nil) && (200..<300).contains(statusCode)
        // Captured here as a String: `Error` is not safely sendable across the actor
        // hop below, and without it a `status -1` (no HTTP response at all) says only
        // "something went wrong at the transport layer" — which is the difference
        // between a network blip that URLSession will retry and a systematic fault.
        let errorText = error.map { DiagnosticUploadProtocol.networkMessage($0) }

        Task { @MainActor [weak self] in
            guard let self else { return }
            if let fileName, !fileName.isEmpty {
                // Always release the claim: on success the file is recorded in
                // `uploadedKey` and will never be a candidate again; on failure it
                // must become a candidate again for the next cycle.
                self.releaseClaim(fileName)
            }
            if succeeded, let fileName, !fileName.isEmpty {
                self.markUploaded(fileName)
                self.uploadStatus = "Uploaded \(fileName) to S3."
                // Keep the local raw original; normal storage-budget cleanup owns it.
                self.log.info("uploaded \(fileName, privacy: .public)")
            } else {
                self.uploadStatus = errorText ?? DiagnosticUploadProtocol.Failure.http(stage: "S3", status: statusCode).localizedDescription
                self.log.error("""
                    upload failed status=\(statusCode, privacy: .public) \
                    error=\(errorText ?? "none", privacy: .public); will retry next cycle
                    """)
            }
        }
    }
}

private struct BetaUploaderEnvironmentKey: EnvironmentKey {
    static let defaultValue: BetaDiagnosticUploader? = nil
}
extension EnvironmentValues {
    var betaUploader: BetaDiagnosticUploader? {
        get { self[BetaUploaderEnvironmentKey.self] }
        set { self[BetaUploaderEnvironmentKey.self] = newValue }
    }
}

struct BetaUploadPanel: View {
    @ObservedObject var uploader: BetaDiagnosticUploader
    var body: some View {
        TelemetryCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("DIAGNOSTIC UPLOADS").font(.headline)
                Text(uploader.endpointHost).font(.caption).foregroundStyle(.secondary)
                Text(uploader.connectionTitle).font(.headline)
                Text(uploader.connectionDetail).font(.footnote)
                if let checked = uploader.lastChecked {
                    Text("Checked \(checked.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(uploader.checkingConnection ? "Checking…" : "Test connection") {
                    Task { await uploader.testConnection() }
                }
                .disabled(uploader.checkingConnection)
                Text("Sends a tiny synthetic test file over Wi-Fi. No ride data is included.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text(uploader.uploadStatus).font(.footnote)
                Text("Eligible at last scan: \(uploader.pendingCount) · Active: \(uploader.activeCount)")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Upload pending logs") { uploader.start() }
                Text("Log sharing must be enabled. Only closed logs created after consent are eligible; recently changed logs wait 60 seconds.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
#endif
