import SwiftUI

/// §9 — Run Details: summary card, synced angle/speed charts, insight strip,
/// interval timeline, and share/export.
struct RunDetailsView: View {
    @State private var viewModel: RunDetailsViewModel

    init(runID: UUID, repository: RunRepository) {
        let run = repository.allRuns.first { $0.id == runID }
            ?? WheelieRun(id: runID, startedAt: .now, endedAt: .now, samples: [],
                          configuration: RunConfigurationSnapshot(
                            angleTarget: MetricRange(lower: 35, upper: 45),
                            speedTarget: MetricRange(lower: 35, upper: 50),
                            speedGaugeMaximum: 100,
                            calibrationID: UUID()))
        _viewModel = State(wrappedValue: RunDetailsViewModel(run: run))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: AppSpacing.lg) {
                summaryCard
                angleChart
                speedChart
                insightStrip
                intervalTimeline
            }
            .padding(.horizontal, AppSpacing.screenPadding)
            .padding(.bottom, AppSpacing.xxl)
        }
        .background(AppColors.background.ignoresSafeArea())
        .navigationTitle("RUN DETAILS")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: exportText, subject: Text("Wheelie Run")) {
                    Image(systemName: "square.and.arrow.up")
                        .accessibilityLabel("Share")
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Summary Card (§9.3)

    private var summaryCard: some View {
        TelemetryCard {
            HStack(spacing: 0) {
                heroMetric(
                    label: "WHEELIE TIME",
                    value: String(format: "%.1fs", viewModel.duration),
                    color: AppColors.textPrimary
                )
                Spacer()
                heroMetric(
                    label: "MAX ANGLE",
                    value: String(format: "%.0f°", viewModel.maxAngle),
                    color: Color(hex: 0x10B9B7)
                )
                Spacer()
                heroMetric(
                    label: "MAX SPEED",
                    value: String(format: "%.0f km/h", viewModel.maxSpeed),
                    color: Color(hex: 0x238CD8)
                )
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func heroMetric(label: String, value: String, color: Color) -> some View {
        VStack(spacing: AppSpacing.xs) {
            Text(label)
                .font(.system(.caption2, weight: .medium))
                .foregroundStyle(AppColors.textSecondary)
            Text(value)
                .font(.system(.title2, design: .monospaced, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }

    // MARK: - Charts (§9.4)

    private var angleChart: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("ANGLE")
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(AppColors.textSecondary)

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

    private var speedChart: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("SPEED")
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(AppColors.textSecondary)

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

    // MARK: - Insight Strip (§9.5)

    private var insightStrip: some View {
        TelemetryCard {
            HStack(spacing: 0) {
                insightItem(label: "ANGLE IN RANGE", value: String(format: "%.1fs", viewModel.totalAngleInRange))
                Spacer()
                insightItem(label: "AVG SPEED", value: String(format: "%.0f km/h", viewModel.averageSpeed))
                Spacer()
                insightItem(label: "SPEED IN RANGE", value: String(format: "%.1fs", viewModel.totalSpeedInRange))
            }
        }
    }

    private func insightItem(label: String, value: String) -> some View {
        VStack(spacing: AppSpacing.xxs) {
            Text(label)
                .font(.system(.caption2, weight: .medium))
                .foregroundStyle(AppColors.textSecondary)
            Text(value)
                .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(AppColors.textPrimary)
        }
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

    // MARK: - Export

    private var exportText: String {
        """
        Wheelie Run — \(viewModel.run.startedAt.formatted())
        Duration: \(String(format: "%.1f", viewModel.duration))s
        Max Angle: \(String(format: "%.1f", viewModel.maxAngle))°
        Max Speed: \(String(format: "%.1f", viewModel.maxSpeed)) km/h
        Avg Speed: \(String(format: "%.1f", viewModel.averageSpeed)) km/h
        Angle In Range: \(String(format: "%.1f", viewModel.totalAngleInRange))s
        Speed In Range: \(String(format: "%.1f", viewModel.totalSpeedInRange))s
        """
    }
}
