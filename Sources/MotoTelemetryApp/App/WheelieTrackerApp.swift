import SwiftUI
import AVFoundation

@main
struct WheelieTrackerApp: App {
    /// The ONE service graph for the process. `App` is instantiated once, so this
    /// `@State` default runs once and every service inside it is constructed once.
    ///
    /// It used to hold three services of its own and inject them into the
    /// environment while `RootTabView` built a separate `ServiceGraph` containing
    /// its OWN `CalibrationService` and `RunRepository`. Any view reading
    /// `@Environment` therefore observed different objects from the ones the recorder
    /// was actually driving — a silent split-brain on top of the duplicate-graph bug.
    @State private var services = ServiceGraph()

    /// Scene phase drives the BETA diagnostic-log upload trigger below. Reading it
    /// unconditionally (not under `#if BETA`) is harmless — it is a standard
    /// SwiftUI environment value — and keeps the `body` structure identical between
    /// the beta and production builds.
    @Environment(\.scenePhase) private var scenePhase

    #if BETA
    /// The anonymous diagnostic-log uploader. `nil` unless the beta Info.plist keys
    /// (`BetaUploadAPIBase` / `BetaUploadToken`) are populated, which they are only
    /// in a beta build — so this is a clean no-op even if BETA is compiled without
    /// the settings. Entire property is absent from a production build.
    @State private var betaUploader: BetaDiagnosticUploader? = BetaDiagnosticUploader.makeUploader()
    #endif

    init() {
        configureAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView(services: services)
                .environment(services.calibration)
                .environment(services.repository)
                .environment(services.preferences)
                #if BETA
                // BETA ONLY: attempt an upload at LAUNCH, not just on background.
                //
                // The background transition was the only trigger, and that made the
                // whole feature depend on a signal we could neither guarantee nor
                // observe: if `.background` is never delivered — the app killed from
                // Xcode's Stop button, force-quit from the app switcher — nothing
                // uploads and nothing is logged, which is exactly the dead end this
                // hit. `.task` runs when the root view appears, so it always fires.
                //
                // Launch is also the *better* moment: the previous session's files are
                // closed by then, and the app has full foreground time, so the presign
                // leg cannot be cut short by suspension. It never touches the live
                // session file — `pendingFiles()` excludes it by name.
                .task {
                    betaUploader?.start()
                }
                // BETA ONLY: on app background, upload not-yet-sent NDJSON diagnostic
                // logs. Never fires mid-ride (only on the background transition) and
                // the PUT uses a URLSession background config so it survives
                // suspension. Absent entirely from a production (non-BETA) build.
                .onChange(of: scenePhase) { _, newPhase in
                    // Logged unconditionally so a missing `.background` is visible
                    // rather than indistinguishable from "fired but found nothing".
                    betaUploader?.noteScenePhase(String(describing: newPhase))
                    if newPhase == .background {
                        betaUploader?.start()
                    }
                }
                #endif
        }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        DiagnosticLog.shared.log(.info, "app", "app launch — configuring audio session")
        do {
            try session.setCategory(.playback, options: .mixWithOthers)
            try session.setActive(true)
        } catch {
            // Audio cues will be unavailable; non-fatal.
            DiagnosticLog.shared.log(.warn, "app", "audio session config failed",
                                     ["code": Double((error as NSError).code)])
        }
    }
}
