import SwiftUI

/// Owns the service graph for the whole app. `RunRecorder` is the live data
/// source — it owns the pipeline, feeds `CalibrationService` every raw IMU
/// sample, and persists a completed run to `RunRepository` when an attempt ends
/// (ui-spec §7.6). Nothing here is optional: with no recorder there is no
/// pipeline, so the meters read zero and Past Runs stays empty forever.
struct RootTabView: View {
    @State private var services = ServiceGraph()

    var body: some View {
        TabView {
            LiveWheelieView(
                calibrationService: services.calibration,
                preferences: services.preferences,
                recorder: services.recorder,
                bikeStore: services.bikeStore
            )
            .tabItem {
                Label("Live", systemImage: "gauge")
            }

            PastRunsView(repository: services.repository)
                .tabItem {
                    Label("Runs", systemImage: "list.bullet")
                }
        }
        .preferredColorScheme(.dark)
    }
}

/// Built once and held for the app's lifetime. Constructed eagerly rather than
/// lazily so the wiring is visible in one place and cannot half-exist.
@Observable
final class ServiceGraph {
    let preferences: RiderPreferences
    let calibration: CalibrationService
    let repository: RunRepository
    let recorder: RunRecorder
    let bikeStore: BikeProfileStore

    init() {
        let preferences = RiderPreferences()
        let calibration = CalibrationService()
        let repository = RunRepository()

        self.preferences = preferences
        self.calibration = calibration
        self.repository = repository
        self.bikeStore = BikeProfileStore()
        self.recorder = RunRecorder(
            motionService: MotionService(),
            speedService: SpeedService(),
            calibrationService: calibration,
            repository: repository
        )
    }
}
