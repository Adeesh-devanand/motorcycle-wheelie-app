import Foundation
import MotoTelemetryCore

struct WheelieRun: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let samples: [TelemetrySample]
    let configuration: RunConfigurationSnapshot
    /// Quality flags for the run — carries `smoothingUnavailable` when the blur
    /// could not run, so a raw-only run is never shown as if it were cleaned.
    var qualityFlags: QualityFlags = []

    var duration: TimeInterval {
        endedAt.timeIntervalSince(startedAt)
    }

    /// The leaderboard number: max over the BLURRED series, falling back to raw for
    /// any sample the blur did not produce. Blurring pulls a lone vibration spike
    /// back toward its neighbours, so this is a less inflated peak than raw max — it
    /// does not fix the ratchet asymmetry (that is the parked percentile upgrade),
    /// only the worst of the spike inflation.
    var maxAngle: Double {
        samples.map { $0.blurredAngleDegrees ?? $0.angleDegrees }.max() ?? 0
    }

    /// The raw max, kept beside `maxAngle` so the blur's effect is visible rather
    /// than hidden — the same honesty rule as storing both series.
    var rawMaxAngle: Double {
        samples.map(\.angleDegrees).max() ?? 0
    }

    var maxSpeed: Double {
        samples.map(\.speedKPH).max() ?? 0
    }

    var averageSpeed: Double {
        guard !samples.isEmpty else { return 0 }
        return samples.map(\.speedKPH).reduce(0, +) / Double(samples.count)
    }

    // MARK: - In-range intervals (IntervalDetector bridge)
    //
    // Was `samples.compactMap { _ in nil }` — a permanent [] that made RunDetails
    // read "ANGLE IN RANGE 0.0s" for every run. The core detector was complete and
    // tested the whole time; only this bridge was missing. Ranges come from the
    // run's OWN stored `TargetSnapshot`, not current preferences, so a historical
    // run's intervals never shift when the rider later edits their target.

    var angleIntervals: [RangeInterval] {
        let lo = configuration.angleTarget.lower * .pi / 180
        let hi = configuration.angleTarget.upper * .pi / 180
        guard hi > lo else { return [] }
        let series = samples.map { (time: $0.elapsed,
                                    value: ($0.blurredAngleDegrees ?? $0.angleDegrees) * .pi / 180) }
        return IntervalDetector(range: lo...hi, minDuration: 0.15, mergeGap: 0.10)
            .intervals(over: series)
            .map { RangeInterval(start: $0.start, end: $0.end) }
    }

    var speedIntervals: [RangeInterval] {
        let lo = configuration.speedTarget.lower / 3.6   // km/h -> m/s
        let hi = configuration.speedTarget.upper / 3.6
        guard hi > lo else { return [] }
        let series = samples.map { (time: $0.elapsed, value: $0.speedKPH / 3.6) }
        return IntervalDetector(range: lo...hi, minDuration: 0.15, mergeGap: 0.10)
            .intervals(over: series)
            .map { RangeInterval(start: $0.start, end: $0.end) }
    }
}
