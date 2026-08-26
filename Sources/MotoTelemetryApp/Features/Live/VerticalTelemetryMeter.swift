import SwiftUI

/// Tall vertical bar gauge showing a real-time telemetry value with target band overlay.
struct VerticalTelemetryMeter: View {
    let value: Double
    let range: ClosedRange<Double>
    let targetBand: MetricRange?
    let unit: String
    let label: String
    let valueFont: Font
    let rangeStatus: RangeStatus

    init(
        value: Double,
        range: ClosedRange<Double>,
        targetBand: MetricRange? = nil,
        unit: String,
        label: String,
        valueFont: Font = AppTypography.meterValue,
        rangeStatus: RangeStatus = .outOfRange
    ) {
        self.value = value
        self.range = range
        self.targetBand = targetBand
        self.unit = unit
        self.label = label
        self.valueFont = valueFont
        self.rangeStatus = rangeStatus
    }

    var body: some View {
        VStack(spacing: AppSpacing.sm) {
            // Value readout
            Text(formattedValue)
                .font(valueFont)
                .foregroundStyle(fillColor)
                .contentTransition(.numericText(value: value))
                .animation(.easeOut(duration: 0.05), value: value)

            // Unit label
            Text(unit)
                .meterLabelStyle()

            // Vertical bar
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    // Background track
                    RoundedRectangle(cornerRadius: AppSpacing.CornerRadius.meter)
                        .fill(AppColors.surfaceMeter)

                    // Filled portion
                    RoundedRectangle(cornerRadius: AppSpacing.CornerRadius.meter)
                        .fill(fillColor.opacity(0.8))
                        .frame(height: fillHeight(in: geo.size.height))
                        .animation(.easeOut(duration: 0.05), value: value)

                    // Target band stripe
                    if let band = targetBand {
                        targetBandOverlay(band: band, height: geo.size.height)
                    }
                }
            }

            // Label
            Text(label)
                .meterLabelStyle()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) meter")
        .accessibilityValue("\(formattedValue) \(unit), \(rangeAccessibilityLabel)")
    }

    // MARK: - Computed

    private var formattedValue: String {
        if value < 100 {
            return String(format: "%.1f", value)
        } else {
            return String(format: "%.0f", value)
        }
    }

    private var fillColor: Color {
        switch rangeStatus {
        case .inRange: AppColors.metricInRange
        case .near: AppColors.metricNearRange
        case .outOfRange: AppColors.metricOutOfRange
        }
    }

    private var rangeAccessibilityLabel: String {
        switch rangeStatus {
        case .inRange: "in target range"
        case .near: "near target range"
        case .outOfRange: "outside target range"
        }
    }

    private func fillHeight(in totalHeight: CGFloat) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        let fraction = (value - range.lowerBound) / span
        let clamped = min(max(fraction, 0), 1)
        return totalHeight * clamped
    }

    @ViewBuilder
    private func targetBandOverlay(band: MetricRange, height: CGFloat) -> some View {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return AnyView(EmptyView()) }

        let lowerFraction = (band.lower - range.lowerBound) / span
        let upperFraction = (band.upper - range.lowerBound) / span
        let bandHeight = (upperFraction - lowerFraction) * height
        let bottomOffset = lowerFraction * height

        return AnyView(
            RoundedRectangle(cornerRadius: 4)
                .fill(AppColors.targetBandFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(AppColors.targetBandStroke, lineWidth: 1.5)
                )
                .frame(height: max(bandHeight, 4))
                .offset(y: -(bottomOffset + bandHeight / 2) + height / 2)
        )
    }
}

// MARK: - Preview

#Preview {
    HStack(spacing: AppSpacing.meterGap) {
        VerticalTelemetryMeter(
            value: 42,
            range: 0...90,
            targetBand: MetricRange(lower: 35, upper: 45),
            unit: "°",
            label: "ANGLE",
            rangeStatus: .inRange
        )
        VerticalTelemetryMeter(
            value: 38,
            range: 0...100,
            targetBand: MetricRange(lower: 35, upper: 50),
            unit: "km/h",
            label: "SPEED",
            valueFont: AppTypography.meterValueSmall,
            rangeStatus: .near
        )
    }
    .padding(AppSpacing.screenPadding)
    .frame(height: 400)
    .background(AppColors.background)
}
