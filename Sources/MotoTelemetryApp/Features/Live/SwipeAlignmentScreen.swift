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
                Text("Draw a line along the bike,\nfront to back")
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

                    // The drawn line.
                    if let s = startPoint, let e = endPoint {
                        Path { p in p.move(to: s); p.addLine(to: e) }
                            .stroke(AppColors.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .allowsHitTesting(false)
                        // Bike glyph oriented ALONG the drawn line, pointing at the
                        // end (the front the rider indicated). This is the visible
                        // check: wrong orientation -> re-swipe.
                        Image(systemName: "bicycle")
                            .font(.system(size: 40))
                            .foregroundStyle(AppColors.accentBright)
                            .rotationEffect(.radians(atan2(e.y - s.y, e.x - s.x)))
                            .position(x: (s.x + e.x) / 2, y: (s.y + e.y) / 2)
                            .allowsHitTesting(false)
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
