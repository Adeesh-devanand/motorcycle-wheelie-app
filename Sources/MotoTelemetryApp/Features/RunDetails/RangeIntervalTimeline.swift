import SwiftUI

/// §9.6 — Single horizontal bar showing in-range intervals for both metrics.
/// Teal=angle, blue=speed, additive blending for overlap.
/// Tap scrolls charts to that time via the selectedTime binding.
struct RangeIntervalTimeline: View {
    let angleIntervals: [RangeInterval]
    let speedIntervals: [RangeInterval]
    let duration: TimeInterval
    @Binding var selectedTime: TimeInterval?
    let totalAngleInRange: TimeInterval
    let totalSpeedInRange: TimeInterval

    @State private var selectedInterval: SelectedInterval?

    private let trackHeight: CGFloat = 12
    private let segmentRadius: CGFloat = 3

    private struct SelectedInterval: Equatable {
        let interval: RangeInterval
        let ordinal: Int
        let total: Int
    }

    var body: some View {
        VStack(spacing: AppSpacing.sm) {
            // Summary
            HStack {
                summaryPill(label: "ANGLE", duration: totalAngleInRange, color: Color(hex: 0x10B9B7))
                Spacer()
                summaryPill(label: "SPEED", duration: totalSpeedInRange, color: Color(hex: 0x238CD8))
            }

            // Timeline canvas
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    // Baseline track
                    RoundedRectangle(cornerRadius: segmentRadius)
                        .fill(Color(hex: 0x8191A0, opacity: 0.22))
                        .frame(height: trackHeight)

                    // Interval segments (screen blending)
                    Canvas { context, size in
                        context.blendMode = .screen

                        // Speed intervals (blue)
                        for interval in speedIntervals {
                            let rect = segmentRect(for: interval, in: size)
                            let path = RoundedRectangle(cornerRadius: segmentRadius)
                                .path(in: rect)
                            context.fill(path, with: .color(Color(hex: 0x238CD8, opacity: 0.62)))
                        }

                        // Angle intervals (teal)
                        for interval in angleIntervals {
                            let rect = segmentRect(for: interval, in: size)
                            let path = RoundedRectangle(cornerRadius: segmentRadius)
                                .path(in: rect)
                            context.fill(path, with: .color(Color(hex: 0x10B9B7, opacity: 0.62)))
                        }

                        // Selected highlight
                        if let sel = selectedInterval {
                            let rect = segmentRect(for: sel.interval, in: size)
                            let path = RoundedRectangle(cornerRadius: segmentRadius)
                                .path(in: rect)
                            context.stroke(path, with: .color(.white.opacity(0.6)), lineWidth: 1.5)
                        }
                    }
                    .frame(height: trackHeight)

                    // Tap gesture overlay
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(height: max(trackHeight, 44))
                        .onTapGesture { location in
                            handleTap(at: location.x, in: width)
                        }
                }
                .frame(height: trackHeight)
            }
            .frame(height: trackHeight)

            // Endpoint labels
            HStack {
                Text("LIFT 0.0s")
                    .font(.system(.caption2, design: .monospaced, weight: .medium))
                    .foregroundStyle(AppColors.textSecondary)
                Spacer()
                Text("DOWN \(String(format: "%.1f", duration))s")
                    .font(.system(.caption2, design: .monospaced, weight: .medium))
                    .foregroundStyle(AppColors.textSecondary)
            }

            // Detail bubble
            if let sel = selectedInterval {
                intervalDetail(sel)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, AppSpacing.sm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Range interval timeline, \(angleIntervals.count) angle intervals, \(speedIntervals.count) speed intervals")
        .accessibilityHint("Tap a segment for details")
    }

    // MARK: - Segment Geometry

    private func segmentRect(for interval: RangeInterval, in size: CGSize) -> CGRect {
        guard duration > 0 else { return .zero }
        let x = CGFloat(interval.start / duration) * size.width
        let w = CGFloat(interval.duration / duration) * size.width
        return CGRect(x: x, y: 0, width: max(w, 2), height: size.height)
    }

    // MARK: - Tap Handling

    private func handleTap(at x: CGFloat, in width: CGFloat) {
        guard width > 0, duration > 0 else { return }
        let tapTime = Double(x / width) * duration
        let touchRadius = duration * 0.02 // Expanded hit zone

        // Hit-test intervals
        let angleHits = hitTest(tapTime, in: angleIntervals, radius: touchRadius)
        let speedHits = hitTest(tapTime, in: speedIntervals, radius: touchRadius)

        if let hit = angleHits.first, speedHits.isEmpty {
            select(hit, metric: .angle, allIntervals: angleIntervals)
        } else if let hit = speedHits.first, angleHits.isEmpty {
            select(hit, metric: .speed, allIntervals: speedIntervals)
        } else if let angleHit = angleHits.first, speedHits.first != nil {
            // Overlap: prefer whichever centre is closer to tap
            let angleMid = (angleHit.start + angleHit.end) / 2
            let speedMid = (speedHits.first!.start + speedHits.first!.end) / 2
            if abs(angleMid - tapTime) <= abs(speedMid - tapTime) {
                select(angleHit, metric: .angle, allIntervals: angleIntervals)
            } else {
                select(speedHits.first!, metric: .speed, allIntervals: speedIntervals)
            }
        } else {
            selectedInterval = nil
        }

        // Scroll chart to tapped time
        selectedTime = tapTime
    }

    private func hitTest(_ time: TimeInterval, in intervals: [RangeInterval], radius: TimeInterval) -> [RangeInterval] {
        intervals.filter { interval in
            time >= (interval.start - radius) && time <= (interval.end + radius)
        }
    }

    private func select(_ interval: RangeInterval, metric: MetricKind, allIntervals: [RangeInterval]) {
        let sorted = allIntervals.sorted { $0.start < $1.start }
        let ordinal = (sorted.firstIndex { $0.id == interval.id } ?? 0) + 1
        if selectedInterval?.interval.id == interval.id {
            selectedInterval = nil
        } else {
            selectedInterval = SelectedInterval(interval: interval, ordinal: ordinal, total: sorted.count)
        }
    }

    // MARK: - Detail Bubble

    private func intervalDetail(_ sel: SelectedInterval) -> some View {
        let metricName = sel.interval.metric == .angle ? "ANGLE" : "SPEED"
        return TelemetryCard {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text("\(metricName) · RANGE \(sel.ordinal) OF \(sel.total)")
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                    .foregroundStyle(AppColors.textSecondary)
                Text("\(String(format: "%.1f", sel.interval.start))s → \(String(format: "%.1f", sel.interval.end))s")
                    .font(.system(.subheadline, design: .monospaced, weight: .medium))
                    .foregroundStyle(AppColors.textPrimary)
                Text("\(String(format: "%.1f", sel.interval.duration))s in range")
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Summary Pill

    private func summaryPill(label: String, duration: TimeInterval, color: Color) -> some View {
        HStack(spacing: AppSpacing.xs) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(label) \(String(format: "%.1f", duration))s")
                .font(.system(.caption, design: .monospaced, weight: .medium))
                .foregroundStyle(AppColors.textSecondary)
        }
    }
}
