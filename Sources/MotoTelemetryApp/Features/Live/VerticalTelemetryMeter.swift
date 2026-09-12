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
    private let majorTickLength: CGFloat = 12
    /// Clear air between the track's edge and where a spoke begins. Was effectively 1 pt,
    /// which read as the spokes growing out of the bar; they are a separate scale.
    private let tickGap: CGFloat = 4
    private let minorTickWidth: CGFloat = 0.5
    private let majorTickWidth: CGFloat = 0.75
    private let cursorOverhang: CGFloat = 6
    private let cursorThickness: CGFloat = 1
    private let cursorDotSize: CGFloat = 7

    // Meter-only colors: tuning these must not recolor cards, labels or run charts.
    // Meter accent — the rider-selected channel color (teal for ANGLE, blue for
    // SPEED by default). Defaulted like `labelsOnLeading` so neither the init nor
    // the two call sites need to change unless they set it. Everything the meter
    // tints — the fill column, the cursor glow, the target band, the value readout —
    // derives from THIS, so a single assignment recolors the whole channel while the
    // gradient TREATMENT (dark base → bright top) is preserved.
    var accentColor: Color = Color(hex: 0x3B82F6)

    // Derived meter blues → now derived from `accentColor` so the band and cursor
    // follow the channel. Kept as computed shades of the accent rather than fixed
    // hex, so a teal angle channel gets a teal band and cursor.
    private var targetTint: Color { accentColor }
    private var cursorTint: Color { accentColor.lightened(0.15) }

    /// How far the band spills past the track on the TARGET-label side. Deliberately
    /// tighter than the open side: the dashed top and bottom lines run the band's full
    /// width, and this is the side carrying the y-axis numbers, so a wide box here draws
    /// its lines straight through them. 12 pt puts the edge at 27 pt from centre against
    /// `scaleInset` at 34, leaving the numbers clear.
    private let bandSpillLabelSide: CGFloat = 12
    /// How far it spills on the opposite side, which holds nothing but tick marks. This
    /// is the only edge that fades, so it is also the fade's runway — hence the extra
    /// width.
    private let bandSpillOpenSide: CGFloat = 36

    /// Whether `value` is a real measurement.
    ///
    /// False means the source has nothing to report — no GNSS speed solution — and the
    /// meter renders that AS ZERO: readout 0, no fill, cursor at the bottom of the scale.
    ///
    /// The flag still has to exist even though the display no longer distinguishes the two
    /// cases, and this is the reason. The view model deliberately HOLDS the last displayed
    /// speed while no fix exists (smoothing toward 0 would invent a stationary bike), so
    /// `value` is a STALE reading in that state. Without this flag the meter renders the
    /// held number as a live one, which is what a device log caught stuck at 8 km/h,
    /// indefinitely, while the card beside it was still correct. `displayedValue` and
    /// `fillFraction` both consult it so nothing on the meter can reach the held value.
    var valueAvailable: Bool = true

    /// How far each meter's whole track is nudged toward the centre of the screen.
    /// Set by the caller, and only when both meters are on screen: every outboard
    /// element sits on the meter's OUTER side, so moving the track inboard is what buys
    /// the TARGET label room before it reaches the screen edge.
    var trackShiftTowardCenter: CGFloat = 0

    /// Gap between the end of a major tick and the scale label text.
    ///
    /// 6 rather than the original 4 keeps the numbers clear of the band's dashed outline,
    /// which is wider than it used to be. It does not need the 10 it briefly had, because
    /// `tickGap` now contributes 4 pt of its own and `majorTickLength` grew — `scaleInset`
    /// lands at 37 either way, against a band edge at 27.
    private let scaleLabelGap: CGFloat = 6
    /// Column widths for the outboard content.
    ///
    /// The readout column is wider when the unit sits BESIDE the number rather than being
    /// baked into the string: the angle reads "45°" in one run of glyphs, speed reads
    /// "120" + "km/h".
    ///
    /// 70 and not more, because the column starts at `scaleInset` and grows OUTWARD toward
    /// the screen edge: on a 375 pt phone the track centre has about 94 pt to the edge, the
    /// 16 pt inboard shift gives back 16, and the column starts 37 out — leaving roughly
    /// 73. An 84 pt column overflowed the screen on every phone narrower than a Pro Max.
    /// At 70, a two-digit speed ("45 km/h", ~69 pt) renders at full size and only a
    /// three-digit one leans on `minimumScaleFactor`.
    private var readoutWidth: CGFloat { unitSitsBesideValue ? 70 : 56 }
    /// True for every meter except angle, whose degree sign is part of the value text.
    private var unitSitsBesideValue: Bool { label != "ANGLE" }
    private let targetLabelWidth: CGFloat = 62

    /// Horizontal distance from the track centre to where scale labels sit — just beyond
    /// the longest spoke, including the gap that now separates the spokes from the bar.
    private var scaleInset: CGFloat {
        trackWidth / 2 + tickGap + majorTickLength + scaleLabelGap
    }

    /// Width the tick Canvas needs so a major spoke is not cut off.
    ///
    /// It used to be sized to `totalTrackWidth` (42 pt, i.e. 21 pt each side) while a
    /// major tick reached 25 pt — a `Canvas` clips to its bounds, so the major spokes were
    /// being trimmed by 4 pt and every one of them rendered the same length as it would
    /// at 21. Sizing from the geometry means the length constants mean what they say.
    private var tickCanvasWidth: CGFloat {
        // +1 of headroom: a major spoke ends exactly at the computed edge, and a path
        // terminating on a Canvas boundary can lose its last antialiased pixel.
        (trackWidth / 2 + tickGap + majorTickLength + 1) * 2
    }

    /// Horizontal distance from the track centre to the inner edge of the TARGET label.
    ///
    /// Measured from `scaleInset` rather than from the band, because the y-axis numbers
    /// are what it has to get past — the band's own edge (27 pt) is already inside them.
    /// It cannot clear them completely: the numbers run to roughly `scaleInset + 24` and
    /// the label's own frame is 62 pt wide, which together would push its outer edge past
    /// the half-screen this meter gets. So it sits just past their start and relies on the
    /// two rarely sharing a height — the label tracks the band's centre, the numbers sit
    /// at fixed 15 deg steps.
    private var targetLabelInset: CGFloat {
        scaleInset + 8
    }

    var body: some View {
        VStack(spacing: AppSpacing.sm) {
            Text(LocalizedStringKey(label))
                .font(.system(size: 15, weight: .medium))
                .tracking(1)
                .foregroundStyle(accentColor)

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
            // Track, centred in the available width. Carries the target-drag gesture,
            // so it must be the only hit-testable layer here.
            meterTrackView(height: height)

            // Scale labels, drawn across the full width so x/y are exact.
            //
            // `allowsHitTesting(false)` is load-bearing, not defensive. This Canvas is
            // sized to the WHOLE meter and sits ABOVE the track in the ZStack, so it
            // hit-tests first and swallowed every touch — the drag gesture on the
            // track never fired at all. Same for the two offset labels below: they
            // overlap the track once clamped toward the middle.
            scaleView(height: height, totalWidth: totalWidth)
                .allowsHitTesting(false)

            // Live value readout, riding the cursor but clamped on-screen.
            valueReadoutView
                .frame(width: readoutWidth, alignment: labelsOnLeading ? .trailing : .leading)
                .offset(
                    x: sign * (scaleInset + readoutWidth / 2),
                    y: clampedReadoutOffset(cursorY: cursorY, height: height)
                )
                .allowsHitTesting(false)

            // Target label, near the band centre. A readout only — the band is set by
            // dragging the track.
            if let band = targetBand {
                targetLabelView(band: band, height: height)
                    .frame(width: targetLabelWidth, alignment: labelsOnLeading ? .trailing : .leading)
                    .offset(
                        x: sign * (targetLabelInset + targetLabelWidth / 2),
                        y: clampedTargetOffset(band: band, height: height)
                    )
                    .allowsHitTesting(false)
            }
        }
        .frame(width: totalWidth, height: height)
        // Nudge the whole meter — track, scale, readout and TARGET label together —
        // toward the centre of the screen. Every outboard element is offset from the
        // track centre on the meter's OUTER side, and the label column reaches
        // `scaleInset + targetLabelWidth` (90 pt) from that centre against a half-width
        // of roughly 97, so it was running out of room at the screen edge. Moving the
        // track inboard buys that clearance without shrinking anything.
        //
        // Applied to the whole layout rather than the track alone, so the pointer, the
        // band and the label keep their relationship to each other.
        .offset(x: (labelsOnLeading ? 1 : -1) * trackShiftTowardCenter)
    }

    // MARK: - Meter Track

    private func meterTrackView(height: CGFloat) -> some View {
        let totalTrackWidth = trackWidth + cursorOverhang * 2

        return ZStack(alignment: .bottom) {
            // Quiet, neutral glass behind the target band and the blue column.
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0x0C1012), Color(hex: 0x090C0F)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: trackWidth, height: height)

            // Target band (behind the fill)
            if let band = targetBand {
                targetBandOverlay(band: band, height: height)
            }


            // The rim belongs above both the fill and target band, so it remains
            // legible through the target range and around the bottom of the gauge.
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.72), .white.opacity(0.38), .white.opacity(0.65)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.65
                )
                .frame(width: trackWidth, height: height)

            // Ticks on both sides. Sized from the tick geometry, NOT `totalTrackWidth` —
            // a Canvas clips to its bounds, and the major spokes now reach further out
            // than the cursor does.
            tickCanvas(height: height)
                .frame(width: tickCanvasWidth, height: height)

            // Fill column + cursor, drawn together from ONE interpolated fraction, ABOVE
            // the rim and ticks (where the cursor used to sit alone).
            //
            // These are the only two things that move with the reading, and they MUST move
            // as one — the cursor line sits exactly at the top of the fill. They used to be
            // a `Rectangle().frame(height:)` (a frame SwiftUI can tween) beside a `Canvas`
            // cursor (which it cannot), so under animation the fill glided while the cursor
            // snapped and they visibly separated. Rendering both inside a single
            // `Animatable` layer whose `animatableData` IS the fraction means SwiftUI feeds
            // it the same interpolated fraction on every native frame, so the fill top and
            // the cursor are computed from one number and cannot drift apart. This is also
            // what upsamples the 30 Hz data to the display's native 60/120 Hz: the view
            // model tweens `value` with `withAnimation(.linear(1/30))`, and this layer
            // redraws at each interpolated fraction between two samples.
            //
            // Drawn last so the cursor line and dot sit over the rim, exactly as before.
            // The fill is inset 1.5 pt inside the capsule and the track is narrower than
            // the tick canvas, so drawing it here does not paint over the rim edge or the
            // spokes.
            MeterFillCursorLayer(
                fraction: fillFraction,
                trackWidth: trackWidth,
                cursorThickness: cursorThickness,
                cursorDotSize: cursorDotSize,
                accent: accentColor,
                cursorGlow: cursorTint,
                cursorColor: AppColors.cursor
            )
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
        // `highPriorityGesture`, not `gesture`: the enclosing `TabView` has a paging
        // swipe, and a plain gesture loses the drag to it as soon as the movement has
        // any horizontal component. The cost is that swipe-paging no longer works when
        // the swipe STARTS on a meter track — the tab bar buttons, the header and the
        // bottom cards all still page — and a target you cannot set is worse than a
        // swipe you have to start 40 pt lower.
        .highPriorityGesture(targetDragGesture(height: height))
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

        // The fill sits exactly INSIDE the dashed outline — same width, same height — and
        // fades out on one edge only: the side away from the TARGET label, which is also
        // the only side with no dashed line to contradict the fade.
        //
        // The vertical spill is gone. Extending the fill above the upper bound and below
        // the lower bound made the glow overrun its own box, and the band should not read
        // as taller than the target it represents. Nothing fades on the label side either,
        // because that edge is a defined boundary: it has the dashed line and the pointer
        // hanging off it.
        let bandWidth = trackWidth + bandSpillLabelSide + bandSpillOpenSide
        // The band is wider on the open side, so its centre is off the track's centre by
        // half that difference.
        let openSideSign: CGFloat = labelsOnLeading ? 1 : -1
        let xShift = openSideSign * (bandSpillOpenSide - bandSpillLabelSide) / 2
        // Full strength from the label edge right across the track, fading only over the
        // spill beyond it — so nothing starts fading near the centre.
        let holdUntil = (bandSpillLabelSide + trackWidth) / bandWidth

        return ZStack {
            RoundedRectangle(cornerRadius: 2.5)
                .fill(openEdgeFade(color: targetTint.opacity(0.17), holdUntil: holdUntil))

            // Three sides, not four: top and bottom are the target's actual bounds, the
            // pointer side is closed because the arrow hangs off it, and the side away
            // from the label has no dashed edge at all.
            BandBracket(closedEdgeLeading: labelsOnLeading)
                .stroke(
                    targetTint.opacity(0.75),
                    style: StrokeStyle(lineWidth: 0.65, dash: [2.5, 2.5])
                )
                .mask(openEdgeFade(color: .white, holdUntil: holdUntil))
                // The pointer, sitting ON the band's closed edge and aimed OUTWARD, at
                // the TARGET label.
                //
                // It used to be the last item in the label's own VStack — a triangle
                // under the text, pointing back at the band from a distance, with nothing
                // joining the two. Its base now touches the bracket exactly and its
                // saturated blue tip points toward the existing label.
                .overlay(alignment: labelsOnLeading ? .leading : .trailing) {
                    BandPointer(pointsLeading: labelsOnLeading)
                        .fill(targetTint)
                        .frame(width: 5, height: 8)
                        .offset(x: labelsOnLeading ? -5 : 5)
                }
        }
        .frame(width: bandWidth, height: bandHeight)
        .offset(x: xShift, y: -bottomOffset)
    }

    /// Solid from the TARGET-label edge across the track, then a fade to nothing over the
    /// spill on the open side. The gradient runs label-side to open-side, which is why its
    /// start and end flip with `labelsOnLeading`.
    private func openEdgeFade(color: Color, holdUntil: CGFloat) -> LinearGradient {
        return LinearGradient(
            stops: [
                .init(color: color, location: 0),
                .init(color: color, location: holdUntil),
                .init(color: color.opacity(0), location: 1)
            ],
            startPoint: labelsOnLeading ? .leading : .trailing,
            endPoint: labelsOnLeading ? .trailing : .leading
        )
    }

    // MARK: - Tick Canvas

    private func tickCanvas(height: CGFloat) -> some View {
        let span = range.upperBound - range.lowerBound
        let minorStep = minorTickStep
        let perMajor = minorTicksPerMajor
        let tw = trackWidth
        let gap = tickGap
        let tl = tickLength
        let mtl = majorTickLength
        let minorW = minorTickWidth
        let majorW = majorTickWidth
        let lb = range.lowerBound
        let ub = range.upperBound
        // The track is a Capsule of width `trackWidth`, so its ends curve over a radius of
        // half that. Spokes are only drawn between the two caps — along the straight part
        // of the bar — because a spoke beside a curving edge does not line up with
        // anything.
        let capRadius = tw / 2

        return Canvas { context, size in
            guard span > 0, minorStep > 0 else { return }
            let centerX = size.width / 2
            let innerX = tw / 2 + gap

            var index = 0
            while true {
                let value = lb + Double(index) * minorStep
                if value > ub + 1e-6 { break }

                let frac = (value - lb) / span
                let y = size.height - (frac * size.height)
                // Majors by INDEX, so they are evenly spaced by construction: one major,
                // then five minors, then the next major. This replaced a modulo test
                // against `span / 4` with a 0.5-unit tolerance, which on the angle scale
                // (minor step 3, quarter step 22.5) only ever matched at 0, 45 and 90 —
                // three majors out of 31 spokes, at irregular gaps.
                let isMajor = index % perMajor == 0
                index += 1

                guard y >= capRadius, y <= size.height - capRadius else { continue }

                let len: CGFloat = isMajor ? mtl : tl
                let width: CGFloat = isMajor ? majorW : minorW

                var leftPath = Path()
                leftPath.move(to: CGPoint(x: centerX - innerX, y: y))
                leftPath.addLine(to: CGPoint(x: centerX - innerX - len, y: y))
                context.stroke(leftPath, with: .color(AppColors.tickMark), lineWidth: width)

                var rightPath = Path()
                rightPath.move(to: CGPoint(x: centerX + innerX, y: y))
                rightPath.addLine(to: CGPoint(x: centerX + innerX + len, y: y))
                context.stroke(rightPath, with: .color(AppColors.tickMark), lineWidth: width)
            }
        }
    }

    /// How many equal intervals the scale is divided into, and therefore
    /// `scaleDivisions + 1` labelled major spokes. Six, because that is what puts the
    /// angle axis on 15 deg steps across 0-90 — and speed now uses the SAME number so the
    /// two meters standing side by side read as one instrument at any ceiling.
    ///
    /// Read from `MeterScale` rather than declared here, because
    /// `RiderPreferences.gaugeMaximumOptions` derives the selectable ceilings from the same
    /// constant: every one is a multiple of `divisions * 5`, so dividing by 6 always lands
    /// on whole multiples of 5. Two independent literals would let that agreement rot.
    private var scaleDivisions: Int { MeterScale.divisions }

    /// Value step between MAJOR spokes — the span divided into `scaleDivisions`, and the
    /// same step `makeScaleSteps()` prints numbers at, so every number lands on a major
    /// spoke instead of floating between two minors.
    ///
    /// One formula for both meters now. It was `15` for angle and `span / 4` for speed, so
    /// the two axes side by side had different numbers of divisions — six against four —
    /// and at a 90 km/h ceiling the speed axis read 0/22.5/45/67.5/90 next to the angle's
    /// 0/15/30/45/60/75/90. Deriving both from the span makes them identical at every
    /// ceiling, and on the 0-90 angle axis it still evaluates to exactly 15.
    private var majorTickStep: Double {
        (range.upperBound - range.lowerBound) / Double(scaleDivisions)
    }

    /// Five minor spokes between each pair of majors, hence six steps per major.
    private var minorTicksPerMajor: Int { 6 }

    private var minorTickStep: Double {
        majorTickStep / Double(minorTicksPerMajor)
    }

    // MARK: - Cursor Overlay

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
                        .foregroundStyle(accentColor)
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

    /// The labelled values: one per major spoke, from the lower bound to the ceiling
    /// inclusive.
    ///
    /// Was two hardcoded branches — a 15 deg stride for angle, quarter steps for speed —
    /// which is what made the two axes disagree. Deriving them from `majorTickStep` means
    /// the numbers cannot drift from the spokes they sit on, and both meters get the same
    /// count by construction rather than by two literals happening to agree.
    private func makeScaleSteps() -> [Double] {
        let step = majorTickStep
        guard step > 0 else { return [range.lowerBound] }
        return (0...scaleDivisions).map { range.lowerBound + Double($0) * step }
    }

    // MARK: - Value Readout

    private var valueReadoutView: some View {
        VStack(spacing: 0) {
            if label == "ANGLE" {
                Text("\(Int(displayedValue))°")
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .foregroundStyle(accentColor.lightened(0.2))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            } else {
                // Unit BESIDE the number, not under it. Stacked, the readout was two lines
                // tall, and its lower line reached down far enough that at a reading of 0 —
                // when the readout is clamped near the bottom of the track — the "km/h" sat
                // on top of the y-axis's own "0" label. Side by side it is one line, which
                // removes about 16 pt of height from exactly the end where the collision
                // happened.
                //
                // `lastTextBaseline` so the small unit sits on the digits' baseline rather
                // than centred against their full cap height.
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text("\(Int(displayedValue))")
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .foregroundStyle(accentColor.lightened(0.2))
                    Text(unit)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(accentColor.lightened(0.2))
                }
                .lineLimit(1)
                // The enclosing `.frame(width: readoutWidth)` is what this scales against.
                // Needed because "300 km/h" is the widest this can get and it is wider than
                // a two-digit speed by half a digit — without it a three-digit reading
                // would overflow the column outward, toward the screen edge.
                .minimumScaleFactor(0.6)
            }
        }
    }

    /// What the readout shows: the reading, or 0 when there is none.
    ///
    /// A rider's call, made knowingly against R15.3's "never a fabricated 0": with no GNSS
    /// speed solution the meter reads 0 km/h rather than a dash, so "stopped" and "no
    /// satellites" look the same on screen. The distinction survives where it costs nothing
    /// visually — the accessibility value still says so, and the log still records
    /// `speedAvailable`.
    ///
    /// It is a LITERAL 0 and deliberately not `value`, and that is what keeps the
    /// stuck-reading bug from coming back. The view model HOLDS the last displayed speed
    /// while no fix exists (smoothing toward 0 would invent a stationary bike), so `value`
    /// is a stale number in that state — rendering it is precisely what pinned this meter
    /// at 8 km/h indefinitely. Showing 0 never consults it.
    private var displayedValue: Double {
        valueAvailable ? value : 0
    }

    // MARK: - Target Label

    /// `TARGET` + range, as a readout. It is no longer a tap target: the band is set
    /// by dragging on the track (see `targetDragGesture`), so there is nothing for a
    /// tap here to open.
    ///
    /// The pointer triangle that used to close this VStack has moved onto the band's
    /// outer edge (see `targetBandOverlay`), where it points outward at this text. It
    /// was previously *below* the text and aimed back at the band across empty space,
    /// which left the two things it was meant to connect unconnected.
    private func targetLabelView(band: MetricRange, height: CGFloat) -> some View {
        let rangeText: String = label == "ANGLE"
            ? "\(Int(band.lower))°-\(Int(band.upper))°"
            : "\(Int(band.lower))-\(Int(band.upper))"

        return VStack(spacing: AppSpacing.xxs) {
            Text("TARGET")
                .font(.system(size: 11))
                .foregroundStyle(accentColor)
            Text(rangeText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(accentColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.vertical, 6)
        // Not interactive, so keep it out of the accessibility tree — the meter
        // element already announces the target in its value.
        .accessibilityHidden(true)
    }

    // MARK: - Computed

    private var fillFraction: Double {
        // No reading means no bar. Not 0 because the bike is stopped — 0 because there is
        // nothing to draw, which is also why the cursor and the numeric readout are
        // suppressed rather than shown at the bottom of the scale.
        guard valueAvailable else { return 0 }
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        let fraction = (value - range.lowerBound) / span
        return min(max(fraction, 0), 1)
    }

    /// Keep the value readout fully on-screen: it rides the cursor in the
    /// mid-range but stops at a safe margin from the track ends (M-UI12).
    ///
    /// The margin also has to clear the y-axis's END labels, which live in the same
    /// column: the readout is offset from `scaleInset`, exactly where the scale numbers
    /// start, so the two only avoid each other by being at different heights. 40 rather
    /// than the previous 32 because at a reading of 0 the readout is pinned at its lowest
    /// and the "0" label is directly beneath it — 32 left the readout's bottom edge inside
    /// that label's box. Worth pairing with the one-line readout: both were needed.
    private func clampedReadoutOffset(cursorY: CGFloat, height: CGFloat) -> CGFloat {
        let raw = cursorY - height / 2
        let margin: CGFloat = 40
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
        // The number matches the screen — 0 when there is no fix — but the spoken value
        // ALSO says the signal is missing. Additive rather than a different reading, and
        // the one place the distinction survives at no visual cost now that the meter
        // shows 0 instead of a dash.
        let reading = "\(Int(displayedValue)) \(unit)"
        let signal = valueAvailable ? "" : ", no GNSS signal"
        if let band = targetBand {
            return "\(reading)\(signal), target \(Int(band.lower)) to \(Int(band.upper))"
        }
        return "\(reading)\(signal)"
    }
}

/// Fill column and cursor, drawn from ONE `fraction` and animated as one unit.
///
/// This is the piece that makes 30 Hz data look like 60/120 fps and keeps the bar and the
/// line locked together. `animatableData` is the fraction itself, so when the view model
/// changes the reading inside `withAnimation(.linear(duration: 1/30))`, SwiftUI calls this
/// layer once per NATIVE display frame with the fraction interpolated toward its new value.
/// Every frame the fill top and the cursor are recomputed from that same interpolated
/// number, so they move continuously and can never separate — which a `Rectangle().frame`
/// (tweenable) next to a `Canvas` cursor (not tweenable) could not guarantee.
///
/// Both are rendered in a single `Canvas` for one more reason: a Canvas draws exactly what
/// the current `fraction` says, with no implicit frame animation of its own to fight the
/// explicit one. The fill grows from the bottom (`y = height` at fraction 0) up to
/// `cursorY`, and the cursor sits at `cursorY` — the same y, by construction.
private struct MeterFillCursorLayer: View, Animatable {
    var fraction: Double
    let trackWidth: CGFloat
    let cursorThickness: CGFloat
    let cursorDotSize: CGFloat
    /// The channel accent — the fill column's gradient is derived from this so the
    /// bar reads teal (angle) or blue (speed) while keeping the dark-base→bright-top
    /// treatment.
    let accent: Color
    /// The diffuse glow under the cursor hairline, a lighter shade of the accent.
    let cursorGlow: Color
    let cursorColor: Color

    /// The interpolated quantity. SwiftUI drives this between the old and new fraction
    /// across the native frames of the `withAnimation` transaction; everything the layer
    /// draws is a function of it, so fill and cursor advance together frame by frame.
    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let clamped = min(max(fraction, 0), 1)
            let cursorY = size.height * (1 - clamped)
            let centerX = size.width / 2

            // Fill: a bottom-anchored rounded column from the base up to the cursor line,
            // clipped to the track capsule inset by 1.5 pt (matching the rim inset) so it
            // never paints over the rim edge. Its TOP is exactly `cursorY`.
            let fillHeight = size.height - cursorY
            if fillHeight > 0 {
                let trackX = centerX - trackWidth / 2
                let capsule = Capsule().path(
                    in: CGRect(x: trackX, y: 0, width: trackWidth, height: size.height)
                        .insetBy(dx: 1.5, dy: 1.5)
                )
                context.drawLayer { fill in
                    fill.clip(to: capsule)
                    let fillRect = CGRect(x: trackX, y: cursorY, width: trackWidth, height: fillHeight)
                    fill.fill(
                        Path(fillRect),
                        with: .linearGradient(
                            // Derived from the channel accent so the bar reads in the
                            // rider's chosen colour, preserving the original dark-base →
                            // bright-top treatment: a deep shade at the base, the accent
                            // itself at the cursor.
                            Gradient(stops: [
                                .init(color: accent.darkenedTrack, location: 0),
                                .init(color: accent.darkened(0.35), location: 0.55),
                                .init(color: accent, location: 1)
                            ]),
                            startPoint: CGPoint(x: trackX, y: size.height),
                            endPoint: CGPoint(x: trackX, y: 0)
                        )
                    )
                }
            }

            guard cursorY >= 0, cursorY <= size.height else { return }

            // Cursor line + dot, sitting at the fill's top edge.
            var linePath = Path()
            linePath.move(to: CGPoint(x: 0, y: cursorY))
            linePath.addLine(to: CGPoint(x: size.width, y: cursorY))
            let dotRect = CGRect(
                x: centerX - cursorDotSize / 2,
                y: cursorY - cursorDotSize / 2,
                width: cursorDotSize, height: cursorDotSize
            )

            // Diffuse blue light under a crisp white hairline and marker.
            context.drawLayer { glow in
                glow.addFilter(.blur(radius: 4))
                glow.stroke(linePath, with: .color(cursorGlow.opacity(0.65)), lineWidth: 3)
                glow.fill(
                    Circle().path(in: dotRect.insetBy(dx: -3, dy: -3)),
                    with: .color(cursorGlow.opacity(0.55))
                )
            }
            context.stroke(linePath, with: .color(cursorColor), lineWidth: cursorThickness)
            context.fill(Circle().path(in: dotRect), with: .color(cursorColor))
        }
    }
}

/// The target band's outline, with ONE vertical edge instead of two.
///
/// Top and bottom are the band's real information — the lower and upper bound of the
/// target — so they are always drawn. Only the edge on the TARGET label's side is closed,
/// because that is where the pointer attaches. The opposite edge is deliberately absent:
/// the fill fades out across that spill, and a crisp dashed line at the end of a fade
/// contradicts it.
private struct BandBracket: Shape {
    /// True when the closed vertical edge is the leading one (the angle meter, whose
    /// labels sit on the left).
    var closedEdgeLeading: Bool

    func path(in rect: CGRect) -> Path {
        let r = min(2.5, rect.height / 2)
        let closedX = closedEdgeLeading ? rect.minX : rect.maxX
        let openX = closedEdgeLeading ? rect.maxX : rect.minX
        let direction: CGFloat = closedEdgeLeading ? 1 : -1
        var path = Path()
        path.move(to: CGPoint(x: openX, y: rect.minY))
        path.addLine(to: CGPoint(x: closedX + direction * r, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: closedX, y: rect.minY + r),
            control: CGPoint(x: closedX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: closedX, y: rect.maxY - r))
        path.addQuadCurve(
            to: CGPoint(x: closedX + direction * r, y: rect.maxY),
            control: CGPoint(x: closedX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: openX, y: rect.maxY))
        return path
    }
}

/// Its base touches the bracket; its tip points out toward the target label.
private struct BandPointer: Shape {
    var pointsLeading: Bool

    func path(in rect: CGRect) -> Path {
        let baseX = pointsLeading ? rect.maxX : rect.minX
        let tipX = pointsLeading ? rect.minX : rect.maxX
        var path = Path()
        path.move(to: CGPoint(x: baseX, y: rect.minY))
        path.addLine(to: CGPoint(x: tipX, y: rect.midY))
        path.addLine(to: CGPoint(x: baseX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

#if DEBUG
/// Static fixtures for comparing the meter artwork without a sensor session.
private struct MeterArtworkPreview: View {
    var atLimits = false

    var body: some View {
        HStack(spacing: 0) {
            meter(value: atLimits ? 90 : 38, label: "ANGLE", leading: true,
                  target: MetricRange(lower: atLimits ? 80 : 35, upper: atLimits ? 90 : 45))
            meter(value: atLimits ? 0 : 42, label: "SPEED", leading: false,
                  target: MetricRange(lower: atLimits ? 0 : 35, upper: atLimits ? 10 : 50))
        }
        .padding(16)
        .background(AppColors.background)
    }

    private func meter(value: Double, label: String, leading: Bool, target: MetricRange) -> some View {
        var meter = VerticalTelemetryMeter(
            value: value, range: 0...90, targetBand: target,
            unit: leading ? "°" : "km/h", label: label
        )
        meter.labelsOnLeading = leading
        meter.trackShiftTowardCenter = 16
        return meter
    }
}

struct VerticalTelemetryMeter_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            MeterArtworkPreview()
                .previewLayout(.fixed(width: 375, height: 560))
                .previewDisplayName("Target bands — 38° / 42 km/h")
            MeterArtworkPreview(atLimits: true)
                .previewLayout(.fixed(width: 320, height: 480))
                .previewDisplayName("Compact — empty / full scale")
        }
        .preferredColorScheme(.dark)
    }
}
#endif
