import SwiftUI

/// Settings: speed on/off, gauge maximum, about.
///
/// Two sections that used to be here are gone, both for the same reason — they
/// presented controls that did nothing:
///
/// - **Bike.** It navigated to `BikeProfileSetupView` to pick an "Active Bike", but
///   `WheelieRun` has no bike field, so the selection could not reach a recorded
///   run. The beta audit removed the wizard's false "Mount rotation matrix saved"
///   label and left its dead `editingProfile` alone to keep that diff scoped, which
///   is why the entry point outlived the thing it was for. Nothing downstream reads
///   `BikeProfileStore.selectedProfile`, so choosing a bike changed a label and
///   nothing else. Per-bike profiles need a bike field on `WheelieRun` first.
/// - **Audio Cues.** Three `Toggle`s bound to `.constant(true)`: they rendered in
///   the on position, ignored taps, and there is no `cueEnabled` in
///   `RiderPreferences` for them to write to. `CueAudioRenderer` is always on and
///   driven by angle alone. Hidden rather than deleted (see `hiddenAudioCueSection`)
///   because the controls are wanted once the preference they need exists.
struct SettingsView: View {
    @State private var preferences: RiderPreferences

    init(preferences: RiderPreferences) {
        _preferences = State(wrappedValue: preferences)
    }

    var body: some View {
        List {
            Section("Speed") {
                // No unit picker: speed is km/h throughout. An mph option existed but
                // only changed the LABEL, never the value — it displayed km/h numbers
                // under an "mph" heading. A fabricated input is worse than a missing
                // one, so the app is km/h-only until a real conversion is wired.
                Toggle("Speedometer", isOn: $preferences.speedEnabled)

                if preferences.speedEnabled {
                    gaugeMaximumField
                } else {
                    Text("Speed is off: the live speed meter is hidden, GNSS is not "
                         + "read for a speed, and new runs record 0 for speed. "
                         + "Angle is unaffected.")
                        .font(.footnote)
                        .foregroundStyle(AppColors.textSecondary)
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

    // MARK: - Gauge maximum

    /// A menu of allowed ceilings, not a typed number.
    ///
    /// It WAS a text field, replacing an older five-preset picker, on the reasoning that a
    /// rider whose ceiling is 140 had no way to say so. That reasoning was wrong in a way
    /// only visible on the meter: the live scale divides its range into
    /// `MeterScale.divisions` (6) so the speed axis matches the 0-90 deg angle axis beside
    /// it, and an arbitrary ceiling makes those six steps fractional — 140 gives 23.33, and
    /// an axis labelled 0/23/47/70/93/117/140. So the ceiling is not actually a free
    /// parameter; it has to be a multiple of 30. A menu states that constraint instead of
    /// letting the rider type a value the app then silently moves.
    private var gaugeMaximumField: some View {
        Picker("Gauge Maximum", selection: $preferences.speedGaugeMaximum) {
            ForEach(RiderPreferences.gaugeMaximumOptions, id: \.self) { option in
                Text("\(Int(option)) km/h").tag(option)
            }
        }
    }

    // MARK: - Hidden: audio cue controls

    /// Kept, unreferenced, as the shape these controls should take once
    /// `RiderPreferences` carries the flags. Restoring it means adding
    /// `cueEnabled` / `cueApproachEnabled` / `hapticsEnabled` and binding to
    /// those — NOT re-adding `.constant(true)`, which is what made the originals
    /// decorative. `#if false` rather than a comment block so it stays
    /// syntax-checked by anyone editing this file.
    #if false
    private var hiddenAudioCueSection: some View {
        Section("Audio Cues") {
            Toggle("In-range tone", isOn: $preferences.cueEnabled)
            Toggle("Approaching tone", isOn: $preferences.cueApproachEnabled)
            Toggle("Haptic feedback", isOn: $preferences.hapticsEnabled)
        }
    }
    #endif

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}
