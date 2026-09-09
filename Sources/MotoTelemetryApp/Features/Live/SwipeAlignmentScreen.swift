import SwiftUI
import MotoTelemetryCore

/// Draw-a-line-along-the-chassis capture, shown the instant calibration completes.
///
/// The rider drags one line down the length of the bike. That line's direction in
/// the screen plane, plus the gravity anchor from calibration, fully determines the
/// phone->bike alignment (`MountAlignment.fromSwipe`). A bike-orientation glyph is
/// drawn ALONG the line the rider drew, so if the app resolved the wrong way the
/// rider sees it immediately and re-swipes — the design's answer to the one case the
/// math cannot self-check (a sideways swipe on a bar mount reads with full
/// confidence but is 90 degrees wrong).
///
/// The `|p|` classification is invisible to the rider and needs no UI: a swipe along
/// gravity (vertical mount) routes to the screen-normal branch inside the solver,
/// and only a zero-length tap is rejected.
struct SwipeAlignmentScreen: View {
    /// Gravity anchor (device-frame specific force) from the completed calibration.
    let gravityAnchor: Vector3
    let config: Config
    let bikeProfileID: UUID
    /// Called with the resolved alignment when the rider confirms.
    let onConfirmed: (MountAlignment) -> Void
    /// Sends the rider back to recalibrate.
    /// `@MainActor` so the isolation of the handler survives being stored here.
    /// It is invoked from a SwiftUI Button and calls main-actor state; a plain
    /// `() -> Void` silently drops that, which Swift 6 makes an error.
    let onRecalibrate: @MainActor () -> Void

    @State private var startPoint: CGPoint?
    @State private var endPoint: CGPoint?
    @State private var resolved: MountAlignment?
    @State private var errorText: String?

    var body: some View {
        ZStack {
            AppColors.background.ignoresSafeArea()

            VStack(spacing: AppSpacing.lg) {
                // "back to front", NOT "front to back", which is what this said.
                //
                // `MountAlignment.fromSwipe` takes `atan2(-screenDY, screenDX)` over
                // `end - start` AS the bike's forward axis, so the direction of the drag
                // IS forward. A rider who followed the old wording literally — start at
                // the nose, finish at the tail — handed the solver a reversed forward
                // axis, which is the silent 180-degree error `fromSwipe`'s own
                // documentation warns reports every wheelie as a stoppie. The glyph made
                // it *catchable* (it would draw the bike facing the way they dragged,
                // i.e. backwards) but the instruction was actively steering them into it.
                Text("Draw a line along the bike,\nback to front")
                    .font(AppTypography.bodyText)
                    .foregroundStyle(AppColors.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.top, AppSpacing.xxl)

                ZStack {
                    // The guide box is now VISUAL ONLY, inset inside the drawing surface
                    // rather than being its edge. The padding used to sit on the outer
                    // chain, below the gesture — so the surface that both received the
                    // drag and drew the line was exactly the box, and a line could not be
                    // finished outside it. Every decorative child is
                    // `allowsHitTesting(false)` for the same reason `scaleView` is on the
                    // meters: the bike glyph is `.position`-ed, which expands its
                    // container to fill the whole area, and it would then hit-test before
                    // the drag on the parent.
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(AppColors.accent.opacity(0.3), lineWidth: 1)
                        .padding(AppSpacing.xl)
                        .allowsHitTesting(false)

                    // The drawn line, in two segments with a gap for the bike.
                    if let s = startPoint, let e = endPoint {
                        lineWithGapForGlyph(from: s, to: e)
                        bikeGlyph(from: s, to: e)
                    } else {
                        Text("Swipe here")
                            .font(AppTypography.cardSubtitle)
                            .foregroundStyle(AppColors.textSecondary)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                // `highPriorityGesture`, not `gesture`: this screen sits inside the app's
                // `TabView`, whose paging swipe claims a drag as soon as it has any
                // horizontal component — and a line drawn along a bike is almost entirely
                // horizontal, so the paging gesture is competing for exactly the stroke
                // the rider is trying to make. Same reason the meter tracks use it.
                .highPriorityGesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { value in
                            // `startLocation` is constant for the life of one drag, so
                            // assigning it unconditionally both anchors the first frame
                            // and RE-anchors on a second attempt.
                            //
                            // The `startPoint == nil` guard this replaces only ever fired
                            // once, on the very first swipe. On a re-draw it left the
                            // PREVIOUS attempt's start in place while `endPoint` followed
                            // the new finger, so the rider saw a line hinged on the old
                            // start point sweeping to the new one, snapping into place
                            // only on lift-off when `onEnded` finally reassigned it.
                            if startPoint != value.startLocation {
                                startPoint = value.startLocation
                                // The previous solution describes a line no longer on
                                // screen. Drop it so "Looks right" cannot confirm an
                                // alignment the rider has stopped looking at.
                                resolved = nil
                                errorText = nil
                            }
                            endPoint = value.location
                        }
                        .onEnded { value in
                            startPoint = value.startLocation
                            endPoint = value.location
                            resolve(from: value.startLocation, to: value.location)
                        }
                )
                .frame(maxHeight: .infinity)
                // No padding here any more — it moved onto the guide outline above. The
                // surface is full-bleed so the stroke can run past the box (and to the
                // screen edges) and still be delivered and drawn.

                // Constant-height slot, NOT `if let errorText`. The drawing area above
                // is `maxHeight: .infinity`, so it absorbs whatever this row gives up:
                // a message appearing or clearing resized the canvas under the rider's
                // finger, and every already-drawn point moved with it. Reserving the
                // space means the canvas geometry — and so the line — never moves.
                Text(errorText ?? "")
                    .font(AppTypography.cardSubtitle)
                    .foregroundStyle(AppColors.warning)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .frame(height: 34)
                    .padding(.horizontal, AppSpacing.screenPadding)

                // Two real buttons of equal size. They were a plain `Button("Recalibrate")`
                // in secondary grey beside a `Button("Looks right")` at a different font
                // — two different sizes for the two halves of one decision, which reads
                // as one label and one control rather than a choice.
                //
                // Both labels also said the wrong thing. "Recalibrate" names the screen
                // it returns to, not what the rider is doing (abandoning this alignment
                // and re-zeroing the gyro), and "Looks right" is an opinion, not an
                // action — it does not say that tapping it commits the alignment and
                // moves on.
                HStack(spacing: AppSpacing.md) {
                    Button { onRecalibrate() } label: {
                        Text("Redo gyro zero")
                            .font(AppTypography.bodyText.weight(.semibold))
                            .foregroundStyle(AppColors.textSecondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(AppColors.surfaceButton)
                            .clipShape(RoundedRectangle(cornerRadius: AppSpacing.CornerRadius.button))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Discards this alignment and measures the gyro bias again")

                    Button {
                        if let resolved { onConfirmed(resolved) }
                    } label: {
                        Text("Confirm alignment")
                            .font(AppTypography.bodyText.weight(.semibold))
                            .foregroundStyle(resolved == nil
                                             ? AppColors.textTertiary
                                             : AppColors.badgeSuccessText)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(resolved == nil
                                        ? AppColors.surfaceButton
                                        : AppColors.badgeSuccessFill)
                            .clipShape(RoundedRectangle(cornerRadius: AppSpacing.CornerRadius.button))
                    }
                    .buttonStyle(.plain)
                    .disabled(resolved == nil)
                    .accessibilityHint(resolved == nil
                                       ? "Draw a line along the bike first"
                                       : "Saves this mount alignment and starts the live meter")
                }
                .padding(.horizontal, AppSpacing.screenPadding)
                .padding(.bottom, AppSpacing.xl)
            }
        }
    }

    // MARK: - Line and glyph

    /// Length of the bike glyph ALONG the drawn line.
    ///
    /// The gap in the line is derived from this, so the two scale together — but note the
    /// side effect: `bikeGlyphGap * 2` is the shortest line that gets any stroke drawn at
    /// all, so a bigger bike means a longer minimum line. At 144 that threshold is 160 pt,
    /// which a line drawn along a bike comfortably clears on any phone.
    private let bikeGlyphLength: CGFloat = 144

    /// How far short of the midpoint each half of the line stops. Half the glyph plus a
    /// little air, so the stroke meets the bike's nose and tail without touching them.
    private var bikeGlyphGap: CGFloat { bikeGlyphLength / 2 + 8 }

    /// The rider's line, drawn as TWO segments with the middle left empty for the bike.
    ///
    /// One continuous stroke ran straight through the glyph, which on a top-down bike
    /// reads as a spear through the tank rather than as an axis along it.
    @ViewBuilder
    private func lineWithGapForGlyph(from s: CGPoint, to e: CGPoint) -> some View {
        let dx = e.x - s.x
        let dy = e.y - s.y
        let length = (dx * dx + dy * dy).squareRoot()

        // Below twice the gap there is no line left to draw on either side, and forcing
        // one would poke a stub out of each end of the bike. The glyph alone carries it.
        if length > bikeGlyphGap * 2 {
            let ux = dx / length
            let uy = dy / length
            let mid = CGPoint(x: (s.x + e.x) / 2, y: (s.y + e.y) / 2)

            Path { p in
                p.move(to: s)
                p.addLine(to: CGPoint(x: mid.x - ux * bikeGlyphGap,
                                      y: mid.y - uy * bikeGlyphGap))
                p.move(to: CGPoint(x: mid.x + ux * bikeGlyphGap,
                                   y: mid.y + uy * bikeGlyphGap))
                p.addLine(to: e)
            }
            .stroke(AppColors.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            .allowsHitTesting(false)
        }
    }

    /// The bike, laid along the drawn line with its NOSE at the end of the drag.
    ///
    /// Pointing at `end` is not a style choice — it is what `MountAlignment.fromSwipe`
    /// decided. That takes `atan2(-screenDY, screenDX)` over `end - start` AS the bike's
    /// forward axis, so the direction the rider dragged IS forward. Drawing the bike any
    /// other way would show them something the estimator does not believe, and this glyph
    /// exists precisely so a 180-degree error is visible instead of silent.
    ///
    /// `BikeTopDown` is authored pointing UP the screen (nose at the asset's top, mirrors
    /// just below it), i.e. its forward is −Y. Rotation is therefore the line's angle PLUS
    /// a quarter turn: at zero rotation the glyph faces −Y, and `rotationEffect` turns
    /// clockwise in this coordinate space, so `+.pi / 2` brings its nose onto +X before
    /// the line's own angle carries it the rest of the way.
    ///
    /// Template-rendered so `foregroundStyle` tints it, and tinted with `accent` — the
    /// line's own colour — rather than `accentBright`, so the bike and the axis it sits on
    /// read as one mark.
    private func bikeGlyph(from s: CGPoint, to e: CGPoint) -> some View {
        Image("BikeTopDown")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            // The box is deliberately wider in ratio (0.7) than the asset (0.536), so the
            // HEIGHT is what binds and the glyph's length along the line is exactly
            // `bikeGlyphLength` at any aspect the artwork happens to have.
            .frame(width: bikeGlyphLength * 0.7, height: bikeGlyphLength)
            .foregroundStyle(AppColors.accent)
            .rotationEffect(.radians(atan2(Double(e.y - s.y), Double(e.x - s.x)) + .pi / 2))
            .position(x: (s.x + e.x) / 2, y: (s.y + e.y) / 2)
            .allowsHitTesting(false)
    }

    private func resolve(from start: CGPoint, to end: CGPoint) {
        // Screen deltas: dx right-positive, dy DOWN-positive (UIKit/SwiftUI). The
        // solver applies the upward-Y flip internally, so hand it the raw deltas —
        // negating here as well would double-flip and report every wheelie backward.
        let dx = end.x - start.x
        let dy = end.y - start.y
        switch MountAlignment.fromSwipe(specificForce: gravityAnchor,
                                        screenDX: Double(dx),
                                        screenDY: Double(dy),
                                        config: config,
                                        bikeProfileID: bikeProfileID) {
        case .success(let alignment):
            resolved = alignment
            errorText = nil
        case .failure(let failure):
            resolved = nil
            errorText = failure.message
        }
    }
}
