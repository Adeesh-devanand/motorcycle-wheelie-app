import SwiftUI

/// Two short vertical rounded bars — the Live tab glyph from the mockup (M-UI7).
/// Rendered as a template image so the tab bar tints it for selected/unselected.
struct TwinMeterGlyph: View {
    var body: some View {
        HStack(spacing: 3) {
            Capsule().frame(width: 4, height: 15)
            Capsule().frame(width: 4, height: 20)
        }
        .frame(width: 24, height: 24)
    }
}

/// Owns the service graph for the whole app. `RunRecorder` is the live data
/// source — it owns the pipeline, feeds `CalibrationService` every raw IMU
/// sample, and persists a completed run to `RunRepository` when an attempt ends
/// (ui-spec §7.6). Nothing here is optional: with no recorder there is no
/// pipeline, so the meters read zero and Past Runs stays empty forever.
struct RootTabView: View {
    /// Injected by `WheelieTrackerApp` and held for the app lifetime.
    ///
    /// Deliberately a plain `let`, NOT `@State private var services = ServiceGraph()`.
    /// That form is a trap: the `@State` default-value autoclosure re-runs
    /// `ServiceGraph()` on every `RootTabView.init`. SwiftUI keeps only the first
    /// instance, but the throwaways are FULLY CONSTRUCTED first — and
    /// `ServiceGraph.init` eagerly builds `SpeedService`, which starts location
    /// authorization. So the side effects fire before the object is discarded. A
    /// device log shows three graphs built in one session: twice at launch (identity
    /// pass + first body pass) and twice more when a run was SAVED, because saving
    /// mutates the observable `RunRepository` that `body` depends on and re-runs
    /// `init`. The result was three `SpeedService` instances holding
    /// `bestForNavigation` GPS simultaneously, one of them reporting
    /// `first GNSS fix generation=0` while the live one was on generation 5.
    ///
    /// Do not wrap this in `@State` again.
    let services: ServiceGraph
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            LiveWheelieView(
                calibrationService: services.calibration,
                preferences: services.preferences,
                recorder: services.recorder,
                bikeStore: services.bikeStore
            )
            .tag(0)
            .tabItem {
                Label {
                    Text("Live")
                } icon: {
                    TwinMeterGlyph()
                }
            }

            PastRunsView(repository: services.repository)
                .tag(1)
                .tabItem {
                    Label("Runs", systemImage: "list.bullet")
                }
        }
        .tint(AppColors.accent)
        .preferredColorScheme(.dark)
        .onChange(of: selectedTab) { _, newValue in
            // BUG 2 context: leaving Live and returning is the reproduction. Logging
            // the tab change gives the sensor stream lifecycle a timeline anchor.
            DiagnosticLog.shared.log(.info, "app", "tab changed",
                                     ["tab": Double(newValue)])
        }
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
            repository: repository,
            cueRenderer: CueAudioRenderer()
        )
        DiagnosticLog.shared.log(.info, "app", "ServiceGraph constructed",
                                 ["motion": 1, "speed": 1, "calibration": 1,
                                  "repository": 1, "bikeStore": 1, "recorder": 1,
                                  "cueRenderer": 1])
    }
}
