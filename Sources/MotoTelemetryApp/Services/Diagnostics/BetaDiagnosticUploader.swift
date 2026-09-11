//
//  BetaDiagnosticUploader.swift
//
//  ANONYMOUS BETA DIAGNOSTIC-LOG UPLOAD — BETA BUILDS ONLY.
//
//  ============================================================================
//  #if BETA GATING (read this first)
//  ============================================================================
//  EVERY line of this file is wrapped in `#if BETA ... #endif`. The `BETA`
//  compilation condition is set ONLY in a beta-capable build configuration
//  (currently the app target's Debug config → Debug / TestFlight builds). In a
//  Release / App Store build `BETA` is NOT defined, so this entire file compiles
//  to nothing: no uploader type exists, no network code is linked, and no call
//  site referencing it compiles either (the trigger in the app scene is itself
//  under `#if BETA`). Nothing here ships to production.
//
//  As a second, independent safety net, the API base URL and auth token are read
//  at runtime from `Bundle.main.infoDictionary` (Info.plist keys `BetaUploadAPIBase`
//  and `BetaUploadToken`, populated from build settings). Those settings are set
//  ONLY in the beta config and left EMPTY in Release, so even if this code were
//  ever compiled into a non-beta build, `makeUploader()` returns nil and the
//  uploader no-ops — it cannot make a network call without a configured base URL.
//
//  ============================================================================
//  SHARED CONTRACT (the AWS backend is built in parallel to THIS exact contract)
//  ============================================================================
//  1. Presign:
//       GET {API_BASE}/presign?installID=<uuid>&session=<sessionID>&ts=<unixMillis>
//       Header:  X-Beta-Key: <token>
//     Response JSON:
//       { "uploadURL": "<presigned PUT url>", "key": "...", "expiresIn": 900 }
//
//  2. Upload:
//       HTTP PUT the RAW file bytes to uploadURL
//       Header:  Content-Type: application/x-ndjson
//
//  ============================================================================
//  BEHAVIOUR
//  ============================================================================
//  • Source files: the app's existing NDJSON logs in `DiagnosticLog.shared.logDirectory`
//    (`<Documents>/logs/`) — both `session-*.ndjson` and `raw-*.ndjson`. We do NOT
//    invent a new log store; we upload the files the app already writes.
//  • Triggered on app background only (never mid-ride) — see the scene hook in
//    `WheelieTrackerApp` / `RootTabView`, also under `#if BETA`.
//  • Uploads run on a URLSession *background* configuration so they survive app
//    suspension.
//  • Already-uploaded file names are recorded in UserDefaults so a file is never
//    re-sent. The file currently being written (DiagnosticLog's `currentFileURL`)
//    is skipped so we never upload a live, still-growing file.
//  • All failures are swallowed quietly and simply retried on the next background
//    cycle — a beta telemetry upload must never disrupt the app.
//

#if BETA
import Foundation
import UIKit
import os

// MARK: - Anonymous per-install ID

/// Anonymous, per-install identifier for beta diagnostic-log upload.
///
/// A single random `UUID` generated ONCE on first access and persisted in
/// `UserDefaults` under `beta.installID`. No account, no login, no PII: a fresh
/// v4 UUID with no derivation from device or user, so it cannot be correlated to
/// a person — it exists only so the backend can group uploads from the same
/// install. Compiled only under `BETA`, so production never generates or stores it.
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
final class BetaDiagnosticUploader: NSObject {

    // MARK: Configuration read from Info.plist (empty in production → no-op)

    private let apiBase: URL
    private let token: String

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
        config.allowsCellularAccess = true
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
    private lazy var presignSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.allowsCellularAccess = true
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    private let log = Logger(subsystem: "com.mototelemetry.app", category: "beta.upload")

    // MARK: Init

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

        // Reject a value that still contains an UNEXPANDED build-setting
        // placeholder. The Info.plist carries these as `$(BetaUploadAPIBase)` /
        // `$(BetaUploadToken)` and relies on the plist step expanding them; if that
        // ever stops happening, the literal string arrives here instead. That must
        // not be treated as configured: `URL(string: "$(BetaUploadAPIBase)")`
        // returns a NON-nil *relative* URL, so the guard below would pass and the
        // uploader would fail later at request time with nothing pointing at the
        // real cause. Requiring an absolute https URL with a host turns a silent
        // misconfiguration into a clean no-op plus one log line.
        guard !baseString.contains("$("), !token.contains("$(") else {
            Logger(subsystem: "com.mototelemetry.app", category: "beta.upload")
                .error("beta upload config not expanded — check Info.plist $( ) substitution")
            return nil
        }

        guard !baseString.isEmpty, !token.isEmpty,
              let base = URL(string: baseString),
              base.scheme == "https", base.host != nil else {
            // Logged rather than returning nil silently. A silent nil is how an
            // upload failure presents as "absolutely nothing happens, anywhere" —
            // no cycle line, no error — which is genuinely hard to diagnose. The
            // usual cause is a missing or unwired BetaUpload.xcconfig, so name it.
            Logger(subsystem: "com.mototelemetry.app", category: "beta.upload")
                .error("""
                    beta upload disabled: config missing or invalid \
                    (baseEmpty=\(baseString.isEmpty, privacy: .public) \
                    tokenEmpty=\(token.isEmpty, privacy: .public)) \
                    — check BetaUpload.xcconfig is present and wired as the app \
                    target's Debug base configuration
                    """)
            return nil
        }
        return BetaDiagnosticUploader(apiBase: base, token: token,
                                      logDirectory: logDirectory)
    }

    /// `nonisolated` for the same reason as `makeUploader` — it only assigns
    /// immutable stored properties, so it needs no main-actor hop.
    nonisolated private init(apiBase: URL, token: String, logDirectory: URL) {
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
    func start() {
        let installID = BetaInstallID.current

        // Unconditional entry line. Without it, "the scene-phase trigger never fired"
        // and "it fired and found nothing to send" are indistinguishable in the log —
        // which is exactly the ambiguity that made a no-upload run undiagnosable.
        log.info("upload cycle start")

        let candidates = pendingFiles()
        guard !candidates.isEmpty else { return }

        beginBackgroundAssertion()

        for fileURL in candidates {
            // Claim the file BEFORE any async work so a second `start()` in the same
            // backgrounding cannot pick it up again (see `inFlight`).
            inFlight.insert(fileURL.lastPathComponent)

            presignThenUpload(fileURL: fileURL, installID: installID)
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
    private func pendingFiles() -> [URL] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }

        let uploaded = uploadedFileNames()
        let liveFileName = DiagnosticLog.shared.currentFileURL.lastPathComponent
        let now = Date()

        // Per-reason counters, logged below. A no-upload run is otherwise impossible to
        // explain from the outside: "already sent", "still being written" and "nothing
        // there at all" produce the same silence.
        var skippedLive = 0, skippedUploaded = 0, skippedInFlight = 0, skippedRecent = 0

        let result = urls.filter { url in
            guard url.pathExtension == "ndjson" else { return false }
            if url.lastPathComponent == liveFileName { skippedLive += 1; return false }
            if uploaded.contains(url.lastPathComponent) { skippedUploaded += 1; return false }
            if inFlight.contains(url.lastPathComponent) { skippedInFlight += 1; return false }

            // Unknown modification date → treat as possibly open and skip.
            guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate else { skippedRecent += 1; return false }
            if now.timeIntervalSince(modified) < DiagnosticLog.activeFileGraceInterval {
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

        return result
    }

    // MARK: Presign + PUT

    private func presignThenUpload(fileURL: URL, installID: String) {
        let sessionID = Self.sessionIdentifier(for: fileURL)
        let ts = Self.timestampMillis(for: fileURL)   // unix millis, from the file

        var components = URLComponents(url: apiBase.appendingPathComponent("presign"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "installID", value: installID),
            URLQueryItem(name: "session", value: sessionID),
            URLQueryItem(name: "ts", value: String(ts)),
        ]
        guard let presignURL = components?.url else { return }

        var request = URLRequest(url: presignURL)
        request.httpMethod = "GET"
        request.setValue(token, forHTTPHeaderField: "X-Beta-Key")

        // The presign GET runs on `presignSession` (a standard ephemeral session), NOT
        // on the background session: a background session rejects completion-handler
        // tasks by raising an uncaught exception. The presign is small and completes
        // promptly while the app still has background execution time; if it is
        // interrupted the file is simply retried next cycle. Only the file PUT below
        // needs to survive suspension, and that one uses the background session.
        let task = presignSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                self.log.error("presign failed: \(error.localizedDescription, privacy: .public)")
                Task { @MainActor in self.releaseClaim(fileURL.lastPathComponent) }
                return
            }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let uploadURLString = json["uploadURL"] as? String,
                  let uploadURL = URL(string: uploadURLString) else {
                self.log.error("presign returned no usable uploadURL")
                Task { @MainActor in self.releaseClaim(fileURL.lastPathComponent) }
                return
            }
            // Hop back to the main actor to touch the actor-isolated session/state.
            Task { @MainActor in
                self.putFile(fileURL: fileURL, to: uploadURL)
            }
        }
        task.resume()
    }

    /// PUT the raw file bytes. On a background URLSession, `uploadTask(with:fromFile:)`
    /// is what survives suspension — the upload continues (and can relaunch the app)
    /// after the user leaves. Completion is handled in the delegate, which marks the
    /// file uploaded only on a 2xx.
    private func putFile(fileURL: URL, to uploadURL: URL) {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Content-Type")

        let task = session.uploadTask(with: request, fromFile: fileURL)
        // Stash the source file name so the delegate can mark it uploaded on success.
        task.taskDescription = fileURL.lastPathComponent
        task.resume()
    }

    // MARK: Uploaded-set persistence

    private func uploadedFileNames() -> Set<String> {
        let arr = UserDefaults.standard.stringArray(forKey: Self.uploadedKey) ?? []
        return Set(arr)
    }

    fileprivate func markUploaded(_ fileName: String) {
        var set = uploadedFileNames()
        set.insert(fileName)
        UserDefaults.standard.set(Array(set), forKey: Self.uploadedKey)
    }

    /// Release an `inFlight` claim. Called on completion (success or failure) and on
    /// every presign bail-out, so a file that genuinely failed becomes a candidate
    /// again on the next background cycle rather than being stuck forever.
    fileprivate func releaseClaim(_ fileName: String) {
        inFlight.remove(fileName)
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
        let errorText = error?.localizedDescription ?? "none"

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
                self.deleteUploadedFile(named: fileName)
                self.log.info("uploaded \(fileName, privacy: .public)")
            } else {
                self.log.error("""
                    upload failed status=\(statusCode, privacy: .public) \
                    error=\(errorText, privacy: .public); will retry next cycle
                    """)
            }
        }
    }
}
#endif
