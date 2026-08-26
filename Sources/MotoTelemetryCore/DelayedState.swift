import Foundation

/// Holds recent filter states so a late measurement can be applied at the time it
/// was actually FOR, then re-propagated forward to the present.
///
/// A CoreLocation fix arrives 100-400 ms after its `fixTime` — the log records both
/// so the latency is measured rather than assumed. Applying a 250 ms-old observation
/// to the current state smears it: at 30 deg/s that is 7.5 degrees of attitude
/// applied to the wrong instant. The alternative usually reached for, inflating R to
/// "cover" the latency, throws away the information instead of using it, and is not
/// reproducible on replay in the same way.
///
/// Cost: 200 entries at 100 Hz, each replayed through one 6-state propagation, is a
/// few hundred microseconds once per second. Negligible, and exactly reproducible.
public struct DelayedStateBuffer {
    private var entries: [AttitudeESKF.Snapshot] = []
    private let capacity: Int
    private let window: TimeInterval

    /// Fixes older than the buffer are discarded and counted, never silently
    /// applied to the wrong state.
    public private(set) var discardedTooOld = 0
    public private(set) var applied = 0

    public init(config: Config) {
        self.window = config.delayedStateWindow
        self.capacity = max(2, Int(config.delayedStateWindow * config.nominalSampleRate) + 2)
        entries.reserveCapacity(capacity)
    }

    public var count: Int { entries.count }
    public var oldestTime: TimeInterval? { entries.first?.time }
    public var newestTime: TimeInterval? { entries.last?.time }

    public mutating func record(_ snapshot: AttitudeESKF.Snapshot) {
        entries.append(snapshot)
        // Drop anything beyond the window, and hard-cap the count.
        let cutoff = snapshot.time - window
        while let first = entries.first, first.time < cutoff {
            entries.removeFirst()
        }
        while entries.count > capacity {
            entries.removeFirst()
        }
    }

    /// Index of the last entry at or before `time`, or nil if `time` predates the
    /// buffer.
    private func indexAtOrBefore(_ time: TimeInterval) -> Int? {
        guard !entries.isEmpty else { return nil }
        guard time >= entries[0].time else { return nil }
        var low = 0, high = entries.count - 1, best = 0
        while low <= high {
            let mid = (low + high) / 2
            if entries[mid].time <= time {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return best
    }

    /// Rewinds `filter` to the state bracketing `fixTime`, runs `update` there, and
    /// re-propagates through every stored sample after it.
    ///
    /// Returns false when the fix is too old to place, in which case the filter is
    /// left untouched.
    public mutating func applyRetroactively(
        to filter: inout AttitudeESKF,
        fixTime: TimeInterval,
        thermalState: Int,
        update: (inout AttitudeESKF, AttitudeESKF.Snapshot) -> Void
    ) -> Bool {
        guard let index = indexAtOrBefore(fixTime) else {
            discardedTooOld += 1
            return false
        }

        let anchor = entries[index]
        filter.restore(anchor)
        update(&filter, anchor)

        // Re-propagate forward through the recorded raw samples. The bias has just
        // changed, so each rate must be re-corrected with the new bias — which is
        // why the snapshot stores the RAW measured rate.
        if index + 1 < entries.count {
            for i in (index + 1)..<entries.count {
                let entry = entries[i]
                let sample = IMUSample(time: entry.time,
                                       rotationRate: entry.measuredRate,
                                       specificForce: entry.specificForce,
                                       saturated: entry.saturated)
                filter.propagate(sample, thermalState: thermalState)
                filter.updateWithGravity(
                    sample,
                    verdict: ValidityGate.Verdict(
                        isOpen: entry.gateOpen,
                        heldFor: 0,
                        reason: entry.gateReason))
                // Refresh the stored state so a second late fix in the same window
                // rewinds to corrected history rather than stale history.
                entries[i] = filter.snapshot(measuredRate: entry.measuredRate,
                                             specificForce: entry.specificForce,
                                             saturated: entry.saturated,
                                             gateOpen: entry.gateOpen,
                                             gateReason: entry.gateReason)
            }
        }
        applied += 1
        return true
    }

    public mutating func reset() {
        entries.removeAll(keepingCapacity: true)
    }
}

/// Estimates ground acceleration by differentiating consecutive GNSS Doppler speeds,
/// and reports how uncertain that estimate is.
///
/// Differentiation amplifies noise: sigma_a = sqrt(2) * sigma_v / dt. With 0.1 m/s
/// speed accuracy over a 1 s interval that is 0.141 m/s^2, which is the dominant
/// term in the GNSS pitch measurement's noise budget.
public struct GroundAccelerationEstimator {
    private var previous: GNSSFix?
    private let config: Config

    public init(config: Config) { self.config = config }

    public struct Estimate: Sendable {
        public var acceleration: Double        // m/s^2, along track
        public var sigma: Double               // m/s^2
        public var midTime: TimeInterval       // the instant it is FOR
        public var speed: Double               // m/s, at midTime
    }

    /// Returns an estimate when two usable fixes are available, else nil.
    public mutating func process(_ fix: GNSSFix) -> Estimate? {
        defer { if fix.isSpeedValid { previous = fix } }

        guard fix.isSpeedValid,
              fix.speedAccuracy >= 0,
              fix.speedAccuracy <= config.gnssMaxSpeedAccuracy,
              let last = previous,
              last.isSpeedValid,
              last.speedAccuracy >= 0,
              last.speedAccuracy <= config.gnssMaxSpeedAccuracy
        else { return nil }

        let dt = fix.fixTime - last.fixTime
        guard dt > 0.1, dt < 5.0 else { return nil }

        let acceleration = (fix.speed - last.speed) / dt
        // Independent errors on both speeds, so they add in quadrature.
        let sigma = (fix.speedAccuracy * fix.speedAccuracy
                     + last.speedAccuracy * last.speedAccuracy).squareRoot() / dt

        // The difference is centred between the two fixes, not at either end.
        // Stamping it at fix.fixTime would bias the measurement by dt/2.
        let midTime = (fix.fixTime + last.fixTime) / 2
        let speed = (fix.speed + last.speed) / 2

        return Estimate(acceleration: acceleration,
                        sigma: sigma,
                        midTime: midTime,
                        speed: speed)
    }

    public mutating func reset() { previous = nil }
}
