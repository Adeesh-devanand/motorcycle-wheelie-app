import SwiftUI

/// Tall vertical bar gauge showing a real-time telemetry value with target band,
/// ticks, cursor, and scale labels. Layout is mirrored: ANGLE shows labels/value
/// on the left, SPEED on the right.
struct VerticalTelemetryMeter: View {
    let value: Double
    let range: ClosedRange<Double>
    let targetBand: MetricRange?
    let unit: String
    let label: String
    let valueFont: Font
    let rangeStatus: RangeStatus

    /// Whether labels sit on the leading (left) side. Angle = true, Speed = false.
    var labelsOnLeading: Bool = true
    /// Optional action for the target-editor button beside the band.
    var onTargetEdit: (() -> Void)?

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

    // MARK: - Constants

    private let trackWidth: CGFloat = 40
    private let tickLength: CGFloat = 6
    private let majorTickLength: CGFloat = 10
    private let cursorOverhang: CGFloat = 8
    private let cursorThickness: CGFloat = 2
    private let cursorDotSize: CGFloat = 10

    var body: some View {
        VStack(spacing: AppSpacing.sm) {
            // Title above the meter
            Text(label)
                .font(.system(size: 15, weight: .medium))
                .tracking(1)
                .foregroundStyle(AppColors.textSecondary)

            // Meter with side content
            GeometryReader { geo in
                meterLayout(height: geo.size.height, totalWidth: geo.size.width)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) meter")
        .accessibilityValue("\(Int(value)) \(unit)")
    }

    // MARK: - Main Layout

    private func meterLayout(height: CGFloat, totalWidth: CGFloat) -> some View {
        let fraction = fillFraction
        let cursorY = height * (1 - fraction)

        return HStack(alignment: .top, spacing: 0) {
            if labelsOnLeading {
                sideContent(height: height, cursorY: cursorY, totalWidth: (totalWidth - trackWidth - cursorOverhang * 2) / 2)
                Spacer(minLength: 0)
            }

            meterTrackView(height: height, cursorY: cursorY)

            if !labelsOnLeading {
                Spacer(minLength: 0)
                sideContent(height: height, cursorY: cursorY, totalWidth: (totalWidth - trackWidth - cursorOverhang * 2) / 2)
            }
        }
        .frame(height: height)
    }

    // MARK: - Side Content (value readout + scale + target)

    private func sideContent(height: CGFloat, cursorY: CGFloat, totalWidth: CGFloat) -> some View {
        ZStack {
            // Scale labels
            scaleView(height: height)

            // Big value readout near cursor
            valueReadoutView
                .offset(y: cursorY - height / 2)

            // Target label near band center
            if let band = targetBand {
                targetLabelView(band: band, height: height)
            }
        }
        .frame(width: max(totalWidth, 65), height: height)
    }

    // MARK: - Meter Track

    private func meterTrackView(height: CGFloat, cursorY: CGFloat) -> some View {
        let fraction = fillFraction
        let totalTrackWidth = trackWidth + cursorOverhang * 2

        return ZStack(alignment: .bottom) {
            // Track background capsule
            Capsule()
                .fill(AppColors.surfaceMeter)
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .frame(width: trackWidth, height: height)

            // Target band (behind fill)
            if let band = targetBand {
                targetBandOverlay(band: band, height: height)
            }

            // Fill from bottom up to cursor
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [AppColors.meterFillBottom, AppColors.meterFillMid, AppColors.meterFillTop],
                        startPoint: .bottom,
                        endPoint: .top
                    )
                )
                .frame(width: trackWidth, height: max(fraction * height, 0))
                .animation(.easeOut(duration: 0.05), value: value)

            // Ticks on both sides
            tickCanvas(height: height)
                .frame(width: totalTrackWidth, height: height)

            // Cursor line + dot + glow
            cursorOverlayView(cursorY: cursorY, height: height, totalWidth: totalTrackWidth)
                .frame(width: totalTrackWidth, height: height)
        }
        .frame(width: totalTrackWidth, height: height)
    }

    // MARK: - Target Band Overlay

    private func targetBandOverlay(band: MetricRange, height: CGFloat) -> some View {
        let span = range.upperBound - range.lowerBound
        let lowerFrac = span > 0 ? min(max((band.lower - range.lowerBound) / span, 0), 1) : 0
        let upperFrac = span > 0 ? min(max((band.upper - range.lowerBound) / span, 0), 1) : 0
        let bandHeight = max((upperFrac - lowerFrac) * height, 4)
        let bottomOffset = lowerFrac * height

        return Rectangle()
            .fill(AppColors.targetBandFill)
            .overlay(
                Rectangle()
                    .stroke(
                        AppColors.targetBandStroke,
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            )
            .frame(width: trackWidth + 8, height: bandHeight)
            .offset(y: -(bottomOffset + bandHeight / 2) + height / 2)
    }

    // MARK: - Tick Canvas

    private func tickCanvas(height: CGFloat) -> some View {
        let span = range.upperBound - range.lowerBound
        let majorStep = span > 0 ? span / 4.0 : 1
        let minorStep: Double = label == "ANGLE" ? 3.0 : 5.0
        let tw = trackWidth
        let tl = tickLength
        let mtl = majorTickLength
        let lb = range.lowerBound
        let ub = range.upperBound

        return Canvas { context, size in
            guard span > 0 else { return }
            let centerX = size.width / 2

            var tick = lb
            while tick <= ub + 0.001 {
                let frac = (tick - lb) / span
                let y = size.height - (frac * size.height)

                // Determine if major tick
                let remainder = tick.truncatingRemainder(dividingBy: majorStep)
                let isMajor = remainder < 0.5 || (majorStep - remainder) < 0.5 || abs(tick - ub) < 0.5
                let len: CGFloat = isMajor ? mtl : tl

                // Left tick
                var leftPath = Path()
                leftPath.move(to: CGPoint(x: centerX - tw / 2 - 1, y: y))
                leftPath.addLine(to: CGPoint(x: centerX - tw / 2 - 1 - len, y: y))
                context.stroke(leftPath, with: .color(AppColors.tickMark), lineWidth: 1)

                // Right tick
                var rightPath = Path()
                rightPath.move(to: CGPoint(x: centerX + tw / 2 + 1, y: y))
                rightPath.addLine(to: CGPoint(x: centerX + tw / 2 + 1 + len, y: y))
                context.stroke(rightPath, with: .color(AppColors.tickMark), lineWidth: 1)

                tick += minorStep
            }
        }
    }

    // MARK: - Cursor Overlay

    private func cursorOverlayView(cursorY: CGFloat, height: CGFloat, totalWidth: CGFloat) -> some View {
        Canvas { context, size in
            let y = cursorY
            guard y >= 0, y <= size.height else { return }

            // Glow
            let glowRect = CGRect(
                x: 0, y: y - 6,
                width: size.width, height: 12
            )
            context.fill(
                Ellipse().path(in: glowRect),
                with: .color(.white.opacity(0.15))
            )

            // Crisp line
            var linePath = Path()
            linePath.move(to: CGPoint(x: 0, y: y))
            linePath.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(linePath, with: .color(AppColors.cursor), lineWidth: cursorThickness)

            // Center dot
            let dotRect = CGRect(
                x: size.width / 2 - cursorDotSize / 2,
                y: y - cursorDotSize / 2,
                width: cursorDotSize, height: cursorDotSize
            )
            context.fill(Circle().path(in: dotRect), with: .color(AppColors.cursor))
        }
        .animation(.easeOut(duration: 0.05), value: value)
    }

    // MARK: - Scale Labels View

    private func scaleView(height: CGFloat) -> some View {
        let span = range.upperBound - range.lowerBound
        let steps: [Double] = makeScaleSteps()
        let isLeading = labelsOnLeading

        return Canvas { context, size in
            guard span > 0 else { return }
            for tick in steps {
                let frac = (tick - range.lowerBound) / span
                let y = size.height - (frac * size.height)
                let text = label == "ANGLE" ? "\(Int(tick))°" : "\(Int(tick))"
                let resolved = context.resolve(
                    Text(text)
                        .font(.system(size: 13))
                        .foregroundStyle(AppColors.textSecondary)
                )
                let textSize = resolved.measure(in: size)
                let x: CGFloat = isLeading
                    ? size.width - textSize.width - 4
                    : 4
                context.draw(resolved, at: CGPoint(x: x + textSize.width / 2, y: y))
            }
        }
        .frame(height: height)
    }

    private func makeScaleSteps() -> [Double] {
        if label == "ANGLE" {
            return stride(from: 0.0, through: 90.0, by: 15.0).map { $0 }
        } else {
            let span = range.upperBound - range.lowerBound
            let step = span / 4
            guard step > 0 else { return [range.lowerBound] }
            return stride(from: range.lowerBound, through: range.upperBound, by: step).map { $0 }
        }
    }

    // MARK: - Value Readout

    private var valueReadoutView: some View {
        VStack(spacing: 0) {
            if label == "ANGLE" {
                Text("\(Int(value))°")
                    .font(.system(size: 40, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppColors.accentBright)
            } else {
                Text("\(Int(value))")
                    .font(.system(size: 40, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppColors.accentBright)
                Text(unit)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppColors.accentBright)
            }
        }
    }

    // MARK: - Target Label View

    private func targetLabelView(band: MetricRange, height: CGFloat) -> some View {
        let span = range.upperBound - range.lowerBound
        let bandCenterFrac = span > 0 ? ((band.lower + band.upper) / 2.0 - range.lowerBound) / span : 0.5
        let offsetY = (height * (1 - bandCenterFrac)) - height / 2 + 50
        let clampedY = min(max(offsetY, -height / 2 + 80), height / 2 - 60)
        let rangeText: String = label == "ANGLE"
            ? "\(Int(band.lower))°-\(Int(band.upper))°"
            : "\(Int(band.lower))-\(Int(band.upper))"
        let triangleIcon = labelsOnLeading
            ? "arrowtriangle.right.fill"
            : "arrowtriangle.left.fill"

        return VStack(spacing: AppSpacing.xxs) {
            Text("TARGET")
                .font(.system(size: 12))
                .foregroundStyle(AppColors.accent)
            Text(rangeText)
                .font(.system(size: 12))
                .foregroundStyle(AppColors.accent)
            Image(systemName: triangleIcon)
                .font(.system(size: 8))
                .foregroundStyle(AppColors.accent)

            if let action = onTargetEdit {
                Button(action: action) {
                    Circle()
                        .fill(AppColors.surfaceButton)
                        .frame(width: 36, height: 36)
                        .overlay(
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 14))
                                .foregroundStyle(AppColors.textSecondary)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .offset(y: clampedY)
    }

    // MARK: - Computed

    private var fillFraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        let fraction = (value - range.lowerBound) / span
        return min(max(fraction, 0), 1)
    }
}
