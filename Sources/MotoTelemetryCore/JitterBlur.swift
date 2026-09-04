import Foundation

/// Zero-phase jitter blur for a recorded pitch series.
///
/// The beta's post-event cleaner. It removes VIBRATION JITTER from a recorded
/// wheelie and nothing else — see the limits section, which is the important part
/// of this file.
///
/// ## Why zero-phase, and why that is only possible offline
/// A causal filter can only look backwards, so it necessarily lags: the smoothed
/// value at time t is built from samples at or before t, and the output arrives
/// late by roughly the filter's time constant. That lag is fatal to the live path,
/// whose whole job is to warn the rider BEFORE an angle is reached, which is why
/// the live estimate is never filtered.
///
/// Offline the constraint disappears, because the whole event already exists. This
/// filter averages each point against neighbours on BOTH sides, so the phase shift
/// one side would introduce is cancelled by the other: the blurred curve lines up
/// in time with the raw one. A centred window is the entire trick, and it is
/// available only after the fact.
///
/// ## What it fixes
/// Fast wiggle. On a bike the pitch reading carries a few degrees of vibration
/// jitter even at a steady angle, and a plain `max()` over that series does not
/// find the peak of the real angle — it finds the peak of *angle plus the single
/// luckiest upward noise spike in the whole hold*. Averaging a spike against its
/// neighbours pulls it back toward the real curve, which is what makes
/// max-over-blurred an honest improvement on max-over-raw.
///
/// ## What it CANNOT fix, and this must not be forgotten
/// **Drift.** The beta measures gyro bias once, at calibration, and holds it
/// constant, so the integrated angle slowly leans away from truth as the phone
/// self-heats (~0.1 deg/s over 30 min; 0.5 deg/s of stale bias is ~5 deg over a
/// 10 s hold). Blurring does nothing to that, because every neighbour is drifted by
/// almost the same amount — averaging a set of consistently-wrong numbers returns a
/// consistently-wrong number. Removing drift needs an ABSOLUTE reference (a
/// trustworthy "down"), which only the accelerometer carries, and the accelerometer
/// is unusable during and immediately after a wheelie: rpm surges and chassis
/// vibration peg it, and thrust makes it read "down" as wherever the bike is
/// accelerating.
///
/// That is why this replaced the RTS smoother (`AttitudeSmoother`) in the beta.
/// RTS does correct drift, using a post-event gravity anchor — but it needs ~2 s of
/// level, low-vibration rolling right after the wheel drops, and a real rider
/// brakes, tilts into a corner, or idles rough with the engine still shaking the
/// phone. The anchor rarely exists cleanly, and a marginal one would anchor on a
/// slightly-wrong "down" and bake that error into the stored number. So the beta
/// keeps the half that needs no anchor and accepts the drift, which is invisible
/// and consistent rather than the flappy noise a rider actually notices.
///
/// The eventual fix is a measured drift model — fit bias-versus-time/temperature
/// across many logged rides, then predict and subtract it live — which stays
/// pure-gyro and never touches the accelerometer. It needs a pile of real rides
/// first, which the beta is what generates.
public struct JitterBlur {
    /// Why a series was returned unblurred.
    public enum Unavailable: Error, Equatable {
        /// Fewer samples than `Config.blurMinSamples`. A window wider than the data
        /// would flatten the event rather than clean it.
        case tooFewSamples(count: Int, required: Int)
    }

    /// Half-width of the centred window, in samples. The full width is
    /// `2 * halfWidth + 1`, which is odd by construction — an even width has no
    /// centre sample and would shift the series in time, defeating the one property
    /// this filter exists to have.
    public let halfWidth: Int
    public let minSamples: Int

    /// Full window width in samples, always odd.
    public var windowSamples: Int { 2 * halfWidth + 1 }

    public init(config: Config = Config()) {
        // Round an even or too-small configured width up to the next valid odd
        // width rather than trusting the caller: a silently-even window is exactly
        // the bug that would reintroduce lag, and lag is the thing this file is for.
        self.halfWidth = max(1, config.blurWindowSamples / 2)
        self.minSamples = max(3, config.blurMinSamples)
    }

    /// Explicit-parameter initializer, for tests that pin a specific width.
    public init(halfWidth: Int, minSamples: Int) {
        self.halfWidth = max(1, halfWidth)
        self.minSamples = max(3, minSamples)
    }

    /// Blurs a series, preserving its length and its timing.
    ///
    /// Near the edges the window is TRUNCATED symmetrically rather than padded: at
    /// index 1 it averages 3 samples, not 9. Padding with a repeated end value would
    /// drag the first and last samples toward that value, and clamping the window
    /// off-centre would shift those samples in time — both of which would show up as
    /// a fake ramp at the start of every wheelie, precisely where the entry peak
    /// lives. A narrower window near the edge just means less noise reduction there,
    /// which is honest.
    public func blur(_ series: [Double]) -> Result<[Double], Unavailable> {
        guard series.count >= minSamples else {
            return .failure(.tooFewSamples(count: series.count, required: minSamples))
        }

        var out = [Double](repeating: 0, count: series.count)
        for i in series.indices {
            let lower = max(0, i - halfWidth)
            let upper = min(series.count - 1, i + halfWidth)
            // Symmetric truncation: shrink to whichever side is closer to the edge,
            // so the window stays CENTRED on i and the output cannot shift in time.
            let reach = min(i - lower, upper - i)
            let from = i - reach
            let through = i + reach
            var sum = 0.0
            for j in from...through { sum += series[j] }
            out[i] = sum / Double(through - from + 1)
        }
        return .success(out)
    }

    /// Convenience for a timestamped series: blurs the values, returns the same
    /// times. The times are untouched — a zero-phase filter that moved its own
    /// timestamps would be a contradiction.
    public func blur(
        _ series: [(time: TimeInterval, value: Double)]
    ) -> Result<[(time: TimeInterval, value: Double)], Unavailable> {
        blur(series.map(\.value)).map { blurred in
            zip(series, blurred).map { (time: $0.0.time, value: $0.1) }
        }
    }
}
