import Foundation
import MotoTelemetryCore
import Observation

/// §9 view model — provides downsampled data, intervals, summary metrics,
/// and shared scrubber state for Run Details.
@Observable
final class RunDetailsViewModel {

    // MARK: - Public State

    let run: WheelieRun
    let angleIntervals: [RangeInterval]
    let speedIntervals: [RangeInterval]
    let displaySamples: [TelemetrySample]
    private(set) var speedSegments: [[Downsample.Point]] = []
    private(set) var anglePoints: [Downsample.Point] = []
    private(set) var speedPoints: [Downsample.Point] = []
    var selectedTime: TimeInterval?

    // MARK: - Summary Metrics

    var duration: TimeInterval { run.duration }
    var maxAngle: Double { run.maxAngle }
    var maxSpeed: Double { run.maxSpeed }
    var averageSpeed: Double { run.averageSpeed }

    var totalAngleInRange: TimeInterval {
        angleIntervals.reduce(0) { $0 + $1.duration }
    }

    var totalSpeedInRange: TimeInterval {
        speedIntervals.reduce(0) { $0 + $1.duration }
    }

    // MARK: - Chart Domains

    var timeDomain: ClosedRange<TimeInterval> {
        0...max(run.duration, 0.1)
    }

    var angleDomain: ClosedRange<Double> { 0...90 }

    var speedDomain: ClosedRange<Double> {
        0...run.configuration.speedGaugeMaximum
    }

    // MARK: - Configuration Snapshot

    var angleTarget: MetricRange { run.configuration.angleTarget }
    var speedTarget: MetricRange { run.configuration.speedTarget }

    // MARK: - Init

    init(run: WheelieRun) {
        self.run = run
        angleIntervals = run.angleIntervals
        speedIntervals = run.speedIntervals
        displaySamples = run.samples.map {
            TelemetrySample(id: $0.id, elapsed: $0.elapsed,
                angleDegrees: $0.blurredAngleDegrees ?? $0.angleDegrees,
                speedKPH: $0.speedValid == true ? $0.speedKPH : .nan,
                speedValid: $0.speedValid)
        }
        downsample()
    }

    // MARK: - Interpolation (§9.4 scrubber)

    func valuesAtTime(_ time: TimeInterval) -> (angle: Double, speed: Double) {
        let samples = displaySamples
        guard samples.count >= 2 else {
            let s = samples.first
            return (s?.angleDegrees ?? 0, s?.speedKPH ?? 0)
        }

        // Binary search for the bracket
        var lo = 0
        var hi = samples.count - 1
        while lo < hi - 1 {
            let mid = (lo + hi) / 2
            if samples[mid].elapsed <= time {
                lo = mid
            } else {
                hi = mid
            }
        }

        let a = samples[lo]
        let b = samples[hi]

        guard b.elapsed != a.elapsed else {
            return (a.angleDegrees, a.speedKPH)
        }

        guard b.elapsed - a.elapsed <= 0.25 else { return (.nan, .nan) }
        let u = (time - a.elapsed) / (b.elapsed - a.elapsed)
        let clampedU = max(0, min(1, u))
        let angle = a.angleDegrees + clampedU * (b.angleDegrees - a.angleDegrees)
        let speed = a.speedKPH + clampedU * (b.speedKPH - a.speedKPH)
        return (angle, speed)
    }

    // MARK: - Downsampling

    private func downsample() {
        let samples = displaySamples

        let rawAngle = samples.map { Downsample.Point(x: $0.elapsed, y: $0.angleDegrees) }
        let rawSpeed = samples.map { Downsample.Point(x: $0.elapsed, y: $0.speedKPH) }

        anglePoints = Downsample.lttb(rawAngle, threshold: Downsample.defaultThreshold)
        var segment: [Downsample.Point] = []
        for point in rawSpeed {
            if !point.y.isFinite || segment.last.map({ point.x - $0.x > 0.25 }) == true {
                if !segment.isEmpty { speedSegments.append(Downsample.lttb(segment, threshold: Downsample.defaultThreshold)) }
                segment = []
            }
            if point.y.isFinite { segment.append(point) }
        }
        if !segment.isEmpty { speedSegments.append(Downsample.lttb(segment, threshold: Downsample.defaultThreshold)) }
        speedPoints = speedSegments.flatMap { $0 }
    }
}
