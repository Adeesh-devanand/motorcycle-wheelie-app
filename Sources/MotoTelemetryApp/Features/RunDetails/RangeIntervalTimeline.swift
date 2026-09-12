import SwiftUI

/// §9.6 — Single horizontal baseline with in-range intervals for both metrics.
/// Teal=angle, blue=speed, screen blending for overlap.
/// Tap a segment for callout details; tap sets selectedTime for chart scrubber sync.
struct RangeIntervalTimeline: View {
    let angleIntervals: [RangeInterval]
    let speedIntervals: [RangeInterval]
    let duration: TimeInterval
    @Binding var selectedTime: TimeInterval?
    let totalAngleInRange: TimeInterval
    let totalSpeedInRange: TimeInterval

    var angleColor: Color = AppColors.angleMetric
    var speedColor: Color = AppColors.speedMetric

    @State private var selectedInterval: SelectedInterval?
    @State private var showOverlapChooser = false
    @State private var overlapAngleHit: RangeInterval?
    @State private var overlapSpeedHit: RangeInterval?
    @State private var timelineWidth: CGFloat = 0

    private let trackHeight: CGFloat = 12
    /// How thick the in-range highlight bar is drawn. Deliberately thinner than the
    /// 6 pt endpoint dots so the dots read as caps on a slimmer line, not as beads on
    /// a bar of equal width. The bar used to fill the whole `trackHeight` (12 pt) —
    /// twice the dot diameter — so the dots vanished into it.
    private let segmentBarThickness: CGFloat = 3
    private let segmentRadius: CGFloat = 1.5
    private let markerSize: CGFloat = 8

    private struct SelectedInterval: Equatable {
        let interval: RangeInterval
        let ordinal: Int
        let total: Int
    }

    var body: some View {
        VStack(spacing: AppSpacing.sm) {
            // Timeline
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .center) {
                    // Baseline
                    Rectangle()
                        .fill(AppColors.gridLine)
                        .frame(height: 2)

                    // Endpoint circles
                    HStack {
                        Circle()
                            .fill(AppColors.textTertiary)
                            .frame(width: markerSize, height: markerSize)
                        Spacer()
                        Circle()
                            .fill(AppColors.textTertiary)
                            .frame(width: markerSize, height: markerSize)
                    }

                    // Interval segments rendered with Canvas for blending
                    Canvas { context, size in
                        context.blendMode = .screen

                        // Speed intervals
                        for interval in speedIntervals {
                            let rect = segmentRect(for: interval, in: size)
                            let path = RoundedRectangle(cornerRadius: segmentRadius)
                                .path(in: rect)
                            context.fill(path, with: .color(speedColor.opacity(0.65)))

                            // Endpoint markers
                            let leftCircle = CGRect(
                                x: rect.minX - 3, y: size.height / 2 - 3,
                                width: 6, height: 6
                            )
                            let rightCircle = CGRect(
                                x: rect.maxX - 3, y: size.height / 2 - 3,
                                width: 6, height: 6
                            )
                            context.fill(Circle().path(in: leftCircle), with: .color(speedColor))
                            context.fill(Circle().path(in: rightCircle), with: .color(speedColor))
                        }

                        // Angle intervals
                        for interval in angleIntervals {
                            let rect = segmentRect(for: interval, in: size)
                            let path = RoundedRectangle(cornerRadius: segmentRadius)
                                .path(in: rect)
                            context.fill(path, with: .color(angleColor.opacity(0.65)))

                            // Endpoint markers
                            let leftCircle = CGRect(
                                x: rect.minX - 3, y: size.height / 2 - 3,
                                width: 6, height: 6
                            )
                            let rightCircle = CGRect(
                                x: rect.maxX - 3, y: size.height / 2 - 3,
                                width: 6, height: 6
                            )
                            context.fill(Circle().path(in: leftCircle), with: .color(angleColor))
                            context.fill(Circle().path(in: rightCircle), with: .color(angleColor))
                        }

                        // Selected segment highlight
                        if let sel = selectedInterval {
                            let rect = segmentRect(for: sel.interval, in: size)
                            let path = RoundedRectangle(cornerRadius: segmentRadius)
                                .path(in: rect)
                            context.stroke(path, with: .color(.white.opacity(0.75)), lineWidth: 2)
                        }
                    }
                    .frame(height: trackHeight)

                    // Tap gesture overlay (44pt tall for hit radius)
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(height: 44)
                        .onTapGesture { location in
                            handleTap(at: location.x, in: width)
                        }
                }
                .frame(height: trackHeight)
                .onAppear { timelineWidth = width }
                .onChange(of: geo.size.width) { _, newW in timelineWidth = newW }
            }
            .frame(height: 44) // Account for 44pt tap target

            // Endpoint labels, one line each rather than a stacked pair — Run Details
            // has no scroll view, so a second line here is a second line taken off the
            // charts.
            HStack {
                Text(String(localized: "LIFT \(String(format: "%.1f", 0.0))s"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppColors.textTertiary)
                Spacer()
                Text(String(localized: "DOWN \(String(format: "%.1f", duration))s"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppColors.textTertiary)
            }

            // Boundary times
            boundaryTimesRow

            // ONE fixed-height slot shared by the hint, the overlap chooser and the
            // selected segment's detail.
            //
            // The detail used to be a full card that appeared on tap, below everything
            // else. Inside the old ScrollView that just made the page longer; on a
            // page that must fit the screen it would push the charts off the bottom
            // every time the rider tapped a segment. Reserving one row costs 26 pt
            // always and means tapping never changes the page's height.
            ZStack {
                if showOverlapChooser {
                    overlapChooserView
                } else if let sel = selectedInterval {
                    compactCallout(sel)
                } else {
                    Text("Tap a segment for details")
                        .font(.system(size: 12))
                        .foregroundStyle(AppColors.textTertiary)
                }
            }
            .frame(height: 26)
        }
        .padding(.vertical, AppSpacing.xs)
        .animation(.easeInOut(duration: 0.2), value: selectedInterval?.interval.id)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Range interval timeline, \(angleIntervals.count) angle intervals, \(speedIntervals.count) speed intervals")
        .accessibilityHint("Tap a segment for details")
    }

    // MARK: - Boundary Times Row

    private var boundaryTimesRow: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let allTimes = collectBoundaryTimes()
            let filtered = filterCollisions(times: allTimes, width: width)

            ZStack(alignment: .leading) {
                ForEach(filtered, id: \.self) { time in
                    let x = xPosition(for: time, in: width)
                    Text(String(format: "%.1fs", time))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(AppColors.textTertiary)
                        .position(x: x, y: 6)
                }
            }
        }
        .frame(height: 16)
    }

    private func collectBoundaryTimes() -> [Double] {
        var times: Set<Double> = []
        for interval in angleIntervals {
            times.insert(interval.start)
            times.insert(interval.end)
        }
        for interval in speedIntervals {
            times.insert(interval.start)
            times.insert(interval.end)
        }
        // Remove 0 and duration (shown by LIFT/DOWN)
        times.remove(0)
        if let dur = times.first(where: { abs($0 - duration) < 0.05 }) {
            times.remove(dur)
        }
        return times.sorted()
    }

    private func filterCollisions(times: [Double], width: CGFloat) -> [Double] {
        guard width > 0 else { return times }
        var result: [Double] = []
        var lastX: CGFloat = -40
        for t in times {
            let x = xPosition(for: t, in: width)
            if x - lastX > 32 {
                result.append(t)
                lastX = x
            }
        }
        return result
    }

    private func xPosition(for time: TimeInterval, in width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(time / duration) * width
    }

    // MARK: - Segment Geometry

    private func segmentRect(for interval: RangeInterval, in size: CGSize) -> CGRect {
        guard duration > 0 else { return .zero }
        let x = CGFloat(interval.start / duration) * size.width
        let w = CGFloat(interval.duration / duration) * size.width
        // Center the thin bar vertically; the endpoint dots are drawn separately at
        // their own (larger) 6 pt size, so they cap the ends rather than matching the
        // bar's width.
        let yOffset = (size.height - segmentBarThickness) / 2
        return CGRect(x: x, y: yOffset, width: max(w, 2), height: segmentBarThickness)
    }

    // MARK: - Tap Handling

    private func handleTap(at x: CGFloat, in width: CGFloat) {
        guard width > 0, duration > 0 else { return }
        let tapTime = Double(x / width) * duration
        let touchRadius = duration * 0.025

        showOverlapChooser = false
        overlapAngleHit = nil
        overlapSpeedHit = nil

        let angleHits = hitTest(tapTime, in: angleIntervals, radius: touchRadius)
        let speedHits = hitTest(tapTime, in: speedIntervals, radius: touchRadius)

        if let hit = angleHits.first, speedHits.isEmpty {
            toggleSelect(hit, metric: .angle, allIntervals: angleIntervals)
        } else if let hit = speedHits.first, angleHits.isEmpty {
            toggleSelect(hit, metric: .speed, allIntervals: speedIntervals)
        } else if let angleHit = angleHits.first, let speedHit = speedHits.first {
            // Overlap: show chooser
            overlapAngleHit = angleHit
            overlapSpeedHit = speedHit
            showOverlapChooser = true
        } else {
            // Tap on empty baseline — clear
            selectedInterval = nil
        }

        selectedTime = tapTime
    }

    private func hitTest(_ time: TimeInterval, in intervals: [RangeInterval], radius: TimeInterval) -> [RangeInterval] {
        intervals.filter { interval in
            time >= (interval.start - radius) && time <= (interval.end + radius)
        }
    }

    private func toggleSelect(_ interval: RangeInterval, metric: MetricKind, allIntervals: [RangeInterval]) {
        let sorted = allIntervals.sorted { $0.start < $1.start }
        let ordinal = (sorted.firstIndex { $0.id == interval.id } ?? 0) + 1
        if selectedInterval?.interval.id == interval.id {
            selectedInterval = nil
        } else {
            selectedInterval = SelectedInterval(interval: interval, ordinal: ordinal, total: sorted.count)
        }
    }

    // MARK: - Overlap Chooser

    private var overlapChooserView: some View {
        HStack(spacing: AppSpacing.sm) {
            Button {
                if let hit = overlapAngleHit {
                    toggleSelect(hit, metric: .angle, allIntervals: angleIntervals)
                }
                showOverlapChooser = false
            } label: {
                HStack(spacing: AppSpacing.xs) {
                    Circle().fill(angleColor).frame(width: 6, height: 6)
                    Text("ANGLE")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(angleColor)
                }
                .padding(.horizontal, AppSpacing.sm)
                .padding(.vertical, AppSpacing.xs)
                .background(AppColors.surfaceButton)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Button {
                if let hit = overlapSpeedHit {
                    toggleSelect(hit, metric: .speed, allIntervals: speedIntervals)
                }
                showOverlapChooser = false
            } label: {
                HStack(spacing: AppSpacing.xs) {
                    Circle().fill(speedColor).frame(width: 6, height: 6)
                    Text("SPEED")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(speedColor)
                }
                .padding(.horizontal, AppSpacing.sm)
                .padding(.vertical, AppSpacing.xs)
                .background(AppColors.surfaceButton)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Callout (one line, fits the reserved slot)

    /// Same three facts as the card it replaced — which metric, which of how many
    /// intervals, its bounds and its duration — on one line. The card version was
    /// ~86 pt tall and appeared only on tap, which is exactly the growth a page with
    /// no scroll view cannot absorb.
    private func compactCallout(_ sel: SelectedInterval) -> some View {
        let metricColor = sel.interval.metric == .angle ? angleColor : speedColor
        let metricName = sel.interval.metric == .angle ? "ANGLE" : "SPEED"

        return HStack(spacing: AppSpacing.xs) {
            Text("\(metricName) \(sel.ordinal)/\(sel.total)")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(metricColor)

            Text("\(String(format: "%.1f", sel.interval.start))s → \(String(format: "%.1f", sel.interval.end))s")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(metricColor)

            Text(String(localized: "· \(String(format: "%.1f", sel.interval.duration))s in range"))
                .font(.system(size: 12))
                .foregroundStyle(AppColors.textSecondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, AppSpacing.xxs)
        .background(AppColors.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(AppColors.cardBorder, lineWidth: 1)
        )
    }
}
