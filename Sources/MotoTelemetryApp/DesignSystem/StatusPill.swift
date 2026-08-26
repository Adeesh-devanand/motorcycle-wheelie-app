import SwiftUI

// MARK: - StatusPill

/// Capsule-shaped pill displaying the current CalibrationState.
/// Tapping when `.calibrated` triggers forced recalibration.
struct StatusPill: View {
    let state: CalibrationState
    let onTapRecalibrate: () -> Void

    var body: some View {
        Button(action: handleTap) {
            HStack(spacing: AppSpacing.xs) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
                    .modifier(PulseModifier(isPulsing: isPulsing))

                Text(label)
                    .font(AppTypography.chipLabel)
                    .textCase(.uppercase)
                    .foregroundStyle(AppColors.textPrimary)
            }
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, AppSpacing.xs + 2)
            .background(AppColors.surfaceCard)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Calibration status: \(accessibilityLabel)")
        .accessibilityHint(isTappable ? "Double tap to recalibrate" : "")
    }

    // MARK: - Computed Properties

    private var label: String {
        switch state {
        case .unavailable: "UNAVAILABLE"
        case .calibrating: "CALIBRATING"
        case .calibrated: "CALIBRATED"
        case .stale: "STALE"
        case .failed: "FAILED"
        }
    }

    private var dotColor: Color {
        switch state {
        case .unavailable: AppColors.textSecondary
        case .calibrating: AppColors.accent
        case .calibrated: AppColors.success
        case .stale: AppColors.warning
        case .failed: AppColors.danger
        }
    }

    private var isPulsing: Bool {
        if case .calibrating = state { return true }
        return false
    }

    private var isTappable: Bool {
        if case .calibrated = state { return true }
        return false
    }

    private var accessibilityLabel: String {
        label.lowercased()
    }

    private func handleTap() {
        if case .calibrated = state {
            onTapRecalibrate()
        }
    }
}

// MARK: - Pulse Animation Modifier

private struct PulseModifier: ViewModifier {
    let isPulsing: Bool
    @State private var isAnimating = false

    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? (isAnimating ? 0.3 : 1.0) : 1.0)
            .animation(
                isPulsing
                    ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                    : .default,
                value: isAnimating
            )
            .onAppear {
                if isPulsing { isAnimating = true }
            }
            .onChange(of: isPulsing) { _, newValue in
                isAnimating = newValue
            }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 12) {
        StatusPill(state: .calibrated(referenceID: UUID(), calibratedAt: .now)) {}
        StatusPill(state: .calibrating(progress: 0.5)) {}
        StatusPill(state: .stale(reason: .timeout)) {}
        StatusPill(state: .failed(message: "Sensor error")) {}
    }
    .padding()
    .background(AppColors.background)
}
