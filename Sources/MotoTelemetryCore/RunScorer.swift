import Foundation

/// Per-event metrics computed over PipelineOutput samples between onset and end.
///
/// The hold window (for angleStdDev) is the plateau between end-of-rise and
/// start-of-descent, located by pitch-rate zero crossings. Computing std dev over
/// the whole event would measure the ramp's slope spread, not the rider's
/// steadiness at the top — which defeats the metric's purpose.
public struct EventMetrics: Codable, Sendable, Equatable {
    public var onset: TimeInterval
    public var end: TimeInterval
    public var duration: TimeInterval
    public var liveMaxAngle: Double             // rad
    public var averageHeldAngle: Double         // rad, hold window only
    public var angleStdDev: Double              // rad, hold window only — measures steadiness
    public var distance: Double?                // m, nil when fewer than distanceMinFixes
    public var entrySpeed: Double?              // m/s at onset
    public var rollMin: Double                  // rad
    public var rollMax: Double                  // rad
    public var flags: QualityFlags

    /// False when the hold window could not be located from pitch-rate zero
    /// crossings and a middle-of-event heuristic was substituted.
    ///
    /// This is surfaced rather than hidden because `angleStdDev` means something
    /// quite different in the two cases: over a real plateau it is the rider's
    /// steadiness, which is the metric's whole point, while over an arbitrary middle
    /// slice of a ramp-shaped event it is mostly the ramp's slope. A consistency
    /// number the code cannot vouch for has to say so, or it silently competes for a
    /// personal best against numbers that were measured properly.
    public var holdWindowResolved: Bool
}

/// Accumulates samples during an active event and computes EventMetrics on close.
public struct RunScorer {
    private let holdRateEpsilon: Double
    private let distanceMinFixes: Int

    private var samples: [(time: TimeInterval, pitch: Double, pitchRate: Double, roll: Double)] = []
    private var gnssFixes: [(time: TimeInterval, speed: Double)] = []
    private var onset: TimeInterval = 0
    private var entrySpeed: Double?
    private var flags: QualityFlags = []

    public init(config: Config = Config()) {
        self.holdRateEpsilon = config.holdRateEpsilon
        self.distanceMinFixes = config.distanceMinFixes
    }

    /// Call when an onset transition fires.
    public mutating func beginEvent(onset: TimeInterval, entrySpeed: Double?, flags: QualityFlags = []) {
        self.onset = onset
        self.entrySpeed = entrySpeed
        self.flags = flags
        samples.removeAll(keepingCapacity: true)
        gnssFixes.removeAll(keepingCapacity: true)
    }

    /// Feed every PipelineOutput sample while active.
    public mutating func addSample(time: TimeInterval, pitch: Double, pitchRate: Double, roll: Double) {
        samples.append((time, pitch, pitchRate, roll))
    }

    /// Feed GNSS fixes that arrive during the event.
    public mutating func addGNSSFix(time: TimeInterval, speed: Double) {
        gnssFixes.append((time, speed))
    }

    /// Insert quality flags discovered during the event (e.g. saturation).
    public mutating func insertFlag(_ flag: QualityFlags) {
        flags.insert(flag)
    }

    /// Finalise the event and compute all metrics. Call when end transition fires.
    public func finalise(end: TimeInterval) -> EventMetrics {
        let duration = end - onset

        // Max angle and roll envelope over all collected samples.
        var maxAngle: Double = 0
        var rollMin: Double = .greatestFiniteMagnitude
        var rollMax: Double = -.greatestFiniteMagnitude

        for s in samples {
            if s.pitch > maxAngle { maxAngle = s.pitch }
            if s.roll < rollMin { rollMin = s.roll }
            if s.roll > rollMax { rollMax = s.roll }
        }
        if samples.isEmpty {
            rollMin = 0
            rollMax = 0
        }

        // Hold window: between the end of the rise and the start of the descent,
        // located by pitch-rate crossings of the holdRateEpsilon deadband. When both
        // cannot be found the window is a middle-of-event heuristic, and that is
        // reported through `holdWindowResolved` rather than passed off as a measured
        // plateau.
        let (holdRange, holdResolved) = computeHoldWindow()
        let holdSamples = samples.filter { holdRange.contains($0.time) }

        let averageHeld: Double
        let stdDev: Double
        if holdSamples.count >= 2 {
            let pitches = holdSamples.map { $0.pitch }
            let mean = pitches.reduce(0, +) / Double(pitches.count)
            averageHeld = mean
            let variance = pitches.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
                / Double(pitches.count - 1)
            stdDev = variance.squareRoot()
        } else if !samples.isEmpty {
            // Degenerate: not enough hold samples, use all samples.
            let pitches = samples.map { $0.pitch }
            let mean = pitches.reduce(0, +) / Double(pitches.count)
            averageHeld = mean
            let variance = pitches.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
                / Double(max(pitches.count - 1, 1))
            stdDev = variance.squareRoot()
        } else {
            averageHeld = 0
            stdDev = 0
        }

        // Distance: trapezoid integration of GNSS speed over fixTime.
        let distance: Double?
        if gnssFixes.count >= distanceMinFixes {
            var sum: Double = 0
            for i in 1..<gnssFixes.count {
                let dt = gnssFixes[i].time - gnssFixes[i - 1].time
                let avgSpeed = (gnssFixes[i].speed + gnssFixes[i - 1].speed) / 2
                sum += avgSpeed * dt
            }
            distance = sum
        } else {
            distance = nil
        }

        return EventMetrics(
            onset: onset,
            end: end,
            duration: duration,
            liveMaxAngle: maxAngle,
            averageHeldAngle: averageHeld,
            angleStdDev: stdDev,
            distance: distance,
            entrySpeed: entrySpeed,
            rollMin: rollMin,
            rollMax: rollMax,
            flags: flags,
            holdWindowResolved: holdResolved && holdSamples.count >= 2
        )
    }

    // MARK: - Hold window detection

    /// Locates the hold window by finding pitch-rate zero crossings.
    /// The hold is the interval between:
    ///   - last time pitchRate drops INTO the deadband from above (end of rise)
    ///   - first time pitchRate drops OUT of the deadband downward (start of descent)
    ///
    /// Uses holdRateEpsilon as a symmetric deadband around zero.
    ///
    /// Returns the window and whether it was genuinely LOCATED. A false second
    /// element means the caller is looking at a heuristic slice, not a plateau.
    private func computeHoldWindow() -> (ClosedRange<TimeInterval>, Bool) {
        guard samples.count >= 2 else {
            return (onset...onset, false)
        }

        let eventStart = samples.first!.time
        let eventEnd = samples.last!.time

        // Find the last transition from above-epsilon to within-epsilon
        // (end of the initial rise) — scanning forward, record each such crossing.
        var holdStart: TimeInterval = eventStart
        var holdEnd: TimeInterval = eventEnd

        // Scan for the LAST time pitchRate crosses down through +epsilon
        // (marking end of rise). We want the last such crossing that is followed
        // by a period within the deadband.
        var lastRiseEnd: TimeInterval?
        for i in 1..<samples.count {
            let prev = samples[i - 1].pitchRate
            let curr = samples[i].pitchRate
            // Transition from above epsilon to within the deadband
            if prev > holdRateEpsilon && curr <= holdRateEpsilon {
                lastRiseEnd = samples[i].time
                break  // First one from the start = end of the initial rise
            }
        }

        // Scan backward for the FIRST time pitchRate crosses down through -epsilon
        // (marking start of descent).
        var firstDescentStart: TimeInterval?
        for i in stride(from: samples.count - 1, through: 1, by: -1) {
            let prev = samples[i - 1].pitchRate
            let curr = samples[i].pitchRate
            // Transition from within deadband to below -epsilon
            if prev >= -holdRateEpsilon && curr < -holdRateEpsilon {
                firstDescentStart = samples[i - 1].time
                break  // First one from the end = start of the final descent
            }
        }

        if let start = lastRiseEnd { holdStart = start }
        if let end = firstDescentStart { holdEnd = end }

        // Sanity: hold window must be non-inverted
        // Both crossings must have been found for the window to mean what the metric
        // claims it means.
        let resolved = lastRiseEnd != nil && firstDescentStart != nil && holdStart < holdEnd

        if holdStart >= holdEnd {
            // Heuristic: middle 60% of the event. Flagged, not silent.
            let mid = (eventStart + eventEnd) / 2
            let span = (eventEnd - eventStart) * 0.3
            holdStart = mid - span
            holdEnd = mid + span
        }

        return (holdStart...holdEnd, resolved)
    }
}

// MARK: - Session Summary

/// Aggregate statistics over all events in a session.
public struct SessionSummary: Sendable, Equatable {
    public var eventCount: Int
    public var cumulativeHoldTime: TimeInterval
    public var bestMaxAngle: EventMetrics?
    public var bestDuration: EventMetrics?
    public var bestDistance: EventMetrics?
    public var bestConsistency: EventMetrics?  // lowest angleStdDev

    public init(events: [EventMetrics]) {
        eventCount = events.count

        // Cumulative hold time approximated as total event duration (the hold
        // window is a subset, but duration is the closest without storing the
        // hold boundaries separately).
        cumulativeHoldTime = events.reduce(0) { $0 + $1.duration }

        bestMaxAngle = events.max(by: { $0.liveMaxAngle < $1.liveMaxAngle })
        bestDuration = events.max(by: { $0.duration < $1.duration })
        bestDistance = events.compactMap({ $0.distance != nil ? $0 : nil })
            .max(by: { ($0.distance ?? 0) < ($1.distance ?? 0) })
        // Best consistency = lowest std dev (most stable hold), among events whose
        // hold window was actually RESOLVED from pitch-rate crossings.
        //
        // The `holdWindowResolved` flag exists precisely to keep a heuristic window
        // out of a personal best, and this line previously ignored it. That was the
        // worst possible direction to fail: the heuristic fallback takes a fixed
        // ±30% slice around the event's midpoint, which is narrower and better
        // centred than a real hold, so it tends to produce a LOWER std dev than an
        // honestly-measured hold — meaning a fallback event did not merely compete
        // for the best-consistency slot, it was biased toward winning it.
        bestConsistency = events
            .filter { $0.holdWindowResolved }
            .min(by: { $0.angleStdDev < $1.angleStdDev })
    }
}
