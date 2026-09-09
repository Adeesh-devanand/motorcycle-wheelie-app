import SwiftUI

/// Tall vertical bar gauge showing a real-time telemetry value with target band,
/// ticks, cursor, and scale labels.
///
/// Layout: the TRACK is centred in the width it is given, so when the caller
/// hands each meter half the screen the two bars land in the middle of their
/// respective halves (M-UI14). Scale labels sit immediately outside the ticks
/// (M-UI11) and are inset vertically so the end labels (0 / 90 / 100) are never
/// clipped by the canvas edge. Side content is mirrored: ANGLE draws on the
/// left, SPEED on the right.
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

    /// Snap increment for a target-band drag, in this meter's own units (degrees
    /// for angle, km/h for speed).
    var targetDragStep: Double = 2.5

    /// Called continuously while the rider drags a new target band directly on the
    /// track. Nil disables dragging — during an attempt, and before calibration.
    ///
    /// This replaced a tap that opened a modal two-thumb slider. Dragging on the
    /// bar itself means the band follows your finger against the same scale you are
    /// about to ride, instead of being set on a different scale in a sheet that
    /// covers the meter.
    var onTargetChange: ((MetricRange) -> Void)?

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

    private let trackWidth: CGFloat = 30
    private let tickLength: CGFloat = 5
    private let majorTickLength: CGFloat = 9
    private let cursorOverhang: CGFloat = 6
    private let cursorThickness: CGFloat = 2
    private let cursorDotSize: CGFloat = 10

    /// Gap between the end of a major tick and the scale label text.
    private let scaleLabelGap: CGFloat = 4
    /// Column widths for the outboard content.
    private let readoutWidth: CGFloat = 56
    private let targetLabelWidth: CGFloat = 62

    /// Horizontal distance from the track centre to where scale labels sit.
    private var scaleInset: CGFloat {
        trackWidth / 2 + majorTickLength + scaleLabelGap
    }

    var body: some View {
        VStack(spacing: AppSpacing.sm) {
            Text(label)
                .font(.system(size: 15, weight: .medium))
                .tracking(1)
                .foregroundStyle(AppColors.textSecondary)

            GeometryReader { geo in
                meterLayout(height: geo.size.height, totalWidth: geo.size.width)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) meter")
        .accessibilityValue(accessibilityValueText)
        // A drag gesture is unreachable with VoiceOver, and dropping the modal
        // editor removed the only accessible way to set a target. This moves the
        // whole band by one snap step, preserving its width.
        .accessibilityAdjustableAction { direction in
            guard let onTargetChange, let current = targetBand else { return }
            let delta = direction == .increment ? targetDragStep : -targetDragStep
            let width = current.upper - current.lower
            let lower = min(max(current.lower + delta, range.lowerBound),
                            range.upperBound - width)
            onTargetChange(MetricRange(lower: lower, upper: lower + width))
        }
    }

    // MARK: - Main Layout

    /// A centred ZStack: the track occupies the middle of `totalWidth`, and the
    /// scale / readout / target label are offset outward from that centre.
    private func meterLayout(height: CGFloat, totalWidth: CGFloat) -> some View {
        let cursorY = height * (1 - fillFraction)
        let sign: CGFloat = labelsOnLeading ? -1 : 1

        return ZStack {
            // Track, centred in the available width.
            meterTrackView(height: height, cursorY: cursorY)

            // Scale labels, drawn across the full width so x/y are exact.
            scaleView(height: height, totalWidth: totalWidth)

            // Live value readout, riding the cursor but clamped on-screen.
            valueReadoutView
                .frame(width: readoutWidth, alignment: labelsOnLeading ? .trailing : .leading)
                .offset(
                    x: sign * (scaleInset + readoutWidth / 2),
                    y: clampedReadoutOffset(cursorY: cursorY, height: height)
                )

            // Target label, near the band centre, itself the tap target.
            if let band = targetBand {
                targetLabelView(band: band, height: height)
                    .frame(width: targetLabelWidth, alignment: labelsOnLeading ? .trailing : .leading)
                    .offset(
                        x: sign * (scaleInset + targetLabelWidth / 2),
                        y: clampedTargetOffset(band: band, height: height)
                    )
            }
        }
        .frame(width: totalWidth, height: height)
    }

    // MARK: - Meter Track

    private func meterTrackView(height: CGFloat, cursorY: CGFloat) -> some View {
        let fraction = fillFraction
        let totalTrackWidth = trackWidth + cursorOverhang * 2

        return ZStack(alignment: .bottom) {
            // Track background
            Capsule()
                .fill(AppColors.surfaceMeter)
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .frame(width: trackWidth, height: height)

            // Target band (behind the fill)
            if let band = targetBand {
                targetBandOverlay(band: band, height: height)
            }

            // Fill from the bottom up to the cursor — flat top edge at the
            // cursor, rounded bottom corners only (M-UI15); two-stop ramp (M-UI1).
            BottomRoundedRect(radius: trackWidth / 2)
                .fill(
                    LinearGradient(
                        colors: [AppColors.meterFillBottom, AppColors.meterFillTop],
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
            cursorOverlayView(cursorY: cursorY, height: height)
                .frame(width: totalTrackWidth, height: height)
        }
        .frame(width: totalTrackWidth, height: height)
        // Widen the touch target without changing anything visible. The track is
        // 42 pt, under the 44 pt minimum, and this is now a control the rider drags
        // — possibly with gloves on. The padding is transparent and symmetric, so
        // the bar stays centred in its half of the screen, and it is horizontal only
        // so the y-to-value mapping in `snappedValue(atY:height:)` is unaffected.
        .padding(.horizontal, 9)
        // The Canvases above are not hit-testable, so without this the gesture
        // would only fire over the track Capsule and the fill.
        .contentShape(Rectangle())
        .gesture(targetDragGesture(height: height))
    }

    // MARK: - Target Drag

    /// Drag anywhere on the track to set the target band: the value under where you
    /// pressed is one edge, the value under your finger is the other.
    ///
    /// `minimumDistance` is deliberately non-zero. At 0 this would win against the
    /// enclosing `TabView`'s page swipe and against simple taps; 8 pt lets a tap and
    /// a horizontal page swipe through while still feeling immediate vertically.
    private func targetDragGesture(height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { drag in
                guard let onTargetChange else { return }
                let pressed = snappedValue(atY: drag.startLocation.y, height: height)
                let current = snappedValue(atY: drag.location.y, height: height)
                onTargetChange(band(from: pressed, to: current))
            }
    }

    /// The value at a y offset on the track, snapped to `targetDragStep`.
    ///
    /// y grows downward and the scale grows upward, hence `1 - fraction`. Clamped
    /// before snapping so a drag past either end of the track saturates at the end
    /// of the scale rather than producing a value outside it.
    private func snappedValue(atY y: CGFloat, height: CGFloat) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0, height > 0, targetDragStep > 0 else { return range.lowerBound }
        let fraction = 1 - min(max(Double(y / height), 0), 1)
        let raw = range.lowerBound + fraction * span
        let snapped = (raw / targetDragStep).rounded() * targetDragStep
        return min(max(snapped, range.lowerBound), range.upperBound)
    }

    /// Build a band from the two drag endpoints.
    ///
    /// Direction-agnostic by construction: 60 dragged to 75 and 75 dragged to 60 both
    /// give 60–75, which is what "auto correct for dragging up or down" means. A
    /// zero-width band is not a target and would draw as a hairline, so a drag that
    /// snaps to a single value is widened to one step, pushed inward at the ends.
    private func band(from a: Double, to b: Double) -> MetricRange {
        var lower = min(a, b)
        var upper = max(a, b)
        if upper - lower < targetDragStep {
            upper = min(lower + targetDragStep, range.upperBound)
            lower = max(upper - targetDragStep, range.lowerBound)
        }
        return MetricRange(lower: lower, upper: upper)
    }

    // MARK: - Target Band Overlay

    /// The band spans exactly `band.lower ... band.upper` on the track, so the
    /// cursor falls inside the band precisely when the reading is in target.
    ///
    /// The band lives in a `.bottom`-aligned ZStack, so its bottom edge already
    /// starts at the track bottom: lifting it by `bottomOffset` is the whole
    /// transform. The previous formula mixed in `height / 2` and half the band
    /// height and pushed the band far below its real position.
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
            .offset(y: -bottomOffset)
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

                let remainder = tick.truncatingRemainder(dividingBy: majorStep)
                let isMajor = remainder < 0.5 || (majorStep - remainder) < 0.5 || abs(tick - ub) < 0.5
                let len: CGFloat = isMajor ? mtl : tl

                var leftPath = Path()
                leftPath.move(to: CGPoint(x: centerX - tw / 2 - 1, y: y))
                leftPath.addLine(to: CGPoint(x: centerX - tw / 2 - 1 - len, y: y))
                context.stroke(leftPath, with: .color(AppColors.tickMark), lineWidth: 1)

                var rightPath = Path()
                rightPath.move(to: CGPoint(x: centerX + tw / 2 + 1, y: y))
                rightPath.addLine(to: CGPoint(x: centerX + tw / 2 + 1 + len, y: y))
                context.stroke(rightPath, with: .color(AppColors.tickMark), lineWidth: 1)

                tick += minorStep
            }
        }
    }

    // MARK: - Cursor Overlay

    private func cursorOverlayView(cursorY: CGFloat, height: CGFloat) -> some View {
        Canvas { context, size in
            let y = cursorY
            guard y >= 0, y <= size.height else { return }

            let glowRect = CGRect(x: 0, y: y - 6, width: size.width, height: 12)
            context.fill(
                Ellipse().path(in: glowRect),
                with: .color(.white.opacity(0.15))
            )

            var linePath = Path()
            linePath.move(to: CGPoint(x: 0, y: y))
            linePath.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(linePath, with: .color(AppColors.cursor), lineWidth: cursorThickness)

            let dotRect = CGRect(
                x: size.width / 2 - cursorDotSize / 2,
                y: y - cursorDotSize / 2,
                width: cursorDotSize, height: cursorDotSize
            )
            context.fill(Circle().path(in: dotRect), with: .color(AppColors.cursor))
        }
        .animation(.easeOut(duration: 0.05), value: value)
    }

    // MARK: - Scale Labels

    /// Labels are drawn adjacent to the ticks and their y is clamped by half the
    /// text height, so the bottom (0) and top (90 / 100) labels stay fully
    /// visible instead of being cut in half by the canvas edge (M-UI11).
    private func scaleView(height: CGFloat, totalWidth: CGFloat) -> some View {
        let span = range.upperBound - range.lowerBound
        let steps = makeScaleSteps()
        let isLeading = labelsOnLeading
        let isAngle = label == "ANGLE"
        let inset = scaleInset
        let lower = range.lowerBound

        return Canvas { context, size in
            guard span > 0 else { return }
            let centerX = size.width / 2

            for tick in steps {
                let frac = (tick - lower) / span
                let rawY = size.height - (frac * size.height)

                let text = isAngle ? "\(Int(tick))°" : "\(Int(tick))"
                let resolved = context.resolve(
                    Text(text)
                        .font(.system(size: 13))
                        .foregroundStyle(AppColors.textSecondary)
                )
                let textSize = resolved.measure(in: size)

                // Keep the whole glyph inside the canvas vertically.
                let y = min(max(rawY, textSize.height / 2), size.height - textSize.height / 2)

                // Sit immediately outside the ticks, on the labelled side.
                let x: CGFloat = isLeading
                    ? centerX - inset - textSize.width / 2
                    : centerX + inset + textSize.width / 2

                context.draw(resolved, at: CGPoint(x: x, y: y))
            }
        }
        .frame(width: totalWidth, height: height)
    }

    private func makeScaleSteps() -> [Double] {
        if label == "ANGLE" {
            return stride(from: 0.0, through: 90.0, by: 15.0).map { $0 }
        } else {
            // Quarter steps including the maximum. With the MAX chip removed
            // (M-UI3) the top label is how the rider sees the gauge ceiling.
            let ub = range.upperBound
            return [0.0, 0.25, 0.50, 0.75, 1.0].map { $0 * ub }
        }
    }

    // MARK: - Value Readout

    private var valueReadoutView: some View {
        VStack(spacing: 0) {
            if label == "ANGLE" {
                Text("\(Int(value))°")
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppColors.accentBright)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            } else {
                Text("\(Int(value))")
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppColors.accentBright)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(unit)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppColors.accentBright)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Target Label

    /// `TARGET` + range, as a readout. It is no longer a tap target: the band is set
    /// by dragging on the track (see `targetDragGesture`), so there is nothing for a
    /// tap here to open.
    private func targetLabelView(band: MetricRange, height: CGFloat) -> some View {
        let rangeText: String = label == "ANGLE"
            ? "\(Int(band.lower))°-\(Int(band.upper))°"
            : "\(Int(band.lower))-\(Int(band.upper))"
        let triangleIcon = labelsOnLeading
            ? "arrowtriangle.right.fill"
            : "arrowtriangle.left.fill"

        return VStack(spacing: AppSpacing.xxs) {
            Text("TARGET")
                .font(.system(size: 11))
                .foregroundStyle(AppColors.accent)
            Text(rangeText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppColors.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Image(systemName: triangleIcon)
                .font(.system(size: 8))
                .foregroundStyle(AppColors.accent)
        }
        .padding(.vertical, 6)
        // Not interactive, so keep it out of the accessibility tree — the meter
        // element already announces the target in its value.
        .accessibilityHidden(true)
    }

    // MARK: - Computed

    private var fillFraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        let fraction = (value - range.lowerBound) / span
        return min(max(fraction, 0), 1)
    }

    /// Keep the value readout fully on-screen: it rides the cursor in the
    /// mid-range but stops at a safe margin from the track ends (M-UI12).
    private func clampedReadoutOffset(cursorY: CGFloat, height: CGFloat) -> CGFloat {
        let raw = cursorY - height / 2
        let margin: CGFloat = 32
        guard height > margin * 2 else { return 0 }
        return min(max(raw, -height / 2 + margin), height / 2 - margin)
    }

    /// Centre the TARGET label on the band, clamped to stay on-screen.
    private func clampedTargetOffset(band: MetricRange, height: CGFloat) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        let centerFrac = ((band.lower + band.upper) / 2.0 - range.lowerBound) / span
        let raw = height * (1 - centerFrac) - height / 2
        let margin: CGFloat = 40
        guard height > margin * 2 else { return 0 }
        return min(max(raw, -height / 2 + margin), height / 2 - margin)
    }

    private var accessibilityValueText: String {
        if let band = targetBand {
            return "\(Int(value)) \(unit), target \(Int(band.lower)) to \(Int(band.upper))"
        }
        return "\(Int(value)) \(unit)"
    }
}

/// A rectangle rounded on the bottom two corners only, with a flat top edge.
/// Used for the meter fill so it reads as a solid column meeting the cursor
/// line flat, while the track outline supplies the rounded look (M-UI15).
private struct BottomRoundedRect: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(radius, min(rect.width, rect.height) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
                    radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
                    radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.closeSubpath()
        return path
    }
}
