import SwiftUI

/// Compact editor for ONE target range. Angle and speed are edited separately:
/// tapping the angle meter's TARGET label must not put the speed range under
/// your thumb as well, so the caller states which field it opened.
/// Updates RiderPreferences directly; disabled during active recording.
struct TargetRangeEditor: View {

    /// Which single range this editor edits. `Identifiable` so a caller can
    /// present it with `.sheet(item:)` — there the non-nil field IS the request
    /// to open, which makes "which meter did they tap" impossible to lose.
    enum Field: String, Identifiable, CaseIterable {
        case angle, speed
        var id: String { rawValue }
    }

    @Bindable var preferences: RiderPreferences
    let field: Field
    let isDisabled: Bool

    var body: some View {
        VStack(spacing: AppSpacing.md) {
            switch field {
            case .angle: angleSlider
            case .speed: speedSlider
            }
        }
        .padding(AppSpacing.cardPadding)
        .background(AppColors.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: AppSpacing.CornerRadius.card))
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1.0)
    }

    // MARK: - Per-field sliders

    private var angleSlider: some View {
        DualThumbSlider(
            label: "Angle Target",
            unit: "°",
            lower: Binding(
                get: { preferences.angleTarget.lower },
                set: { newLower in
                    let clamped = min(newLower, preferences.angleTarget.upper - 1)
                    preferences.angleTarget = MetricRange(lower: max(0, clamped),
                                                          upper: preferences.angleTarget.upper)
                }
            ),
            upper: Binding(
                get: { preferences.angleTarget.upper },
                set: { newUpper in
                    let clamped = max(newUpper, preferences.angleTarget.lower + 1)
                    preferences.angleTarget = MetricRange(lower: preferences.angleTarget.lower,
                                                          upper: min(90, clamped))
                }
            ),
            bounds: 0...90
        )
    }

    private var speedSlider: some View {
        DualThumbSlider(
            label: "Speed Target",
            unit: preferences.speedUnit == .kph ? "km/h" : "mph",
            lower: Binding(
                get: { preferences.speedTarget.lower },
                set: { newLower in
                    let clamped = min(newLower, preferences.speedTarget.upper - 1)
                    preferences.speedTarget = MetricRange(lower: max(0, clamped),
                                                          upper: preferences.speedTarget.upper)
                }
            ),
            upper: Binding(
                get: { preferences.speedTarget.upper },
                set: { newUpper in
                    let clamped = max(newUpper, preferences.speedTarget.lower + 1)
                    preferences.speedTarget = MetricRange(lower: preferences.speedTarget.lower,
                                                          upper: min(preferences.speedGaugeMaximum, clamped))
                }
            ),
            bounds: 0...preferences.speedGaugeMaximum
        )
    }
}

// MARK: - Dual Thumb Slider

private struct DualThumbSlider: View {
    let label: String
    let unit: String
    @Binding var lower: Double
    @Binding var upper: Double
    let bounds: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            // Header
            HStack {
                Text(label)
                    .font(AppTypography.chipLabel)
                    .foregroundStyle(AppColors.textSecondary)
                    .textCase(.uppercase)

                Spacer()

                Text("\(Int(lower))–\(Int(upper)) \(unit)")
                    .font(AppTypography.chipLabel)
                    .foregroundStyle(AppColors.accent)
            }

            // Track + thumbs
            GeometryReader { geo in
                let width = geo.size.width
                let span = bounds.upperBound - bounds.lowerBound

                ZStack(alignment: .leading) {
                    // Background track
                    Capsule()
                        .fill(AppColors.surfaceMeter)
                        .frame(height: 6)

                    // Selected range highlight
                    let lowerOffset = ((lower - bounds.lowerBound) / span) * width
                    let upperOffset = ((upper - bounds.lowerBound) / span) * width

                    Capsule()
                        .fill(AppColors.accent)
                        .frame(width: max(upperOffset - lowerOffset, 4), height: 6)
                        .offset(x: lowerOffset)

                    // Lower thumb
                    thumbView()
                        .offset(x: lowerOffset - 10)
                        .gesture(
                            DragGesture()
                                .onChanged { drag in
                                    let fraction = drag.location.x / width
                                    let newValue = bounds.lowerBound + fraction * span
                                    lower = min(max(newValue, bounds.lowerBound), upper - 1)
                                }
                        )

                    // Upper thumb
                    thumbView()
                        .offset(x: upperOffset - 10)
                        .gesture(
                            DragGesture()
                                .onChanged { drag in
                                    let fraction = drag.location.x / width
                                    let newValue = bounds.lowerBound + fraction * span
                                    upper = max(min(newValue, bounds.upperBound), lower + 1)
                                }
                        )
                }
            }
            .frame(height: 28)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) range")
        .accessibilityValue("\(Int(lower)) to \(Int(upper)) \(unit)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: upper = min(upper + 1, bounds.upperBound)
            case .decrement: lower = max(lower - 1, bounds.lowerBound)
            @unknown default: break
            }
        }
    }

    @ViewBuilder
    private func thumbView() -> some View {
        Circle()
            .fill(AppColors.accent)
            .frame(width: 20, height: 20)
            .shadow(color: AppColors.accentGlow, radius: 4)
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: AppSpacing.md) {
        TargetRangeEditor(preferences: RiderPreferences(), field: .angle, isDisabled: false)
        TargetRangeEditor(preferences: RiderPreferences(), field: .speed, isDisabled: false)
    }
    .padding()
    .background(AppColors.background)
}
