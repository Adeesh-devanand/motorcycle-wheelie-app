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

    private struct Statistics: Sendable, Equatable {
        var angle: Double = 0
        var rawAngle: Double = 0
        var speed: Double = 0
        var averageSpeed: Double = 0
    }
    private var statistics = Statistics()

    private static func summarize(_ samples: [TelemetrySample]) -> Statistics {
        var result = Statistics()
        var total: Double = 0
        var validCount = 0
        if let first = samples.first {
            result.angle = first.blurredAngleDegrees ?? first.angleDegrees
            result.rawAngle = first.angleDegrees
        }
        for sample in samples {
            result.angle = max(result.angle, sample.blurredAngleDegrees ?? sample.angleDegrees)
            result.rawAngle = max(result.rawAngle, sample.angleDegrees)
            if sample.speedValid == true {
                result.speed = max(result.speed, sample.speedKPH)
                total += sample.speedKPH
                validCount += 1
            }
        }
        result.averageSpeed = validCount == 0 ? 0 : total / Double(validCount)
        return result
    }

    // MARK: - Decoding older files
    //
    // 27 runs on the device were being dropped every launch as "corrupt run file".
    // They are not corrupt. `qualityFlags` was added to this struct in the
    // calibrate-once beta (6667875), and Swift's SYNTHESIZED `Codable` does NOT fall
    // back to a stored property's default value when the key is absent — it calls
    // `decode(_:forKey:)` and throws `keyNotFound`. Verified directly rather than
    // assumed: an old-schema payload against a synthesized decoder throws
    // `keyNotFound(CodingKeys(stringValue: "flags"))`, while the same payload against
    // a `decodeIfPresent` decoder succeeds.
    //
    // So one additive field with a default silently orphaned every run recorded before
    // it. `speedGaugeMaximum` was the earlier suspicion and is NOT the cause; it has
    // been present since the first app commit (78f4a98). `qualityFlags` is the only
    // stored key added since.
    //
    // Every field below except `qualityFlags` uses plain `decode`, deliberately: those
    // five ARE the run, and a file missing one of them is genuinely unreadable. Only
    // the additive field is tolerated, so this stays a compatibility shim rather than
    // a decoder that accepts anything.

    enum CodingKeys: String, CodingKey {
        case id, startedAt, endedAt, samples, configuration, qualityFlags
    }

    init(id: UUID,
         startedAt: Date,
         endedAt: Date,
         samples: [TelemetrySample],
         configuration: RunConfigurationSnapshot,
         qualityFlags: QualityFlags = []) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.samples = samples
        self.statistics = Self.summarize(samples)
        self.configuration = configuration
        self.qualityFlags = qualityFlags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decode(Date.self, forKey: .endedAt)
        samples = try container.decode([TelemetrySample].self, forKey: .samples)
        statistics = Self.summarize(samples)
        configuration = try container.decode(RunConfigurationSnapshot.self,
                                             forKey: .configuration)

        if let stored = try container.decodeIfPresent(QualityFlags.self, forKey: .qualityFlags) {
            qualityFlags = stored
        } else {
            // No quality record in the file. `[]` would claim a clean run, which this
            // file never said — so record the gap itself, and add the one flag that IS
            // derivable from the data present: if not a single sample carries a blurred
            // angle then the backward pass demonstrably never ran on this run.
            var derived: QualityFlags = .qualityRecordMissing
            if samples.allSatisfy({ $0.blurredAngleDegrees == nil }) {
                derived.insert(.smoothingUnavailable)
            }
            qualityFlags = derived
        }
    }

    var duration: TimeInterval {
        endedAt.timeIntervalSince(startedAt)
    }

    /// The leaderboard number: max over the BLURRED series, falling back to raw for
    /// any sample the blur did not produce. Blurring pulls a lone vibration spike
    /// back toward its neighbours, so this is a less inflated peak than raw max — it
    /// does not fix the ratchet asymmetry (that is the parked percentile upgrade),
    /// only the worst of the spike inflation.
    var maxAngle: Double { statistics.angle }
    var rawMaxAngle: Double { statistics.rawAngle }
    var maxSpeed: Double { statistics.speed }
    var averageSpeed: Double { statistics.averageSpeed }

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
        // Was `RangeInterval(start:end:)` — an initializer that does not exist,
        // a hard build break. `RangeInterval` synthesizes only
        // `init(id:metric:start:end:)`, and the detector returns a different
        // type (`IntervalDetector.Interval`), so no overload rescued the two-arg
        // call. Supply all four; `metric: .angle` is load-bearing —
        // `RangeIntervalTimeline` colours the angle vs speed channel off it, so
        // a wrong metric would mis-colour the timeline.
        return IntervalDetector(range: lo...hi, minDuration: 0.15, mergeGap: 0.10, maximumInterpolationGap: 0.25)
            .intervals(over: series)
            .enumerated().map { index, interval in
                RangeInterval(id: intervalID(index: index, speed: false), metric: .angle, start: interval.start, end: interval.end)
            }
    }

    var speedIntervals: [RangeInterval] {
        let lo = configuration.speedTarget.lower / 3.6   // km/h -> m/s
        let hi = configuration.speedTarget.upper / 3.6
        guard hi > lo else { return [] }
        let series = samples.map { (time: $0.elapsed, value: $0.speedValid == true ? $0.speedKPH / 3.6 : .nan) }
        // Same nonexistent `RangeInterval(start:end:)` build break as above;
        // here `metric: .speed` distinguishes this from the angle channel so
        // `RangeIntervalTimeline` colours it correctly.
        return IntervalDetector(range: lo...hi, minDuration: 0.15, mergeGap: 0.10, maximumInterpolationGap: 0.25)
            .intervals(over: series)
            .enumerated().map { index, interval in
                RangeInterval(id: intervalID(index: index, speed: true), metric: .speed, start: interval.start, end: interval.end)
            }
    }
    private func intervalID(index: Int, speed: Bool) -> UUID {
        let suffix = UInt32(truncatingIfNeeded: index) | (speed ? 0x80000000 : 0)
        return UUID(uuidString: String(id.uuidString.prefix(28)) + String(format: "%08X", suffix))!
    }
}
