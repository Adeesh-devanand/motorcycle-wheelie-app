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
    let onRecalibrate: () -> Void

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
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(AppColors.accent.opacity(0.3), lineWidth: 1)

                    // The drawn line.
                    if let s = startPoint, let e = endPoint {
                        Path { p in p.move(to: s); p.addLine(to: e) }
                            .stroke(AppColors.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        // Bike glyph oriented ALONG the drawn line, pointing at the
                        // end (the front the rider indicated). This is the visible
                        // check: wrong orientation -> re-swipe.
                        Image(systemName: "bicycle")
                            .font(.system(size: 40))
                            .foregroundStyle(AppColors.accentBright)
                            .rotationEffect(.radians(atan2(e.y - s.y, e.x - s.x)))
                            .position(x: (s.x + e.x) / 2, y: (s.y + e.y) / 2)
                    } else {
                        Text("Swipe here")
                            .font(AppTypography.cardSubtitle)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { value in
                            if startPoint == nil { startPoint = value.startLocation }
                            endPoint = value.location
                        }
                        .onEnded { value in
                            startPoint = value.startLocation
                            endPoint = value.location
                            resolve(from: value.startLocation, to: value.location)
                        }
                )
                .frame(maxHeight: .infinity)
                .padding(AppSpacing.screenPadding)

                if let errorText {
                    Text(errorText)
                        .font(AppTypography.cardSubtitle)
                        .foregroundStyle(AppColors.warning)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: AppSpacing.xl) {
                    Button("Recalibrate") { onRecalibrate() }
                        .foregroundStyle(AppColors.textSecondary)

                    Button("Looks right") {
                        if let resolved { onConfirmed(resolved) }
                    }
                    .font(AppTypography.bodyText)
                    .foregroundStyle(resolved == nil ? AppColors.textSecondary : AppColors.accent)
                    .disabled(resolved == nil)
                }
                .padding(.bottom, AppSpacing.xxl)
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
