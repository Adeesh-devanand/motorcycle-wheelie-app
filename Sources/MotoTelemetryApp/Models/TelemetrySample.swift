import Foundation

/// A single display-unit, run-relative telemetry point for the UI layer.
/// Distinct from `MotoTelemetryCore.Sample` which is a raw tagged sensor reading.
struct TelemetrySample: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let elapsed: TimeInterval
    /// Live (raw) estimator pitch, degrees.
    let angleDegrees: Double
    /// Acausal-blur pitch, degrees. Nil until the blur runs on event commit, or on
    /// a run too short to blur (`QualityFlags.smoothingUnavailable`). Optional so
    /// runs recorded before this field existed still decode.
    var blurredAngleDegrees: Double?
    let speedKPH: Double
}
