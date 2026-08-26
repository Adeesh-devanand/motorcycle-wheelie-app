import SwiftUI

/// Floating recording controls: record/stop, in-ride marker, timer, mode badge.
/// Bench mode shows 'keep still'. Vibration shows RPM prompt.
struct RecordingControlsView: View {
    let mode: RecordingMode
    let isRecording: Bool
    let elapsed: TimeInterval
    let onRecord: () -> Void
    let onStop: () -> Void
    let onMarker: () -> Void

    @State private var showRPMPrompt = false

    var body: some View {
        VStack(spacing: AppSpacing.md) {
            // Mode badge + timer
            HStack {
                modeBadge
                Spacer()
                if isRecording {
                    timerDisplay
                }
            }

            // Mode-specific prompt
            if isRecording {
                promptForMode
            }

            // Controls
            HStack(spacing: AppSpacing.xl) {
                if isRecording {
                    markerButton
                }
                recordStopButton
            }
        }
        .padding(AppSpacing.lg)
        .background(
            RoundedRectangle(cornerRadius: AppSpacing.CornerRadius.card)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
        .accessibilityElement(children: .contain)
    }

    // MARK: - Mode Badge

    private var modeBadge: some View {
        HStack(spacing: AppSpacing.xs) {
            Circle()
                .fill(isRecording ? Color(hex: 0xFF6B6B) : AppColors.textSecondary)
                .frame(width: 8, height: 8)
                .opacity(isRecording ? 1 : 0.6)

            Text(mode.title.uppercased())
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .foregroundStyle(AppColors.textSecondary)
        }
    }

    // MARK: - Timer

    private var timerDisplay: some View {
        Text(formatTimer(elapsed))
            .font(.system(.title3, design: .monospaced, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(AppColors.textPrimary)
            .accessibilityLabel("Elapsed time \(formatTimer(elapsed))")
    }

    // MARK: - Mode Prompts

    @ViewBuilder
    private var promptForMode: some View {
        switch mode {
        case .ride:
            EmptyView()
        case .bench:
            Text("Keep phone still on mount")
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(AppColors.textSecondary)
                .accessibilityLabel("Keep phone still on mount for bench test")
        case .vibration:
            Button {
                showRPMPrompt = true
            } label: {
                HStack(spacing: AppSpacing.xs) {
                    Image(systemName: "gauge.high")
                    Text("Set target RPM")
                }
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(Color(hex: 0xFDCB6E))
            }
            .alert("Target RPM", isPresented: $showRPMPrompt) {
                TextField("RPM", text: .constant(""))
                    .keyboardType(.numberPad)
                Button("OK") {}
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter the RPM you'll hold steady for this vibration recording.")
            }
        }
    }

    // MARK: - Record/Stop Button

    private var recordStopButton: some View {
        Button {
            if isRecording {
                onStop()
            } else {
                onRecord()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(isRecording ? Color(hex: 0xFF6B6B) : Color(hex: 0x10B9B7))
                    .frame(width: 64, height: 64)

                if isRecording {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.white)
                        .frame(width: 20, height: 20)
                } else {
                    Circle()
                        .fill(.white)
                        .frame(width: 24, height: 24)
                }
            }
        }
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }

    // MARK: - Marker Button

    private var markerButton: some View {
        Button(action: onMarker) {
            VStack(spacing: AppSpacing.xxs) {
                Image(systemName: "flag.fill")
                    .font(.title3)
                    .foregroundStyle(Color(hex: 0xFDCB6E))
                Text("MARK")
                    .font(.system(.caption2, weight: .medium))
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
        .accessibilityLabel("Add in-ride marker")
        .accessibilityHint("Also triggered by volume button")
    }

    // MARK: - Helpers

    private func formatTimer(_ t: TimeInterval) -> String {
        let mins = Int(t) / 60
        let secs = Int(t) % 60
        let tenths = Int((t - Double(Int(t))) * 10)
        return String(format: "%d:%02d.%d", mins, secs, tenths)
    }
}
