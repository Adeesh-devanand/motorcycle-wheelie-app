import SwiftUI

/// §9 — Run Details: nav row, title, hero card, synced angle/speed charts,
/// insight strip, legend, and interval timeline.
struct RunDetailsView: View {
    @State private var viewModel: RunDetailsViewModel
    @Environment(\.dismiss) private var dismiss

    /// Whether this run genuinely holds the longest duration on record. Computed
    /// from the repository at init, never assumed: a badge that claims a record
    /// on every run is a false claim, and this project's whole premise is that
    /// every number it shows is one it can defend.
    private let isLongestRun: Bool

    init(runID: UUID, repository: RunRepository) {
        let allRuns = repository.allRuns
        let run = allRuns.first { $0.id == runID }
            ?? WheelieRun(id: runID, startedAt: .now, endedAt: .now, samples: [],
                          configuration: RunConfigurationSnapshot(
                            angleTarget: MetricRange(lower: 35, upper: 45),
                            speedTarget: MetricRange(lower: 35, upper: 50),
                            speedGaugeMaximum: 100,
                            calibrationID: UUID()))

        // A single run is not a record holder — with nothing to compare against
        // "LONGEST" would be vacuous rather than earned.
        if allRuns.count > 1, let longest = allRuns.max(by: { $0.duration < $1.duration }) {
            self.isLongestRun = longest.id == run.id
        } else {
            self.isLongestRun = false
        }

        _viewModel = State(wrappedValue: RunDetailsViewModel(run: run))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: AppSpacing.lg) {
                navRow
                titleSection
                heroCard
                chartsGroup
                insightStrip
                legendCaption
                intervalTimeline
            }
            .padding(.horizontal, AppSpacing.screenPadding)
            .padding(.bottom, AppSpacing.xxl)
        }
        .background(AppColors.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .preferredColorScheme(.dark)
    }

    // MARK: - Nav Row

    private var navRow: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "arrow.left")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(AppColors.textSecondary)
            }
            Spacer()
            // Removed: a share icon and a gear icon that were bare
            // `Image(systemName:)` views — not Buttons. They looked tappable but
            // did nothing and were invisible to VoiceOver. There was no real
            // export path in reach (the only one, ExportShareView, was itself
            // unreachable and has since been deleted) and no settings action on
            // the view model, so a control that lies is worse than no control.
            // Removed rather than faked. A working export does exist, on the real
            // file URL, in DiagnosticsView.
        }
        .padding(.top, AppSpacing.sm)
    }

    // MARK: - Title

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("RUN DETAILS")
                .font(.system(size: 36, weight: .black))
                .foregroundStyle(AppColors.textPrimary)

            HStack(spacing: AppSpacing.sm) {
                Text(subtitleText)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(AppColors.textSecondary)

                badgePill
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitleText: String {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        let dayPart = formatter.string(from: viewModel.run.startedAt)

        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "h:mm a"
        let timePart = timeFmt.string(from: viewModel.run.startedAt)

        return "\(dayPart) · \(timePart)"
    }

    @ViewBuilder
    private var badgePill: some View {
        if isLongestRun {
            Text("LONGEST")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppColors.badgeSuccessText)
                .padding(.horizontal, AppSpacing.sm)
                .padding(.vertical, AppSpacing.xxs + 1)
                .background(AppColors.badgeSuccessFill)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Hero Card

    private var heroCard: some View {
        TelemetryCard {
            HStack(spacing: 0) {
                heroMetric(
                    label: "WHEELIE TIME",
                    value: String(format: "%.1f", viewModel.duration),
                    unit: "s",
                    color: AppColors.success,
                    showBest: isLongestRun
                )
                .frame(maxWidth: .infinity)

                verticalDivider

                heroMetric(
                    label: "MAX ANGLE",
                    value: String(format: "%.0f°", viewModel.maxAngle),
                    unit: nil,
                    color: AppColors.angleMetric,
                    showBest: false
                )
                .frame(maxWidth: .infinity)

                verticalDivider

                heroMetric(
                    label: "MAX SPEED",
                    value: String(format: "%.0f", viewModel.maxSpeed),
                    unit: "km/h",
                    // Was `AppColors.angleMetric` (teal) — the angle channel's
                    // colour, so the speed hero was lying about which channel it
                    // was. Speed is blue throughout the app.
                    color: AppColors.speedMetric,
                    showBest: false
                )
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var verticalDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 1, height: 60)
    }

    private func heroMetric(label: String, value: String, unit: String?, color: Color, showBest: Bool) -> some View {
        VStack(spacing: AppSpacing.xs) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .tracking(0.5)
                .foregroundStyle(AppColors.accent)

            if let unit {
                HStack(alignment: .lastTextBaseline, spacing: 1) {
                    Text(value)
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .foregroundStyle(color)
                    Text(unit)
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                        .foregroundStyle(color)
                }
            } else {
                Text(value)
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .foregroundStyle(color)
            }

            if showBest {
                Text("PERSONAL BEST")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppColors.success)
            }
        }
    }

    // MARK: - Charts (§9.4)

    /// Both charts stacked, with ONE continuous scrubber line drawn across them
    /// as a single overlay (M-UI8). Each chart reports its plot rect + scrubber x
    /// via `ScrubberGeometryKey`; the overlay joins them into one line and floats
    /// the time bubble at the scrubber's x.
    private var chartsGroup: some View {
        VStack(spacing: AppSpacing.lg) {
            angleChart
            speedChart
        }
        .overlayPreferenceValue(ScrubberGeometryKey.self) { frames in
            GeometryReader { geo in
                sharedScrubberOverlay(frames: frames, container: geo)
            }
        }
    }

    @ViewBuilder
    private func sharedScrubberOverlay(frames: [ScrubberFrame], container: GeometryProxy) -> some View {
        // Convert the reported global plot rects into this container's local space.
        let origin = container.frame(in: .global).origin
        let angle = frames.first { $0.metric == .angle }
        let speed = frames.first { $0.metric == .speed }

        if viewModel.selectedTime != nil,
           let angle, let speed,
           let gx = angle.scrubberX ?? speed.scrubberX {
            let x = gx - origin.x
            let topY = angle.plotRect.minY - origin.y
            let bottomY = speed.plotRect.maxY - origin.y

            // One continuous vertical line from the top of the angle plot to the
            // bottom of the speed plot.
            Path { p in
                p.move(to: CGPoint(x: x, y: topY))
                p.addLine(to: CGPoint(x: x, y: bottomY))
            }
            .stroke(AppColors.textPrimary.opacity(0.85), lineWidth: 1)
            .allowsHitTesting(false)

            // Time bubble tracking the scrubber x, above the angle chart.
            if let time = viewModel.selectedTime {
                Text(String(format: "%.1fs", time))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppColors.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(hex: 0x1A1A20).opacity(0.95))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .fixedSize()
                    .position(x: x, y: max(topY - 14, 10))
                    .allowsHitTesting(false)
            }
        }
    }

    private var angleChart: some View {
        TelemetryCard {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text("ANGLE")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(AppColors.textPrimary)

                TelemetryChart(
                    points: viewModel.anglePoints,
                    rawSamples: viewModel.run.samples,
                    targetBand: viewModel.angleTarget,
                    metric: .angle,
                    yDomain: viewModel.angleDomain,
                    runDuration: viewModel.duration,
                    selectedTime: $viewModel.selectedTime
                )
            }
        }
    }

    private var speedChart: some View {
        TelemetryCard {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text("SPEED")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(AppColors.textPrimary)

                TelemetryChart(
                    points: viewModel.speedPoints,
                    rawSamples: viewModel.run.samples,
                    targetBand: viewModel.speedTarget,
                    metric: .speed,
                    yDomain: viewModel.speedDomain,
                    runDuration: viewModel.duration,
                    selectedTime: $viewModel.selectedTime
                )
            }
        }
    }

    // MARK: - Insight Strip (§9.5)	

    private var insightStrip: some View {
        TelemetryCard {
            HStack(spacing: 0) {
                insightItem(label: "ANGLE IN RANGE", value: String(format: "%.1fs", viewModel.totalAngleInRange))
                    .frame(maxWidth: .infinity)
                verticalDivider
                insightItem(label: "AVG SPEED", value: String(format: "%.0f km/h", viewModel.averageSpeed), color: AppColors.speedMetric)
                    .frame(maxWidth: .infinity)
                verticalDivider
                insightItem(label: "SPEED IN RANGE", value: String(format: "%.1fs", viewModel.totalSpeedInRange), color: AppColors.speedMetric)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// `color` defaults to the angle channel because two of the three insight rows
    /// are angle metrics. It exists because the helper previously hardcoded
    /// `AppColors.angleMetric` for ALL rows, so AVG SPEED and SPEED IN RANGE
    /// rendered teal — the angle channel's colour — on the same screen whose legend
    /// teaches teal = angle and blue = speed. A defaulted parameter fixes the two
    /// speed rows without restructuring the other call site.
    private func insightItem(label: String,
                             value: String,
                             color: Color = AppColors.angleMetric) -> some View {
        VStack(spacing: AppSpacing.xxs) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .tracking(0.5)
                .foregroundStyle(AppColors.textSecondary)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }

    // MARK: - Legend + Caption

    private var legendCaption: some View {
        VStack(spacing: AppSpacing.xs) {
            HStack(spacing: AppSpacing.lg) {
                HStack(spacing: AppSpacing.xs) {
                    Circle().fill(AppColors.angleMetric).frame(width: 8, height: 8)
                    Text("ANGLE")
                        .font(.system(size: 12, weight: .medium))
                        .tracking(0.5)
                        .foregroundStyle(AppColors.textSecondary)
                }
                HStack(spacing: AppSpacing.xs) {
                    Circle().fill(AppColors.speedMetric).frame(width: 8, height: 8)
                    Text("SPEED")
                        .font(.system(size: 12, weight: .medium))
                        .tracking(0.5)
                        .foregroundStyle(AppColors.textSecondary)
                }
            }
            Text("Tap a segment for details")
                .font(.system(size: 12))
                .foregroundStyle(AppColors.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Interval Timeline (§9.6)

    private var intervalTimeline: some View {
        RangeIntervalTimeline(
            angleIntervals: viewModel.run.angleIntervals,
            speedIntervals: viewModel.run.speedIntervals,
            duration: viewModel.duration,
            selectedTime: $viewModel.selectedTime,
            totalAngleInRange: viewModel.totalAngleInRange,
            totalSpeedInRange: viewModel.totalSpeedInRange
        )
    }
}
