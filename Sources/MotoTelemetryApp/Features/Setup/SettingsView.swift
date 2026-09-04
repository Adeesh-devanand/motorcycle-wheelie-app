import SwiftUI

/// Settings: speed unit, gauge max, audio prefs, bike selection, about.
struct SettingsView: View {
    @State private var preferences: RiderPreferences
    @State private var bikeStore: BikeProfileStore

    init(preferences: RiderPreferences, bikeStore: BikeProfileStore) {
        _preferences = State(wrappedValue: preferences)
        _bikeStore = State(wrappedValue: bikeStore)
    }

    private let gaugeMaxPresets: [Double] = [60, 80, 100, 120, 160]

    var body: some View {
        List {
            Section("Speed") {
                // No unit picker: speed is km/h throughout. An mph option existed but
                // only changed the LABEL, never the value — it displayed km/h numbers
                // under an "mph" heading. A fabricated input is worse than a missing
                // one, so the app is km/h-only until a real conversion is wired.
                Picker("Gauge Maximum", selection: $preferences.speedGaugeMaximum) {
                    ForEach(gaugeMaxPresets, id: \.self) { value in
                        Text("\(Int(value)) km/h")
                            .tag(value)
                    }
                }
            }

            Section("Audio Cues") {
                Toggle("In-range tone", isOn: .constant(true))
                Toggle("Approaching tone", isOn: .constant(true))
                Toggle("Haptic feedback", isOn: .constant(true))
            }

            Section("Bike") {
                NavigationLink {
                    BikeProfileSetupView(store: bikeStore)
                } label: {
                    HStack {
                        Text("Active Bike")
                        Spacer()
                        Text(bikeStore.selectedProfile?.name ?? "None")
                            .foregroundStyle(AppColors.textSecondary)
                    }
                }
            }

            Section("About") {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Build", value: buildNumber)

                NavigationLink("Data Integrity") {
                    IntegrityReportView()
                }

                NavigationLink("Diagnostics") {
                    DiagnosticsView()
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppColors.background)
        .navigationTitle("Settings")
        .preferredColorScheme(.dark)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}
