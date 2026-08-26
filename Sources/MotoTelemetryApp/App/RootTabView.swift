import SwiftUI

struct RootTabView: View {
    @State private var calibrationService = CalibrationService()
    @State private var preferences = RiderPreferences()
    @State private var runRepository = RunRepository()

    var body: some View {
        TabView {
            LiveWheelieView(
                calibrationService: calibrationService,
                preferences: preferences
            )
            .tabItem {
                Label("Live", systemImage: "gauge")
            }

            PastRunsView(repository: runRepository)
                .tabItem {
                    Label("Runs", systemImage: "list.bullet")
                }
        }
        .preferredColorScheme(.dark)
    }
}
