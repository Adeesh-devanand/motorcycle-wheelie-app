import Foundation

// MARK: - Telemetry Export

/// Exports telemetry data as CSV or JSON from core SI units.
///
/// The CSV header is fixed by ui-spec §9.7:
///   elapsed_seconds,angle_degrees,speed_kph
///
/// Core stores angle in radians and speed in m/s. Conversion happens here at the
/// boundary so the core never deals with display units and the export never
/// depends on locale-specific formatting.
///
/// Speed is OPTIONAL: a nil speed renders as an empty CSV field, never as 0.
/// The ui-spec is explicit that unavailable speed must never appear as zero — a
/// fabricated 0 is indistinguishable from a real stop and would mislead analysis.
public struct TelemetryExport {

    /// A single telemetry point in core SI units.
    public struct DataPoint: Sendable, Codable, Equatable {
        /// Elapsed time from run start, in seconds.
        public let elapsedSeconds: Double
        /// Lean/pitch angle in radians.
        public let angleRadians: Double
        /// Speed in m/s, or nil if GNSS was unavailable.
        public let speedMetersPerSecond: Double?

        public init(elapsedSeconds: Double, angleRadians: Double, speedMetersPerSecond: Double?) {
            self.elapsedSeconds = elapsedSeconds
            self.angleRadians = angleRadians
            self.speedMetersPerSecond = speedMetersPerSecond
        }
    }

    // MARK: - CSV Export

    /// The exact CSV header mandated by ui-spec §9.7.
    public static let csvHeader = "elapsed_seconds,angle_degrees,speed_kph"

    /// Export data points as a CSV string.
    ///
    /// Numbers are formatted locale-independently using a decimal POINT. A European
    /// locale's decimal comma would corrupt the CSV (commas are the delimiter), so
    /// we format manually rather than relying on String interpolation of Double,
    /// which is locale-independent in Swift but we make this explicit and testable.
    ///
    /// Missing speed renders as an empty field between commas — never "0" or "0.0".
    public static func exportCSV(points: [DataPoint]) -> String {
        var lines: [String] = []
        lines.reserveCapacity(points.count + 1)
        lines.append(csvHeader)

        for point in points {
            let elapsed = formatDouble(point.elapsedSeconds)
            let angle = formatDouble(point.angleRadians * (180.0 / .pi))
            let speed: String
            if let mps = point.speedMetersPerSecond {
                speed = formatDouble(mps * 3.6)  // m/s -> km/h
            } else {
                speed = ""  // empty field, NOT "0"
            }
            lines.append("\(elapsed),\(angle),\(speed)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - JSON Export

    /// A JSON-friendly representation with display units and explicit null for missing speed.
    public struct JSONRecord: Codable, Sendable, Equatable {
        public let elapsed_seconds: Double
        public let angle_degrees: Double
        public let speed_kph: Double?

        enum CodingKeys: String, CodingKey {
            case elapsed_seconds
            case angle_degrees
            case speed_kph
        }

        // Explicit encode so nil speed_kph appears as JSON null rather than being
        // omitted entirely. An absent key and a null key mean different things in
        // telemetry: absent = "field not in schema", null = "value unavailable at
        // this sample". We need the latter.
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(elapsed_seconds, forKey: .elapsed_seconds)
            try container.encode(angle_degrees, forKey: .angle_degrees)
            // encodeNil writes JSON null; encode(optional) would skip the key.
            if let speed = speed_kph {
                try container.encode(speed, forKey: .speed_kph)
            } else {
                try container.encodeNil(forKey: .speed_kph)
            }
        }
    }

    /// Export data points as a JSON string (array of objects).
    ///
    /// Uses JSONEncoder with sortedKeys for deterministic output.
    /// Missing speed is encoded as JSON null.
    public static func exportJSON(points: [DataPoint]) -> String {
        let records = points.map { point in
            JSONRecord(
                elapsed_seconds: point.elapsedSeconds,
                angle_degrees: point.angleRadians * (180.0 / .pi),
                speed_kph: point.speedMetersPerSecond.map { $0 * 3.6 }
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // JSONEncoder in Foundation always uses '.' for decimals regardless of locale.
        guard let data = try? encoder.encode(records),
              let str = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return str
    }

    // MARK: - Number Formatting

    /// Format a Double locale-independently with a decimal point.
    ///
    /// Swift's `"\(double)"` is locale-independent (unlike C's printf with setlocale),
    /// but we make this an explicit function so (a) we can test it directly, and
    /// (b) if this code ever runs through a bridged NSString path it won't pick up
    /// the process locale.
    ///
    /// Precision: up to 6 decimal places, trailing zeros stripped.
    internal static func formatDouble(_ value: Double) -> String {
        // Use a fixed decimal-point representation. Swift's default interpolation
        // uses the shortest round-trippable representation which is fine for CSV
        // (always uses '.'), but we want a reasonable number of decimals for
        // human readability while remaining exact enough for round-trip.
        let s = String(format: "%.6f", value)
        // Strip trailing zeros after the decimal point, but keep at least one
        // digit after the dot (e.g. "42.0" not "42.").
        guard let dotIndex = s.firstIndex(of: ".") else { return s }
        let minEnd = s.index(dotIndex, offsetBy: 2)  // at least ".X"
        var end = s.endIndex
        while end > minEnd && s[s.index(before: end)] == "0" {
            end = s.index(before: end)
        }
        return String(s[s.startIndex..<end])
    }
}
