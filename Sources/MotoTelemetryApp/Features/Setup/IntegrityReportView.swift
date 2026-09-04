import MotoTelemetryCore
import SwiftUI

/// Read-only integrity report: achieved rate, gaps, saturations, thermal,
/// GNSS quality, drops, battery. Low-confidence flag display.
struct IntegrityReportView: View {

    // Injected from the active session writer / quality monitor. There is no
    // default sample: this screen is titled "Data Integrity", so it must never
    // show numbers it did not measure. When no session has been recorded the
    // caller passes nil and we render an explicit empty state instead of
    // fabricating a plausible-looking report.
    //
    // Defaulted to nil so SettingsView (which we do not own and which currently
    // calls `IntegrityReportView()`) keeps compiling; that call resolves to the
    // honest "no data yet" state until a real report is threaded through.
    let report: IntegrityReport?

    init(report: IntegrityReport? = nil) {
        self.report = report
    }

    var body: some View {
        if let report {
            reportList(report)
        } else {
            emptyState
        }
    }

    // MARK: - Empty State

    // Absent measurements must LOOK absent. Shown when no session data has been
    // injected — never a stand-in with representative-looking numbers.
    private var emptyState: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 40))
                .foregroundStyle(AppColors.textSecondary)
            Text("No session data yet")
                .font(.headline)
                .foregroundStyle(AppColors.textPrimary)
            Text("Record a ride to see its integrity report here.")
                .font(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(AppSpacing.screenPadding)
        .background(AppColors.background)
        .navigationTitle("Data Integrity")
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Report List

    private func reportList(_ report: IntegrityReport) -> some View {
        List {
            if report.isLowConfidence {
                Section {
                    HStack(spacing: AppSpacing.sm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppColors.warning)
                        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                            Text("Low Confidence")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppColors.warning)
                            Text("One or more quality checks failed. Data from this session may be unreliable.")
                                .font(.caption)
                                .foregroundStyle(AppColors.textSecondary)
                        }
                    }
                }
            }

            Section("Sample Rate") {
                metricRow("Achieved Rate", value: "\(String(format: "%.1f", report.achievedRateHz)) Hz", status: report.rateStatus)
                metricRow("Nominal Rate", value: "\(Int(report.nominalRateHz)) Hz", status: .nominal)
                metricRow("Rate Ratio", value: String(format: "%.1f%%", report.rateRatio * 100), status: report.rateStatus)
            }

            Section("Data Quality") {
                metricRow("Gaps Detected", value: "\(report.gapCount)", status: report.gapCount > 0 ? .warning : .nominal)
                metricRow("Longest Gap", value: String(format: "%.0f ms", report.longestGapMs), status: report.longestGapMs > 50 ? .critical : .nominal)
                metricRow("Saturations", value: "\(report.saturationCount)", status: report.saturationCount > 0 ? .warning : .nominal)
                metricRow("Drops", value: "\(report.dropCount)", status: report.dropCount > 0 ? .critical : .nominal)
            }

            Section("Environment") {
                metricRow("Thermal State", value: report.thermalState, status: report.thermalStatus)
                metricRow("GNSS Accuracy", value: report.gnssAccuracy, status: report.gnssStatus)
                metricRow("Battery Level", value: "\(report.batteryPercent)%", status: report.batteryPercent < 20 ? .warning : .nominal)
            }

            Section("Flags") {
                if report.qualityFlags.isEmpty {
                    Text("No quality flags")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textSecondary)
                } else {
                    ForEach(report.flagDescriptions, id: \.self) { desc in
                        HStack(spacing: AppSpacing.sm) {
                            Circle().fill(AppColors.warning).frame(width: 6, height: 6)
                            Text(desc)
                                .font(.subheadline)
                                .foregroundStyle(AppColors.textPrimary)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppColors.background)
        .navigationTitle("Data Integrity")
        .preferredColorScheme(.dark)
    }

    // MARK: - Metric Row

    private func metricRow(_ label: String, value: String, status: MetricStatus) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
            Spacer()
            HStack(spacing: AppSpacing.xs) {
                Text(value)
                    .font(.system(.subheadline, design: .monospaced, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(AppColors.textPrimary)
                Circle()
                    .fill(status.color)
                    .frame(width: 8, height: 8)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value), \(status.accessibilityLabel)")
    }
}

// MARK: - Supporting Types

enum MetricStatus {
    case nominal, warning, critical

    var color: Color {
        switch self {
        case .nominal: AppColors.success
        case .warning: AppColors.warning
        case .critical: AppColors.danger
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .nominal: "OK"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }
}

struct IntegrityReport {
    var achievedRateHz: Double
    var nominalRateHz: Double
    var rateRatio: Double { achievedRateHz / nominalRateHz }
    var rateStatus: MetricStatus { rateRatio >= 0.95 ? .nominal : .warning }

    var gapCount: Int
    var longestGapMs: Double
    var saturationCount: Int
    var dropCount: Int

    var thermalState: String
    var thermalStatus: MetricStatus
    var gnssAccuracy: String
    var gnssStatus: MetricStatus
    var batteryPercent: Int

    var qualityFlags: QualityFlags
    var isLowConfidence: Bool { qualityFlags.contains(.lowConfidence) }

    var flagDescriptions: [String] {
        var descs: [String] = []
        if qualityFlags.contains(.saturatedInEvent) { descs.append("Saturated sample in event") }
        if qualityFlags.contains(.highVibration) { descs.append("High vibration detected") }
        if qualityFlags.contains(.aliasingSuspect) { descs.append("Aliasing suspect") }
        if qualityFlags.contains(.lowRate) { descs.append("Low sample rate") }
        if qualityFlags.contains(.gapExceeded) { descs.append("Gap exceeded tolerance") }
        if qualityFlags.contains(.recovered) { descs.append("Session recovered from interruption") }
        if qualityFlags.contains(.smoothingUnavailable) { descs.append("Backward smoothing unavailable") }
        if qualityFlags.contains(.estimatorDegraded) { descs.append("Estimator degraded to gyro-only") }
        if qualityFlags.contains(.lowConfidence) { descs.append("Low confidence — excluded from bests") }
        return descs
    }

    // Preview-only sample. NOT a live-data fallback: renamed from `placeholder`
    // so it can never again be mistaken for a measured report and defaulted into
    // the view. Referenced only by the #Preview below.
    static let previewSample = IntegrityReport(
        achievedRateHz: 98.2,
        nominalRateHz: 100,
        gapCount: 0,
        longestGapMs: 12,
        saturationCount: 0,
        dropCount: 0,
        thermalState: "Nominal",
        thermalStatus: .nominal,
        gnssAccuracy: "±3.2 m",
        gnssStatus: .nominal,
        batteryPercent: 72,
        qualityFlags: []
    )
}

// MARK: - Previews

#Preview("Populated") {
    NavigationStack {
        IntegrityReportView(report: .previewSample)
    }
}

#Preview("No session data") {
    NavigationStack {
        IntegrityReportView()
    }
}
