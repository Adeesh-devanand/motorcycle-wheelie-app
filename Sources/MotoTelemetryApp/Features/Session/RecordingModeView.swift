import SwiftUI

/// Recording mode selection: ride, bench, vibration. Ride+bench NEVER request mic.
/// Vibration shows RPM prompt. Uses TelemetryCard for each mode option.
struct RecordingModeView: View {
    @Binding var selectedMode: RecordingMode
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: AppSpacing.lg) {
            Text("RECORDING MODE")
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(AppColors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(RecordingMode.allCases) { mode in
                modeCard(mode)
            }
        }
        .padding(.horizontal, AppSpacing.screenPadding)
        .accessibilityElement(children: .contain)
    }

    private func modeCard(_ mode: RecordingMode) -> some View {
        let isSelected = selectedMode == mode

        return Button {
            selectedMode = mode
            onStart()
        } label: {
            TelemetryCard {
                HStack(spacing: AppSpacing.md) {
                    Image(systemName: mode.icon)
                        .font(.title2)
                        .foregroundStyle(isSelected ? mode.accentColor : AppColors.textSecondary)
                        .frame(width: 40)

                    VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                        Text(mode.title)
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(AppColors.textPrimary)

                        Text(mode.description)
                            .font(.caption)
                            .foregroundStyle(AppColors.textSecondary)
                            .lineLimit(2)
                    }

                    Spacer()

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(mode.accentColor)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.CornerRadius.card)
                .strokeBorder(isSelected ? mode.accentColor.opacity(0.5) : .clear, lineWidth: 1.5)
        )
        .accessibilityLabel(mode.title)
        .accessibilityHint(mode.description)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Recording Mode

enum RecordingMode: String, CaseIterable, Identifiable {
    case ride
    case bench
    case vibration

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ride: "Ride"
        case .bench: "Bench Test"
        case .vibration: "Vibration Characterization"
        }
    }

    var description: String {
        switch self {
        case .ride:
            "Full wheelie recording — accelerometer, gyro, and GNSS. No microphone."
        case .bench:
            "Stationary sensor test — keep phone still on mount. Validates noise floor and mount stability. No microphone."
        case .vibration:
            "Engine vibration profiling at target RPM. Records accelerometer signature for aliasing detection."
        }
    }

    var icon: String {
        switch self {
        case .ride: "motorcycle"
        case .bench: "level"
        case .vibration: "waveform"
        }
    }

    var accentColor: Color {
        switch self {
        case .ride: Color(hex: 0x10B9B7)
        case .bench: Color(hex: 0x238CD8)
        case .vibration: Color(hex: 0xFDCB6E)
        }
    }

    /// Ride and bench NEVER request microphone access.
    var requestsMicrophone: Bool {
        switch self {
        case .ride, .bench: false
        case .vibration: false // Vibration uses accelerometer, not mic
        }
    }
}
