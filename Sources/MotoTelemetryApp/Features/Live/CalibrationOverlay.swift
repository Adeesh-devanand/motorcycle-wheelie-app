import SwiftUI

/// Full-screen overlay shown during calibration or when sensors are unavailable.
/// Dismisses automatically when state transitions to `.calibrated`.
struct CalibrationOverlay: View {
    let state: CalibrationState
    let onDismiss: (() -> Void)?
    /// R6.2: the validity-gate condition currently blocking calibration, phrased for
    /// the rider. Without it a stalled calibration shows only "Collecting data… 0%",
    /// which names no cause and leaves the rider with nothing to act on. Optional so
    /// existing call sites and previews are unaffected.
    var blockingReason: String? = nil

    @State private var isPulsing = false

    var body: some View {
        ZStack {
            // Semi-transparent backdrop
            Color.black.opacity(0.85)
                .ignoresSafeArea()

            VStack(spacing: AppSpacing.xl) {
                // Pulsing icon
                Image(systemName: iconName)
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(AppColors.accent)
                    .scaleEffect(isPulsing ? 1.1 : 0.95)
                    .opacity(isPulsing ? 1.0 : 0.6)
                    .animation(
                        .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                        value: isPulsing
                    )

                // Instruction text
                Text(instructionText)
                    .font(AppTypography.bodyText)
                    .foregroundStyle(AppColors.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AppSpacing.xxl)

                // Progress indicator
                if let progress = calibrationProgress {
                    ProgressView(value: progress)
                        .tint(AppColors.accent)
                        .frame(width: 200)
                } else if isCalibrating {
                    ProgressView()
                        .tint(AppColors.accent)
                        .controlSize(.large)
                }

                // Status detail
                if let detail = detailText {
                    Text(detail)
                        .font(AppTypography.cardSubtitle)
                        .foregroundStyle(AppColors.textSecondary)
                }

                // Why calibration is not progressing (R6.2).
                if let blockingReason {
                    Text(blockingReason)
                        .font(AppTypography.cardSubtitle)
                        .foregroundStyle(AppColors.textPrimary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, AppSpacing.xxl)
                }
            }
        }
        .onAppear { isPulsing = true }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Calibration overlay")
        .accessibilityValue(instructionText)
    }

    // MARK: - Computed

    private var iconName: String {
        switch state {
        case .unavailable: "exclamationmark.triangle"
        case .calibrating: "gyroscope"
        case .failed: "xmark.circle"
        default: "gyroscope"
        }
    }

    private var instructionText: String {
        switch state {
        case .unavailable:
            "Motion sensors unavailable.\nCheck device permissions."
        case .calibrating:
            "Hold the bike still with the engine idling"
        case .failed(let message):
            "Calibration failed: \(message)\nTap to retry."
        default:
            "Calibrating…"
        }
    }

    private var detailText: String? {
        switch state {
        case .calibrating(let progress):
            if let progress {
                "Collecting data… \(Int(progress * 100))%"
            } else {
                "Waiting for stable position…"
            }
        case .unavailable:
            "Gyroscope and accelerometer are required"
        default:
            nil
        }
    }

    private var calibrationProgress: Double? {
        if case .calibrating(let progress) = state {
            return progress
        }
        return nil
    }

    private var isCalibrating: Bool {
        if case .calibrating = state { return true }
        return false
    }
}

// MARK: - Preview

#Preview {
    CalibrationOverlay(state: .calibrating(progress: 0.65), onDismiss: nil)
}
