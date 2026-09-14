import SwiftUI
import MotoTelemetryCore

/// Optional calibration flow. Skip returns to Live without enabling measurements.

@MainActor
struct CalibrationScreen: View {
    let service: CalibrationService
    /// Called once calibration reaches `.measured`, carrying the completed estimate
    /// (which holds both the bias and the gravity anchor the swipe consumes).
    let onMeasured: (BiasEstimate) -> Void
    var onRetry: (() -> Void)? = nil
    var onSkip: (() -> Void)? = nil

    @State private var isPulsing = false

    var body: some View {
        ZStack {
            AppColors.background

            // Scrollable so the largest accessibility text can't clip the instruction
            // or push the action button off-screen. On normal sizes the min-height frame
            // keeps the VStack full-height, so the Spacers still center everything and
            // nothing actually scrolls; only oversized text engages the scroll.
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: AppSpacing.xl) {
                        Spacer(minLength: 0)

                        Image(systemName: icon)
                            .font(.system(size: 72, weight: .light))
                            .foregroundStyle(iconColor)
                            .scaleEffect(isPulsing ? 1.08 : 0.96)
                            .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                                       value: isPulsing)

                        Text(title)
                    // ~70% of AppTypography.meterValue (56pt). The full meter size pushed
                    // the yellow blockingReason line below the screen on the calibration
                    // screen; a smaller title keeps the whole stack in view.
                    .font(.system(size: 39, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppColors.textPrimary)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.5)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, AppSpacing.xl)

                Text(String(format: "Gyro °/s   X %.2f   Y %.2f   Z %.2f",
                            service.rotationRateDegrees.x,
                            service.rotationRateDegrees.y,
                            service.rotationRateDegrees.z))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)

                // Progress fraction = how much of the 2 s still-window is complete.
                if case .measuring(let progress) = service.phase {
                    if let progress {
                        ProgressView(value: progress)
                            .tint(AppColors.accent)
                            .frame(width: 220)
                        Text("\(Int(progress * 100))%")
                            .font(AppTypography.cardSubtitle)
                            .foregroundStyle(AppColors.textSecondary)
                    } else {
                        ProgressView().tint(AppColors.accent).controlSize(.large)
                    }
                }

                // The live reset reason — the whole point of a real-time gate.
                if let reason = service.blockingReason {
                    Text(reason)
                        .font(AppTypography.bodyText)
                        .foregroundStyle(AppColors.warning)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, AppSpacing.xxl)
                        .transition(.opacity)
                }

                Spacer(minLength: 0)

                if let onSkip {
                    Button("Skip for now", action: onSkip)
                        .font(AppTypography.bodyText)
                        .foregroundStyle(AppColors.textSecondary)
                }
                actionButton
                    .padding(.bottom, AppSpacing.xxl)
                    }
                    .frame(minHeight: proxy.size.height)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear { isPulsing = true }
        .animation(.easeInOut(duration: 0.25), value: service.blockingReason)
        .onChange(of: measuredEstimateID) { _, _ in
            if case .measured(let estimate) = service.phase {
                onMeasured(estimate)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Calibration")
        .accessibilityValue(title)
    }

    /// A stable id that changes only when a NEW estimate is measured, so the
    /// `onChange` fires exactly once per completion rather than every render.
    private var measuredEstimateID: UUID? {
        if case .measured(let e) = service.phase { return e.id }
        return nil
    }

    @ViewBuilder
    private var actionButton: some View {
        switch service.phase {
        case .failed, .unavailable:
            Button("Try again") {
                if let onRetry { onRetry() } else { service.restart() }
            }
                .font(AppTypography.bodyText)
                .foregroundStyle(AppColors.accent)
        default:
            EmptyView()
        }
    }

    private var icon: String {
        switch service.phase {
        case .unavailable: "exclamationmark.triangle"
        case .failed:      "xmark.circle"
        case .measured:    "checkmark.circle"
        case .measuring:   "gyroscope"
        }
    }

    private var iconColor: Color {
        switch service.phase {
        case .unavailable, .failed: AppColors.warning
        case .measured:             AppColors.success
        case .measuring:            AppColors.accent
        }
    }

    private var title: LocalizedStringKey {
        switch service.phase {
        case .measuring:
            "Hold the bike upright and still, engine off"
        case .measured:
            "Calibrated"
        case .failed(let message):
            "Couldn't calibrate: \(message)"
        case .unavailable:
            "Motion sensors unavailable. Check permissions in Settings."
        }
    }
}
