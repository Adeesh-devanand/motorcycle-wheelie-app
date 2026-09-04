import Foundation

/// The beta's live estimator: raw gyro integrated from a once-measured alignment
/// and bias, with the accelerometer never touching the result.
///
/// Deliberately much less than `AttitudeESKF`. There is no gravity update, no
/// covariance, no delayed-state buffer, no grade baseline, and no bias
/// re-estimation. What remains is the propagate step and one subtraction:
///
///     rate  = rawGyro - b
///     Q     = Q * exp(rate * dt)
///     pitch = asin(rotate(forwardInBody).z)
///
/// ## Why the accelerometer is excluded, not merely down-weighted
/// An accelerometer measures specific force — gravity PLUS linear acceleration —
/// and cannot decompose them. A sustained wheelie needs thrust of roughly
/// `g*tan(theta)`, so the accelerometer's error is *correlated with the very signal
/// being measured*: at 0.5 g of forward acceleration it reports 26.6 deg of pitch
/// that is not there. Weighting it low does not help, because variance inflation
/// models UNCORRELATED error — the filter treats repeated samples as independent
/// evidence and still converges on the wrong answer. That is why the ESKF SKIPS
/// rather than down-weights, and why this mode does not consume the accelerometer
/// at all outside calibration.
///
/// Apple's fused fields are excluded for the same reason at one remove:
/// `CMDeviceMotion.rotationRate` is debiased using the accelerometer, and
/// `attitude`/`gravity` are derived from it, so all three re-import the confound
/// invisibly. Raw gyro carries no accelerometer correction of any kind.
///
/// ## What this costs, stated plainly
/// Bias is measured once and held constant, so thermal walk accumulates
/// uncorrected: self-heating moves bias ~0.1 deg/s over 30 minutes, and 0.5 deg/s
/// of stale bias is about 5 deg of error over a 10 s hold. Nothing here corrects
/// that — `BiasEstimate.projectedPitchSigma(age:holdDuration:config:)` is what
/// tells the rider how much to distrust the number, and it must be surfaced.
/// `JitterBlur` does not help either: it removes jitter, not drift.
public struct CalibrateOnceEstimator {
    private let config: Config
    private let alignment: MountAlignment
    /// Measured once at calibration and never updated. That is the whole point of
    /// the mode's name, and the whole of its accuracy cost.
    private let bias: Vector3

    public private(set) var attitude: Quaternion
    /// Whether gravity has fixed the world frame. Before this, integrated attitude
    /// is relative to the initial DEVICE frame, which for a crooked mount differs
    /// from the world by the entire mount rotation — so nothing may be published.
    public private(set) var isAnchored: Bool

    private var lastTime: TimeInterval?

    public private(set) var pitch: Double = 0
    public private(set) var pitchRate: Double = 0
    public private(set) var roll: Double = 0

    /// - Parameter gravityAnchor: body-frame specific force measured at rest during
    ///   calibration. Nil defers anchoring to the first sample handed to
    ///   `anchor(with:)`.
    public init(config: Config,
                alignment: MountAlignment,
                bias: Vector3,
                gravityAnchor: Vector3? = nil) {
        self.config = config
        self.alignment = alignment
        self.bias = bias

        if let f = gravityAnchor, f.magnitude > 1e-6 {
            // Same construction the ESKF uses: specific force points ALONG gravity,
            // so body-frame f corresponds to world (0,0,-g). This fixes TILT and
            // leaves heading arbitrary, which is correct and sufficient — pitch is
            // read as the elevation of a single axis, and an elevation does not
            // depend on which compass direction that axis points.
            self.attitude = Quaternion.rotation(from: f, to: Conventions.worldGravity)
            self.isAnchored = true
        } else {
            self.attitude = .identity
            self.isAnchored = false
        }
        refreshReadings()
    }

    /// Establishes the world frame from a measured at-rest specific force. Also the
    /// re-anchor path: a completed re-calibration makes the pose the rider just held
    /// the new zero.
    ///
    /// Clearing `lastTime` is load-bearing, not tidiness. Without it the next sample
    /// computes its `dt` against a timestamp from BEFORE the re-anchor and integrates
    /// that span onto the attitude that was just declared to be zero — so a re-zero
    /// taken after a pause would immediately tilt off the level reference the rider
    /// explicitly set. Dropping one sample to re-establish the timebase costs 10 ms
    /// and keeps the declared zero actually zero.
    public mutating func anchor(with specificForce: Vector3) {
        guard specificForce.magnitude > 1e-6 else { return }
        attitude = Quaternion.rotation(from: specificForce,
                                       to: Conventions.worldGravity)
        isAnchored = true
        lastTime = nil
        // The rate that applied before the re-anchor describes the old frame and
        // must not survive into the new one.
        pitchRate = 0
        refreshReadings()
    }

    /// Integrates one sample. Returns false while unanchored or on the first sample,
    /// where no `dt` exists yet.
    ///
    /// A `false` return means the attitude did NOT advance. `pitch`/`roll` deliberately
    /// hold their last values — a frozen angle is the honest answer when there is no
    /// interval to integrate — but `pitchRate` is zeroed, because "I do not know the
    /// current rate" must not read as "the last known rate is still current". The cue
    /// predicts a threshold crossing from `pitchRate`, and a rate left over from
    /// before a gap would have it predict from motion that is seconds out of date.
    @discardableResult
    public mutating func integrate(_ sample: IMUSample) -> Bool {
        defer { lastTime = sample.time }
        guard isAnchored, let previous = lastTime else {
            pitchRate = 0
            return false
        }

        let dt = sample.time - previous
        // A non-positive or absurd dt means the stream jumped: replaying across a
        // gap, or a reordered sample. Integrating it would rotate the attitude by a
        // fabricated amount, so skip and resynchronise on the next pair.
        guard dt > 0, dt < config.maxIntegrationDt else {
            pitchRate = 0
            return false
        }

        let rate = sample.rotationRate - bias
        attitude = (attitude * Quaternion.exp(rotationVector: rate * dt)).normalized
        refreshReadings(rate: rate)
        return true
    }

    private mutating func refreshReadings(rate: Vector3? = nil) {
        pitch = AxisElevation.pitch(attitude: attitude,
                                   forwardInBody: alignment.forwardInBody)
        roll = AxisElevation.roll(attitude: attitude,
                                 forwardInBody: alignment.forwardInBody,
                                 upInBody: alignment.upInBody)
        if let rate {
            // Nose-up is a NEGATIVE rotation about bike +Y (left), per Conventions,
            // so the pitch rate is the negated projection of the debiased body rate
            // onto the bike's lateral axis. Read off the axis rather than
            // differencing successive pitch values: differencing amplifies the
            // sample-to-sample jitter that the cue is most sensitive to.
            pitchRate = -rate.dot(alignment.leftInBody.normalized)
        }
    }

    /// Open-loop 1-sigma pitch error projected from the age of the bias estimate.
    ///
    /// NOT a filter covariance. There is no filter here, so there is nothing to
    /// propagate a covariance through — this is an error BUDGET computed from how
    /// stale the bias is and how long the hold has lasted. It is reported in the same
    /// field the ESKF fills with a real covariance, so the distinction has to live in
    /// the name and in this comment, or a reader will take one for the other.
    public func projectedPitchSigma(estimate: BiasEstimate?,
                                    now: TimeInterval,
                                    holdDuration: TimeInterval) -> Double {
        guard let estimate else { return config.liveSigmaLimit }
        return estimate.projectedPitchSigma(age: max(0, now - estimate.monotonicTime),
                                            holdDuration: holdDuration,
                                            config: config)
    }
}
