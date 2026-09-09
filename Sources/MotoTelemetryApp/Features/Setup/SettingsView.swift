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

    /// Draft text for the gauge-maximum field. Held separately from the preference
    /// so a partially-typed value ("5" on the way to "50") is not committed and
    /// clamped to the minimum under the rider's fingers.
    @State private var gaugeMaximumDraft: String = ""
    @FocusState private var gaugeFieldFocused: Bool

    init(preferences: RiderPreferences) {
        _preferences = State(wrappedValue: preferences)
    }

    private var gaugeBounds: ClosedRange<Double> { RiderPreferences.gaugeMaximumRange }

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
        .onAppear { gaugeMaximumDraft = String(Int(preferences.speedGaugeMaximum)) }
        .onChange(of: gaugeFieldFocused) { _, focused in
            // Commit when focus LEAVES the field, so intermediate keystrokes are
            // never clamped mid-typing.
            if !focused { commitGaugeMaximum() }
        }
    }

    // MARK: - Gauge maximum

    /// A typed number rather than a preset picker, bounded 50–300 km/h. The old
    /// picker offered five fixed presets; a rider whose ceiling is 140 had no way to
    /// say so.
    private var gaugeMaximumField: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack {
                Text("Gauge Maximum")
                Spacer()
                TextField("100", text: $gaugeMaximumDraft)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .focused($gaugeFieldFocused)
                    .frame(width: 70)
                    .onSubmit { commitGaugeMaximum() }
                Text("km/h")
                    .foregroundStyle(AppColors.textSecondary)
            }

            Text("\(Int(gaugeBounds.lowerBound))–\(Int(gaugeBounds.upperBound)) km/h")
                .font(.caption)
                .foregroundStyle(AppColors.textSecondary)

            if let pending = Double(gaugeMaximumDraft), !gaugeBounds.contains(pending) {
                // Say what will happen before it happens, rather than silently
                // rewriting the number the moment the field loses focus.
                Text("Will be adjusted to \(Int(RiderPreferences.clampGaugeMaximum(pending)))")
                    .font(.caption)
                    .foregroundStyle(AppColors.danger)
            }
        }
    }

    /// Commit the draft, or restore the live value if the draft is not a number.
    /// `RiderPreferences` clamps on write, so this cannot store an out-of-range
    /// ceiling even if the field is bypassed.
    private func commitGaugeMaximum() {
        guard let typed = Double(gaugeMaximumDraft) else {
            gaugeMaximumDraft = String(Int(preferences.speedGaugeMaximum))
            return
        }
        preferences.speedGaugeMaximum = typed
        gaugeMaximumDraft = String(Int(preferences.speedGaugeMaximum))
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
