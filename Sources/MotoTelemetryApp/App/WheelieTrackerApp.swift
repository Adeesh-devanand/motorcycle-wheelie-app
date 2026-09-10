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
                // BETA ONLY: on app background, upload not-yet-sent NDJSON diagnostic
                // logs. Never fires mid-ride (only on the background transition) and
                // uses a URLSession background config so the upload survives suspension.
                // Absent entirely from a production (non-BETA) build.
                .onChange(of: scenePhase) { _, newPhase in
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
