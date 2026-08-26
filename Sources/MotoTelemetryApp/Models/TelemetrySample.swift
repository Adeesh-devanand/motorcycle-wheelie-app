import Foundation

/// A single display-unit, run-relative telemetry point for the UI layer.
/// Distinct from `MotoTelemetryCore.Sample` which is a raw tagged sensor reading.
struct TelemetrySample: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let elapsed: TimeInterval
    let angleDegrees: Double
    let speedKPH: Double
}
