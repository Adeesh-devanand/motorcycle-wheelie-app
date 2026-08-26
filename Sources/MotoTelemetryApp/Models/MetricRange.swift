import Foundation

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
