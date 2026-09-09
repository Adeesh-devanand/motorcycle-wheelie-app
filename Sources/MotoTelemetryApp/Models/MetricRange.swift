import Foundation

/// How the live meters divide their scales — shared, because the angle meter, the speed
/// meter and the set of selectable speed ceilings all have to agree or the two axes stop
/// matching.
///
/// It lives here rather than on `VerticalTelemetryMeter` so `RiderPreferences` can derive
/// its ceiling ladder from it without a model depending on a view. That derivation is the
/// point: the constraint "a ceiling must divide into whole multiples of 5" was previously
/// only stated in prose, and prose does not survive someone changing `divisions`.
enum MeterScale {
    /// Equal intervals per scale, so `divisions + 1` labelled major spokes. Six puts the
    /// 0-90 degree angle axis on 15 degree steps.
    static let divisions = 6

    /// The coarsest unit any axis label should land on.
    static let labelGranularity: Double = 5

    /// Spacing of the selectable speed ceilings, and the smallest one: the product of the
    /// two above, which is exactly what makes `ceiling / divisions` a whole multiple of
    /// `labelGranularity` for every ceiling on the ladder.
    static var ceilingStep: Double { Double(divisions) * labelGranularity }
}

struct MetricRange: Codable, Equatable, Sendable {
    let lower: Double
    let upper: Double
}

struct RunConfigurationSnapshot: Codable, Sendable, Equatable {
    let angleTarget: MetricRange
    let speedTarget: MetricRange
    let speedGaugeMaximum: Double
    let calibrationID: UUID
}
