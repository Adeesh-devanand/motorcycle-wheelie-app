import MotoTelemetryCore
import SwiftUI

/// §8.3 — Compact TelemetryCard row showing date, duration, max angle, event count.
/// Color chips use RelativeMetricColorScale for per-field normalisation.
struct RunHistoryRow: View {
    let run: WheelieRun
    let colorScale: RelativeMetricColorScale
    let fieldAnchors: PastRunsViewModel.FieldAnchors

    var body: some View {
        TelemetryCard {
            HStack(spacing: AppSpacing.md) {
                // Timestamp column
                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    Text(run.startedAt, style: .time)
                        .font(.system(.subheadline, design: .default, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(AppColors.textPrimary)

                    Text(run.startedAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(AppColors.textSecondary)
                }
                .frame(minWidth: 60, alignment: .leading)

                Spacer()

                // Metrics
                HStack(spacing: AppSpacing.lg) {
                    metricCell(
                        value: String(format: "%.1fs", run.duration),
                        color: durationColor,
                        accessibilityValue: "\(String(format: "%.1f", run.duration)) seconds"
                    )

                    metricCell(
                        value: String(format: "%.0f°", run.maxAngle),
                        color: angleColor,
                        accessibilityValue: "\(String(format: "%.0f", run.maxAngle)) degrees"
                    )

                    metricCell(
                        value: String(format: "%.0f", run.maxSpeed),
                        color: speedColor,
                        accessibilityValue: "\(String(format: "%.0f", run.maxSpeed)) km/h"
                    )
                }

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Metric Cell

    private func metricCell(value: String, color: Color, accessibilityValue: String) -> some View {
        VStack(spacing: AppSpacing.xxs) {
            Text(value)
                .font(.system(.body, design: .monospaced, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(color)

            // Tiny colour intensity bar
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 28, height: 3)
        }
        .accessibilityValue(accessibilityValue)
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

    // MARK: - Accessibility

    private var accessibilityDescription: String {
        let time = run.startedAt.formatted(date: .omitted, time: .shortened)
        let best = isBestForAnyField ? ", personal best" : ""
        return "\(time), \(String(format: "%.1f", run.duration)) seconds, \(String(format: "%.0f", run.maxAngle)) degrees, \(String(format: "%.0f", run.maxSpeed)) km/h\(best)"
    }

    private var isBestForAnyField: Bool {
        run.duration >= fieldAnchors.durationMax ||
        run.maxAngle >= fieldAnchors.angleMax ||
        run.maxSpeed >= fieldAnchors.speedMax
    }
}
