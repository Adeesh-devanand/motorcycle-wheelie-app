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

    // MARK: URLSession (background configuration → survives suspension)

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(
            withIdentifier: "com.mototelemetry.beta.diagupload")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private let log = Logger(subsystem: "com.mototelemetry.app", category: "beta.upload")

    // MARK: Init

    /// Builds an uploader ONLY if both Info.plist keys are present and non-empty.
    /// Returns nil in production (empty settings) so callers get a clean no-op.
    static func makeUploader(
        logDirectory: URL = DiagnosticLog.shared.logDirectory
    ) -> BetaDiagnosticUploader? {
        let info = Bundle.main.infoDictionary
        let baseString = (info?["BetaUploadAPIBase"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let token = (info?["BetaUploadToken"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !baseString.isEmpty, !token.isEmpty,
              let base = URL(string: baseString) else {
            return nil
        }
        return BetaDiagnosticUploader(apiBase: base, token: token,
                                      logDirectory: logDirectory)
    }

    private init(apiBase: URL, token: String, logDirectory: URL) {
        self.apiBase = apiBase
        self.token = token
        self.logDirectory = logDirectory
        super.init()
    }

    // MARK: Public entry point

    /// Scan the log directory and upload every `.ndjson` file that has not already
    /// been uploaded and is not the currently-open log file. Fire-and-forget:
    /// per-file failures are logged and left for the next cycle.
    func start() {
        let installID = BetaInstallID.current
        // One session id per upload cycle, purely for backend correlation of this
        // batch. The log files carry their own provenance in their header line.
        let sessionID = UUID().uuidString

        let candidates = pendingFiles()
        guard !candidates.isEmpty else { return }

        for fileURL in candidates {
            presignThenUpload(fileURL: fileURL,
                              installID: installID,
                              sessionID: sessionID)
        }
    }

    // MARK: File discovery

    /// `.ndjson` files in the log directory that are NOT already uploaded and are
    /// NOT the file currently being written by `DiagnosticLog`.
    private func pendingFiles() -> [URL] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: nil) else { return [] }

        let uploaded = uploadedFileNames()
        let liveFileName = DiagnosticLog.shared.currentFileURL.lastPathComponent

        return urls.filter { url in
            url.pathExtension == "ndjson"
                && url.lastPathComponent != liveFileName
                && !uploaded.contains(url.lastPathComponent)
        }
    }

    // MARK: Presign + PUT

    private func presignThenUpload(fileURL: URL, installID: String, sessionID: String) {
        let ts = Int(Date().timeIntervalSince1970 * 1000)   // unix millis

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

        // The presign GET uses a plain data task; only the large file PUT uses the
        // background session's upload task. A background config still supports data
        // tasks, but they do not run while suspended — the presign is small and
        // completes promptly, and if it is interrupted the file is simply retried
        // next cycle.
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                self.log.error("presign failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let uploadURLString = json["uploadURL"] as? String,
                  let uploadURL = URL(string: uploadURLString) else {
                self.log.error("presign returned no usable uploadURL")
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

        Task { @MainActor [weak self] in
            guard let self else { return }
            if succeeded, let fileName, !fileName.isEmpty {
                self.markUploaded(fileName)
                self.log.info("uploaded \(fileName, privacy: .public)")
            } else {
                self.log.error("upload failed (status \(statusCode)); will retry next cycle")
            }
        }
    }
}
#endif
