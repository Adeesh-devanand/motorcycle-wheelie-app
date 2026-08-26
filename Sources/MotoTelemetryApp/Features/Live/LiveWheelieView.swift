import SwiftUI

/// Main Live tab view — real-time angle + speed meters with target bands,
/// calibration overlay, and recording controls.
struct LiveWheelieView: View {
    @State private var viewModel: LiveWheelieViewModel

    init(calibrationService: CalibrationService, preferences: RiderPreferences) {
        _viewModel = State(wrappedValue: LiveWheelieViewModel(
            calibrationService: calibrationService,
            preferences: preferences
        ))
    }

    var body: some View {
        ZStack {
            AppColors.background
                .ignoresSafeArea()

            VStack(spacing: AppSpacing.lg) {
                // Header
                headerBar

                // Meters
                metersSection
                    .frame(maxHeight: .infinity)

                // Controls
                controlsSection
            }
            .padding(AppSpacing.screenPadding)

            // Calibration overlay
            if showCalibrationOverlay {
                CalibrationOverlay(
                    state: viewModel.calibrationState,
                    onDismiss: { viewModel.requestRecalibration() }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showCalibrationOverlay)
        .onAppear { viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            StatusPill(state: viewModel.calibrationState) {
                viewModel.requestRecalibration()
            }

            Spacer()

            if viewModel.isRecording {
                sessionTimerLabel
            }
        }
    }

    private var sessionTimerLabel: some View {
        HStack(spacing: AppSpacing.xs) {
            Circle()
                .fill(AppColors.danger)
                .frame(width: 8, height: 8)

            Text(formattedElapsed)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(AppColors.textPrimary)
        }
        .accessibilityLabel("Recording time: \(formattedElapsed)")
    }

    // MARK: - Meters

    private var metersSection: some View {
        HStack(spacing: AppSpacing.meterGap) {
            VerticalTelemetryMeter(
                value: viewModel.currentAngle,
                range: 0...90,
                targetBand: viewModel.preferences.angleTarget,
                unit: "°",
                label: "ANGLE",
                valueFont: AppTypography.meterValue,
                rangeStatus: viewModel.angleInRange
            )

            VerticalTelemetryMeter(
                value: viewModel.currentSpeed,
                range: 0...viewModel.preferences.speedGaugeMaximum,
                targetBand: viewModel.preferences.speedTarget,
                unit: viewModel.preferences.speedUnit == .kph ? "km/h" : "mph",
                label: "SPEED",
                valueFont: AppTypography.meterValueSmall,
                rangeStatus: viewModel.speedInRange
            )
        }
    }

    // MARK: - Controls

    private var controlsSection: some View {
        VStack(spacing: AppSpacing.md) {
            TargetRangeEditor(
                preferences: viewModel.preferences,
                isDisabled: viewModel.isRecording
            )

            recordButton
        }
    }

    private var recordButton: some View {
        Button(action: toggleRecording) {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: viewModel.isRecording ? "stop.fill" : "record.circle")
                    .font(.system(size: 18))
                Text(viewModel.isRecording ? "Stop" : "Record")
                    .font(AppTypography.cardTitle)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppSpacing.md)
            .background(viewModel.isRecording ? AppColors.danger : AppColors.accent)
            .clipShape(RoundedRectangle(cornerRadius: AppSpacing.CornerRadius.button))
        }
        .buttonStyle(.plain)
        .disabled(isRecordingDisabled)
        .opacity(isRecordingDisabled ? 0.5 : 1.0)
        .accessibilityLabel(viewModel.isRecording ? "Stop recording" : "Start recording")
    }

    // MARK: - Helpers

    private var showCalibrationOverlay: Bool {
        switch viewModel.calibrationState {
        case .calibrating, .unavailable, .failed:
            // A failure must be shown, not hidden behind a pill: the message
            // names what went wrong and is the only way to act on it.
            return true
        default:
            return false
        }
    }

    private var isRecordingDisabled: Bool {
        switch viewModel.calibrationState {
        case .calibrated:
            return false
        default:
            return !viewModel.isRecording // Allow stopping even if calibration lapses
        }
    }

    private var formattedElapsed: String {
        let total = Int(viewModel.sessionElapsed)
        let minutes = total / 60
        let seconds = total % 60
        let tenths = Int((viewModel.sessionElapsed - Double(total)) * 10)
        return String(format: "%d:%02d.%d", minutes, seconds, tenths)
    }

    private func toggleRecording() {
        if viewModel.isRecording {
            viewModel.stopRecording()
        } else {
            viewModel.startRecording()
        }
    }
}

// MARK: - Preview

#Preview {
    LiveWheelieView(
        calibrationService: CalibrationService(),
        preferences: RiderPreferences()
    )
}
