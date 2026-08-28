import SwiftUI
import AVFoundation

@main
struct WheelieTrackerApp: App {
    @State private var calibrationService = CalibrationService()
    @State private var runRepository = RunRepository()
    @State private var riderPreferences = RiderPreferences()

    init() {
        configureAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(calibrationService)
                .environment(runRepository)
                .environment(riderPreferences)
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
