import SwiftUI

// MARK: - Session Summary Model

/// A one-glance verdict distilled from a whole session file — the thing a tester
/// can screenshot and send. Built by a PURE parser over already-decoded lines, so
/// it is unit-testable and has no dependency on the log writer.
struct SessionSummary: Equatable {

    struct MessageCount: Identifiable, Equatable {
        let message: String
        let level: LogLine.Level
        let count: Int
        var id: String { "\(level.rawValue):\(message)" }
    }

    var fileName: String

    // Level tallies.
    var counts: [LogLine.Level: Int]

    // Header values (strings pulled from the first line, if present).
    var device: String?
    var iosVersion: String?
    var appBuild: String?
    var thermalState: String?
    var configVersion: String?

    // Derived signals.
    var sensorHz: Double?
    var streamDeathCount: Int
    var calibrationOutcome: String?
    var calibrationAttempts: Int
    var worstGyroSigma: Double?
    var gyroSigmaLimit: Double?

    var topMessages: [MessageCount]

    var skippedLines: Int

    static let empty = SessionSummary(
        fileName: "", counts: [:], device: nil, iosVersion: nil, appBuild: nil,
        thermalState: nil, configVersion: nil, sensorHz: nil, streamDeathCount: 0,
        calibrationOutcome: nil, calibrationAttempts: 0, worstGyroSigma: nil,
        gyroSigmaLimit: nil, topMessages: [], skippedLines: 0
    )

    func count(_ level: LogLine.Level) -> Int { counts[level] ?? 0 }
    var totalEvents: Int { counts.values.reduce(0, +) }
}

// MARK: - Parser (pure, off-main)

enum SessionSummaryParser {

    /// Build a summary from a defensively-parsed tail/all-lines result.
    ///
    /// String keys used below are the STABLE, greppable messages/categories the
    /// contract commits to (`cat` values include "sensor","cal","caltrack",
    /// "gate"; messages are "short + STABLE"). We match tolerantly (case- and
    /// substring-based) so a small wording change does not blank the card, and we
    /// never assume a value is present — every field is optional.
    static func parse(fileName: String, lines: [LogLine], skipped: Int) -> SessionSummary {
        var s = SessionSummary.empty
        s.fileName = fileName
        s.skippedLines = skipped

        var counts: [LogLine.Level: Int] = [:]
        var messageTally: [String: (level: LogLine.Level, count: Int)] = [:]
        var calAttempts = 0
        var lastCalOutcome: String?
        var worstSigma: Double?
        var sigmaLimit: Double?
        var streamDeaths = 0
        var hz: Double?

        for line in lines {
            if line.isHeader {
                s.device = str(line.raw, "device", "deviceModel", "model")
                s.iosVersion = str(line.raw, "os", "ios", "iosVersion", "osVersion")
                s.appBuild = str(line.raw, "appBuild", "build", "appVersion", "version")
                s.thermalState = str(line.raw, "thermalState", "thermal")
                s.configVersion = str(line.raw, "configVersion")
                    ?? nestedConfigVersion(line.raw)
                continue
            }

            counts[line.level, default: 0] += 1

            let msg = line.message.lowercased()
            let cat = line.category.lowercased()

            // Frequency tally of warn/error messages only.
            if line.level == .warn || line.level == .error {
                let key = line.message
                let prev = messageTally[key]
                messageTally[key] = (line.level, (prev?.count ?? 0) + 1)
            }

            // Stream-death events. Keyed on an explicit numeric flag, NOT on message
            // prose: the writer emits "stopped (stream NOT finished — still live)" when
            // the stream SURVIVES, which any substring match on "stream"+"stopped"
            // scores as a death — inverting the one signal this card exists to report.
            if line.values["streamEnded"] == 1 {
                streamDeaths += 1
            }

            // Sensor rate — take the first observed Hz value we see.
            if cat == "sensor", hz == nil {
                hz = line.values["hz"] ?? line.values["rate"] ?? line.values["sampleHz"]
            }

            // Calibration: count attempts and remember the last outcome.
            if cat == "cal" || cat == "caltrack" {
                if msg.contains("start") || msg.contains("begin") || msg.contains("attempt") {
                    calAttempts += 1
                }
                if msg.contains("calibrated") || msg.contains("success") || msg.contains("complete") {
                    lastCalOutcome = "Calibrated"
                } else if msg.contains("fail") || msg.contains("timeout") || msg.contains("abort") {
                    lastCalOutcome = line.message
                }
            }

            // Worst gyro sigma against its limit — the value AND the threshold it
            // was compared against live together in `v` (contract).
            // Worst gyro sigma against its limit. Three writers emit this in three
            // shapes, and the CORE category is "bias" — not "cal" — so an over-tight
            // category guard silently drops the lines carrying the real numbers:
            //   core finish  -> semX/semY/semZ  + biasSigmaLimit  (deg/s, per axis)
            //   core failure -> sigmaDegPerSec  + limitDegPerSec  (deg/s)
            //   app echo     -> sigmaDeg                          (deg/s, worstSigma)
            // Only deg/s limit keys are accepted. A bare `limit` is NOT usable here:
            // on a `bias failed vibrationTooHigh` line it is 0.1 m/s^2, which would
            // render as a plausible-looking but meaningless "0.1 deg/s".
            if cat == "bias" || cat == "cal" || cat == "caltrack" {
                let perAxisSem = [line.values["semX"],
                                  line.values["semY"],
                                  line.values["semZ"]].compactMap { $0 }.max()
                let candidate = line.values["sigmaDegPerSec"]
                    ?? line.values["sigmaDeg"]
                    ?? perAxisSem
                    ?? line.values["sigma"]
                if let sigma = candidate, sigma > (worstSigma ?? -Double.infinity) {
                    worstSigma = sigma
                    sigmaLimit = line.values["limitDegPerSec"]
                        ?? line.values["biasSigmaLimit"]
                        ?? sigmaLimit
                }
            }
        }

        s.counts = counts
        s.calibrationAttempts = calAttempts
        s.calibrationOutcome = lastCalOutcome
        s.worstGyroSigma = worstSigma
        s.gyroSigmaLimit = sigmaLimit
        s.streamDeathCount = streamDeaths
        s.sensorHz = hz

        s.topMessages = messageTally
            .map { SessionSummary.MessageCount(message: $0.key, level: $0.value.level, count: $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.message < $1.message }
            .prefix(5)
            .map { $0 }

        return s
    }

    // MARK: helpers

    private static func str(_ dict: [String: Any], _ keys: String...) -> String? {
        for k in keys {
            if let v = dict[k] as? String, !v.isEmpty { return v }
            if let n = dict[k] as? NSNumber { return n.stringValue }
        }
        return nil
    }

    private static func nestedConfigVersion(_ dict: [String: Any]) -> String? {
        guard let config = dict["config"] as? [String: Any] else { return nil }
        if let v = config["version"] as? NSNumber { return v.stringValue }
        if let v = config["version"] as? String { return v }
        return nil
    }
}

// MARK: - Card

/// Placed at the TOP of DiagnosticsView for the newest session. Compact enough to
/// screenshot whole.
struct SessionSummaryCard: View {
    let summary: SessionSummary

    var body: some View {
        TelemetryCard(title: "Latest Session") {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                levelRow
                Divider().overlay(AppColors.cardBorder)
                headerGrid
                if !derived.isEmpty {
                    Divider().overlay(AppColors.cardBorder)
                    derivedGrid
                }
                if !summary.topMessages.isEmpty {
                    Divider().overlay(AppColors.cardBorder)
                    topMessagesSection
                }
                if summary.skippedLines > 0 {
                    Text("\(summary.skippedLines) unparseable line\(summary.skippedLines == 1 ? "" : "s") skipped")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColors.textTertiary)
                }
            }
        }
    }

    // MARK: level tallies

    private var levelRow: some View {
        HStack(spacing: AppSpacing.sm) {
            levelChip(.error, AppColors.danger)
            levelChip(.warn, AppColors.warning)
            levelChip(.info, AppColors.textSecondary)
            levelChip(.debug, AppColors.textTertiary)
            Spacer()
            Text("\(summary.totalEvents) events")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(AppColors.textSecondary)
        }
    }

    private func levelChip(_ level: LogLine.Level, _ color: Color) -> some View {
        HStack(spacing: AppSpacing.xs) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(summary.count(level))")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(AppColors.textPrimary)
            Text(level.rawValue.uppercased())
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(AppColors.textTertiary)
        }
    }

    // MARK: header grid

    private var headerGrid: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            kv("Device", summary.device)
            kv("iOS", summary.iosVersion)
            kv("Build", summary.appBuild)
            kv("Thermal", summary.thermalState)
            kv("Config", summary.configVersion)
        }
    }

    // MARK: derived signals

    private var derived: [(String, String, Color)] {
        var rows: [(String, String, Color)] = []
        if let hz = summary.sensorHz {
            rows.append(("Sensor rate", "\(LogLine.trim(hz)) Hz", AppColors.textPrimary))
        }
        rows.append((
            "Stream deaths",
            "\(summary.streamDeathCount)",
            summary.streamDeathCount > 0 ? AppColors.danger : AppColors.textPrimary
        ))
        if let outcome = summary.calibrationOutcome {
            let ok = outcome.lowercased().contains("calibrat")
            let attempts = summary.calibrationAttempts > 0 ? " · \(summary.calibrationAttempts) attempt\(summary.calibrationAttempts == 1 ? "" : "s")" : ""
            rows.append(("Calibration", outcome + attempts, ok ? AppColors.success : AppColors.warning))
        } else if summary.calibrationAttempts > 0 {
            rows.append(("Calibration", "\(summary.calibrationAttempts) attempt\(summary.calibrationAttempts == 1 ? "" : "s"), no outcome", AppColors.warning))
        }
        if let sigma = summary.worstGyroSigma {
            let limitText = summary.gyroSigmaLimit.map { " / \(LogLine.trim($0))" } ?? ""
            let over = (summary.gyroSigmaLimit.map { sigma > $0 }) ?? false
            rows.append(("Worst gyro σ", "\(LogLine.trim(sigma))\(limitText)", over ? AppColors.danger : AppColors.textPrimary))
        }
        return rows
    }

    private var derivedGrid: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            ForEach(derived, id: \.0) { row in
                HStack {
                    Text(row.0)
                        .font(.system(size: 12))
                        .foregroundStyle(AppColors.textSecondary)
                    Spacer()
                    Text(row.1)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(row.2)
                }
            }
        }
    }

    // MARK: top messages

    private var topMessagesSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("Top warnings & errors")
                .sectionHeaderStyle()
            ForEach(summary.topMessages) { m in
                HStack(alignment: .top, spacing: AppSpacing.sm) {
                    Text("\(m.count)×")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(m.level == .error ? AppColors.danger : AppColors.warning)
                        .frame(minWidth: 34, alignment: .trailing)
                    Text(m.message)
                        .font(.system(size: 12))
                        .foregroundStyle(AppColors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: kv helper

    @ViewBuilder
    private func kv(_ key: String, _ value: String?) -> some View {
        HStack {
            Text(key)
                .font(.system(size: 12))
                .foregroundStyle(AppColors.textSecondary)
            Spacer()
            Text(value ?? "—")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(value == nil ? AppColors.textTertiary : AppColors.textPrimary)
        }
    }
}
