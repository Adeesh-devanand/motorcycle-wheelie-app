import MotoTelemetryCore
import SwiftUI

/// §8.3 — Row card: time column, three ranked metric columns with mini bars, trailing chevron.
struct RunHistoryRow: View {
    let run: WheelieRun
    let colorScale: RelativeMetricColorScale
    let fieldAnchors: PastRunsViewModel.FieldAnchors
    var isLatest: Bool = false
    var isLongest: Bool = false
    var isFastest: Bool = false
    var isHighest: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            // TIME column
            timeColumn
                .frame(width: 96, alignment: .leading)

            // Three metric columns
            HStack(spacing: 0) {
                metricColumn(
                    value: run.duration,
                    format: "%.1f",
                    unit: "s",
                    normalised: normalise(value: run.duration, min: fieldAnchors.durationMin, max: fieldAnchors.durationMax),
                    color: durationColor,
                    trackColor: durationColor.darkenedTrack
                )
                .frame(maxWidth: .infinity)

                metricColumn(
                    value: run.maxAngle,
                    format: "%.0f",
                    unit: "°",
                    normalised: normalise(value: run.maxAngle, min: fieldAnchors.angleMin, max: fieldAnchors.angleMax),
                    color: angleColor,
                    trackColor: angleColor.darkenedTrack
                )
                .frame(maxWidth: .infinity)

                metricColumn(
                    value: run.maxSpeed,
                    format: "%.0f",
                    unit: "km/h",
                    normalised: normalise(value: run.maxSpeed, min: fieldAnchors.speedMin, max: fieldAnchors.speedMax),
                    color: speedColor,
                    trackColor: speedColor.darkenedTrack
                )
                .frame(maxWidth: .infinity)
            }

            // Trailing chevron
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppColors.textTertiary)
                .frame(width: 20)
        }
        .padding(.vertical, AppSpacing.lg)
        .padding(.horizontal, AppSpacing.cardPadding)
        .frame(minHeight: 76)
        .background(AppColors.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: AppSpacing.CornerRadius.card))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.CornerRadius.card)
                .strokeBorder(AppColors.cardBorder, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Time Column

    private var timeColumn: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            // Clock time — e.g. "9:41 AM"
            timeLabel

            // Relative time — "Just now" / "3 min ago" (M-UI6)
            Text(Self.relativeTimeText(from: run.startedAt))
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(AppColors.textSecondary)
                .lineLimit(1)

            // Badges — a run can be several superlatives at once (its single run
            // is the latest AND could be the longest, fastest and highest), so
            // render every one that applies, wrapping within the narrow column.
            if !activeBadges.isEmpty {
                badgeCluster
            }
        }
    }

    /// LATEST first (it is about the whole run), then the metric superlatives in
    /// the same left-to-right order as the metric columns: LONGEST (time),
    /// HIGHEST (angle), FASTEST (speed).
    private var activeBadges: [String] {
        var badges: [String] = []
        if isLatest { badges.append("LATEST") }
        if isLongest { badges.append("LONGEST") }
        if isHighest { badges.append("HIGHEST") }
        if isFastest { badges.append("FASTEST") }
        return badges
    }

    /// A 2-wide wrapping grid, so up to four pills stack in two compact rows
    /// inside the 96pt time column without pushing the card past its max height.
    private var badgeCluster: some View {
        let columns = [
            GridItem(.flexible(), spacing: AppSpacing.xxs, alignment: .leading),
            GridItem(.flexible(), spacing: AppSpacing.xxs, alignment: .leading)
        ]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: AppSpacing.xxs) {
            ForEach(activeBadges, id: \.self) { badgePill(text: $0) }
        }
    }

    private var timeLabel: some View {
        Text(run.startedAt.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)).minute()))
            .font(.system(size: 17, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(AppColors.textPrimary)
            .lineLimit(1)
    }

    private func badgePill(text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(AppColors.badgeText)
            .padding(.horizontal, AppSpacing.xs)
            .padding(.vertical, AppSpacing.xxs)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(AppColors.badgeFill)
            )
    }

    // MARK: - Metric Column

    private func metricColumn(value: Double, format: String, unit: String, normalised: Double, color: Color, trackColor: Color) -> some View {
        VStack(spacing: AppSpacing.xs) {
            // Value + unit
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(String(format: format, value))
                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(unit)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(color.opacity(0.7))
            }

            // Mini bar — inset within its column so adjacent bars never touch,
            // with the unfilled track drawn as a dark shade of the fill colour.
            // The whole bar (track + fill) spans ~3/4 of the column, leading-aligned,
            // so it reads shorter without changing where empty/filled meet.
            GeometryReader { geo in
                let barWidth = geo.size.width * 0.75
                ZStack(alignment: .leading) {
                    // Track — a darkened shade of the fill colour, not a blank grey.
                    Capsule()
                        .fill(trackColor)
                        .frame(width: barWidth, height: 4)

                    // Fill
                    Capsule()
                        .fill(color)
                        .frame(width: max(barWidth * normalised, 4), height: 4)
                }
            }
            .frame(height: 4)
            .padding(.horizontal, AppSpacing.xs)
        }
    }

    // MARK: - Normalisation

    private func normalise(value: Double, min: Double, max: Double) -> Double {
        guard max > min else { return 0.5 }
        return Swift.max(0, Swift.min(1, (value - min) / (max - min)))
    }

    // MARK: - Colors

    private var durationColor: Color {
        colorFromScale(
            value: run.duration,
            min: fieldAnchors.durationMin,
            max: fieldAnchors.durationMax
        )
    }

    private var angleColor: Color {
        colorFromScale(
            value: run.maxAngle,
            min: fieldAnchors.angleMin,
            max: fieldAnchors.angleMax
        )
    }

    private var speedColor: Color {
        colorFromScale(
            value: run.maxSpeed,
            min: fieldAnchors.speedMin,
            max: fieldAnchors.speedMax
        )
    }

    private func colorFromScale(value: Double, min: Double, max: Double) -> Color {
        let rgb = colorScale.color(value: value, fieldMinimum: min, fieldMaximum: max)
        let srgb = rgb.sRGB
        return Color(.sRGB, red: srgb.r, green: srgb.g, blue: srgb.b)
    }

    // MARK: - Relative time

    /// "Just now" for < 60s, else "N min ago" / "N hr ago"; falls back to a
    /// short date for older runs. Explicit `ago` suffix + `Just now` floor (M-UI6).
    static func relativeTimeText(from date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "Just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) hr ago" }
        let days = hours / 24
        if days < 7 { return "\(days) d ago" }
        return date.formatted(.dateTime.month().day())
    }

    // MARK: - Accessibility

    private var accessibilityDescription: String {
        let time = run.startedAt.formatted(date: .omitted, time: .shortened)
        let badges = activeBadges
        let badgeSuffix = badges.isEmpty ? "" : ", " + badges.map { $0.lowercased() }.joined(separator: ", ")
        return "\(time), \(String(format: "%.1f", run.duration)) seconds, \(String(format: "%.0f", run.maxAngle)) degrees, \(String(format: "%.0f", run.maxSpeed)) km/h\(badgeSuffix)"
    }
}
