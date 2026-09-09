import SwiftUI
import MotoTelemetryCore

/// Full-screen calibration, shown on every launch before the live screen — the
/// replacement for `CalibrationOverlay`, which floated over a live view that had
/// nothing valid to show yet.
///
/// It reads `CalibrationService.phase` directly. The service is fed raw IMU by
/// `RunRecorder`, whose sensor session the parent starts, so this view only
/// renders state and offers the two actions a stuck calibration needs: retry, and
/// (on `.measured`) continue to the swipe.
///
/// The rider-facing reset reason is the important part. On every dwell reset the
/// service sets `blockingReason` — "too much vibration — switch the engine off",
/// "still moving" — and this shows it the instant it changes, which is the
/// behaviour the rider valued: the countdown visibly restarts and says why.
/// `@MainActor` because it reads `CalibrationService`'s `@Observable` mirrors and
/// calls `restart()`, which is main-actor isolated so it can publish those mirrors
/// synchronously. SwiftUI's `body` is not itself isolated in Swift 5, so without this
/// the "Try again" button is a main-actor call from a nonisolated context.
@MainActor
struct CalibrationScreen: View {
    let service: CalibrationService
    /// Called once calibration reaches `.measured`, carrying the completed estimate
    /// (which holds both the bias and the gravity anchor the swipe consumes).
    let onMeasured: (BiasEstimate) -> Void

    @State private var isPulsing = false

    var body: some View {
        ZStack {
            AppColors.background.ignoresSafeArea()

            VStack(spacing: AppSpacing.xl) {
                Spacer()

                Image(systemName: icon)
                    .font(.system(size: 72, weight: .light))
                    .foregroundStyle(iconColor)
                    .scaleEffect(isPulsing ? 1.08 : 0.96)
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                               value: isPulsing)

                Text(title)
                    .font(AppTypography.meterValue)
                    .foregroundStyle(AppColors.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AppSpacing.xxl)

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

                Spacer()

                actionButton
                    .padding(.bottom, AppSpacing.xxl)
            }
        }
        .onAppear { isPulsing = true }
        .animation(.easeInOut(duration: 0.25), value: service.blockingReason)
        .onChange(of: measuredEstimateID) { _, _ in
            if case .measured(let estimate) = service.phase {
                onMeasured(estimate)
            }
        }
        .accessibilityElement(children: .combine)
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
            Button("Try again") { service.restart() }
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

    private var title: String {
        switch service.phase {
        case .measuring:
            "Hold the bike upright and still,\nengine off"
        case .measured:
            "Calibrated"
        case .failed(let message):
            "Couldn't calibrate:\n\(message)"
        case .unavailable:
            "Motion sensors unavailable.\nCheck permissions in Settings."
        }
    }
}
