import SwiftUI

// MARK: - StatusPill

/// Wide rounded-rectangle status surface displaying the current CalibrationState.
/// Tapping calls `onTapRecalibrate`.
struct StatusPill: View {
    let state: CalibrationState
    let onTapRecalibrate: () -> Void

    var body: some View {
        Button(action: { onTapRecalibrate() }) {
            HStack(spacing: AppSpacing.sm) {
                statusIndicator
                Text(label)
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(labelColor)
            }
            .frame(height: 52)
            .padding(.horizontal, AppSpacing.xl)
            .background(AppColors.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Calibration status: \(label.lowercased())")
        .accessibilityHint("Double tap to recalibrate")
    }

    // MARK: - Status Indicator

    @ViewBuilder
    private var statusIndicator: some View {
        switch state {
        case .calibrated:
            Circle()
                .fill(AppColors.success)
                .frame(width: 8, height: 8)
        case .calibrating:
            ProgressView()
                .controlSize(.small)
                .tint(AppColors.accent)
        case .unavailable, .stale, .failed:
            EmptyView()
        }
    }

    // MARK: - Computed Properties

    private var label: String {
        switch state {
        case .unavailable: return "UNAVAILABLE"
        case .calibrating: return "CALIBRATING"
        case .calibrated: return "CALIBRATED"
        case .stale: return "STALE"
        case .failed: return "FAILED"
        }
    }

    private var labelColor: Color {
        switch state {
        case .calibrated: return AppColors.success
        case .calibrating: return AppColors.accent
        case .stale: return AppColors.accent
        case .failed: return AppColors.danger
        case .unavailable: return AppColors.textSecondary
        }
    }
}
