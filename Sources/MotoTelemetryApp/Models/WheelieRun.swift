import Foundation

struct WheelieRun: Identifiable, Codable, Sendable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let samples: [TelemetrySample]
    let configuration: RunConfigurationSnapshot

    var duration: TimeInterval {
        endedAt.timeIntervalSince(startedAt)
    }

    var maxAngle: Double {
        samples.map(\.angleDegrees).max() ?? 0
    }

    var maxSpeed: Double {
        samples.map(\.speedKPH).max() ?? 0
    }

    var averageSpeed: Double {
        guard !samples.isEmpty else { return 0 }
        return samples.map(\.speedKPH).reduce(0, +) / Double(samples.count)
    }

    var angleIntervals: [RangeInterval] {
        samples.compactMap { _ in nil } // Placeholder — populated by IntervalDetector bridge
    }

    var speedIntervals: [RangeInterval] {
        samples.compactMap { _ in nil } // Placeholder — populated by IntervalDetector bridge
    }
}
