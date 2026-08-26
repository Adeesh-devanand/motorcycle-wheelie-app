import Foundation

enum MetricKind: String, Codable, Sendable {
    case angle
    case speed
    case duration
}

struct RangeInterval: Identifiable, Codable, Sendable {
    let id: UUID
    let metric: MetricKind
    let start: TimeInterval
    let end: TimeInterval

    var duration: TimeInterval {
        end - start
    }
}
