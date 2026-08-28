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

    init() {
        configureAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView(services: services)
                .environment(services.calibration)
                .environment(services.repository)
                .environment(services.preferences)
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
