import Foundation

/// The live attitude estimator: a 6-state error-state Kalman filter over raw IMU,
/// gyro-dominated by design.
///
/// ## Why an error state
/// A quaternion has four components and three degrees of freedom, so filtering it
/// directly means fighting a normalisation constraint. Instead the NOMINAL
/// trajectory (q, b) is carried outside the covariance and the filter estimates
/// the small ERROR against it:
///
///     q_true = q_nominal * exp(dTheta)      (dTheta in the BODY frame)
///     b_true = b_nominal + dBias
///
/// The error is reset to zero after every update, so the linearisation is always
/// about the current best guess and never drifts far from valid.
///
/// Attitude error is expressed in the BODY frame because both measurements —
/// gravity, and the elevation of the bike's forward axis — are naturally body
/// quantities, which keeps each Jacobian to one `skew()` call.
///
/// ## Why the accelerometer is inflated rather than dropped
/// An accelerometer measures specific force, gravity PLUS linear acceleration, and
/// cannot decompose them. During a sustained wheelie thrust is roughly g*tan(theta),
/// so the phantom pitch is almost perfectly correlated with the true pitch: the
/// accelerometer is systematically wrong, not merely noisy. The filter therefore
/// inflates its measurement noise by orders of magnitude when the gate is shut,
/// rather than switching it off. A hard on/off schedule injects a covariance step
/// every time a bump closes the gate, and steps are what make a live angle readout
/// visibly jump.
public struct AttitudeESKF {

    // MARK: - Nominal state

    /// Body -> world attitude.
    public private(set) var attitude: Quaternion
    /// Gyro bias estimate, rad/s, body frame.
    public private(set) var bias: Vector3
    /// 6x6 error covariance, ordered [attitude error (3); bias error (3)].
    public private(set) var covariance: Symmetric6

    /// Set when the covariance lost positive-definiteness. The filter keeps running
    /// on gyro integration with inflated uncertainty, and says so — a silent
    /// fallback here would present garbage as a measurement.
    public private(set) var isDegraded = false

    /// Last angular rate used for propagation, rad/s, bias-corrected.
    public private(set) var lastCorrectedRate = Vector3.zero
    /// Monotonic time of the most recent propagation.
    public private(set) var time: TimeInterval?

    private let config: Config
    /// Bike axes in device axes. Mutable because it is DERIVED from measured
    /// gravity at the anchor moment when the caller supplied no real alignment;
    /// `Pipeline` reads it back so the two can never disagree.
    public private(set) var alignment: MountAlignment

    /// False until the attitude has been tied to MEASURED gravity. While false the
    /// filter's world frame is just the initial device frame, so "up" is wherever
    /// the phone happened to be pointing — every tilt away from that pose reads as
    /// a positive elevation regardless of direction, which is indistinguishable
    /// from a wheelie when the rider is only leaning. `AttitudeSmoother` already
    /// anchors (it passes the first gate-open sample); the live filter must too.
    private var hasAnchored: Bool

    /// True once attitude has been tied to MEASURED gravity.
    ///
    /// Until then the world frame is the raw device frame and `pitch` is meaningless
    /// — a flat phone reads about -90 deg, and a device log caught exactly that
    /// (-89.7 deg) being published into the pipeline 16 ms before the anchor was
    /// acquired. Callers must publish nothing while this is false.
    public var isAnchored: Bool { hasAnchored }
    /// Whether the pending anchor must be near-level. True for a COLD anchor (nobody
    /// has declared anything); cleared by `requestReanchor()`, where the rider has.
    private var anchorRequiresLevel = true
    /// Whether the bike axes have been derived from gravity yet.
    ///
    /// Deliberately NOT cleared by `requestReanchor()`. A re-anchor must re-zero the
    /// attitude, but the axes are a guess gravity cannot improve on, and re-guessing
    /// them per calibration silently changes which tilt counts as a wheelie.
    private var hasDerivedAlignment: Bool

    /// eskf diagnostics. Anchor/reanchor/bias-applied are milestones (via
    /// `always`); the per-sample pitch/bias line is a 1 Hz heartbeat.
    private var diag: DiagnosticEmitter

    // MARK: - Init

    /// Seeds from a bias estimate and, optionally, a gate-open specific force that
    /// anchors attitude to gravity.
    ///
    /// Seeding attitude from gravity rather than identity is not optional for a
    /// crooked mount: integrating device-frame gyro from identity yields attitude
    /// relative to the initial DEVICE frame, which differs from the world by the
    /// entire mount rotation.
    public init(config: Config,
                alignment: MountAlignment,
                initialBias: BiasEstimate?,
                gravityAnchor: Vector3? = nil,
                initialAttitudeSigma: Double = 5.0 * .pi / 180,
                sink: DiagnosticSink? = nil) {
        self.config = config
        self.alignment = alignment
        self.bias = initialBias?.bias ?? .zero
        self.diag = DiagnosticEmitter(sink: sink, category: "eskf")

        if let f = gravityAnchor, f.magnitude > 1e-6 {
            // Specific force points ALONG gravity, so f in body corresponds to
            // (0,0,-1) in world. Rotate body -> world accordingly.
            self.attitude = Quaternion.rotation(from: f, to: Conventions.worldGravity)
            self.hasAnchored = true
            // A caller that supplied an anchor supplied an alignment too (tests,
            // replay, a real R7.1 solve). Treat those axes as established so no
            // later re-anchor overwrites them with a gravity guess.
            self.hasDerivedAlignment = true
        } else {
            self.attitude = .identity
            self.hasAnchored = false
            self.hasDerivedAlignment = false
        }

        // Bias variance comes from the calibration that produced it: a filter told
        // its bias is perfect will never correct it.
        let biasSigma = initialBias?.worstSigma ?? (1.0 * .pi / 180)
        let attitudeVariance = initialAttitudeSigma * initialAttitudeSigma
        let biasVariance = biasSigma * biasSigma
        self.covariance = .diagonal([attitudeVariance, attitudeVariance, attitudeVariance,
                                     biasVariance, biasVariance, biasVariance])

        if let f = gravityAnchor, f.magnitude > 1e-6 {
            emitAnchor(time: 0, gravity: f)
        }
    }

    /// Re-arms the gravity anchor so the next at-rest sample re-establishes both the
    /// attitude and the bike axes.
    ///
    /// Call this when a calibration COMPLETES. Anchoring is otherwise one-shot per
    /// filter, so the reported angle keeps its reference from whenever the session
    /// first saw a still sample — the rider zeroes the instrument and the number does
    /// not move. Re-deriving the alignment (not just the attitude) is what makes the
    /// result exactly 0: the anchor sets `upInBody = -f.normalized` and
    /// `forwardInBody = left x up`, so forward is perpendicular to up and
    /// `AxisElevation.pitch` is identically zero. Resetting attitude alone would
    /// leave the old forward axis slightly off-perpendicular and report a small
    /// residual instead.
    ///
    /// Note this also overrides an explicitly supplied `gravityAnchor`, so only the
    /// live path should call it — replay and tests keep the alignment they were given.
    public mutating func requestReanchor() {
        hasAnchored = false
        // A re-anchor is a DECLARATION, not a measurement: it is called when a
        // calibration completes, i.e. the rider held the bike still and in doing so
        // said "this pose is level". So the near-level test is waived here — a
        // nose-down cradle is a legitimate mount, and refusing to zero it would make
        // the pill do nothing. The gate must still be open, so the pose still has to
        // be quiescent. The COLD anchor keeps the level requirement, because nobody
        // declared anything there, and that is the path a device log caught accepting
        // a 29.3 deg hand-held pose as level.
        anchorRequiresLevel = false
        diag.always(time: time ?? 0, level: .info,
                    message: "eskf requestReanchor",
                    values: ["pitchDeg": pitch * 180 / .pi])
    }

    // MARK: - Propagation

    /// Integrates one IMU sample forward. `thermalState` scales bias random walk.
    ///
    /// `dt` is taken from consecutive sample times and clamped: a gap outside the
    /// plausible range is a dropout, and it is recorded and propagated with
    /// inflated process noise rather than pretended away.
    ///
    /// `verdict` is the gate reading for THIS sample, computed once upstream. It is
    /// required, not optional: the deferred gravity anchor needs it, and a caller
    /// that cannot supply one has no business deciding that a sample represents rest.
    public mutating func propagate(_ sample: IMUSample,
                                   verdict: ValidityGate.Verdict,
                                   thermalState: Int = 0) {
        let nominalDt = 1.0 / config.nominalSampleRate
        var dt = nominalDt
        var gapFactor = 1.0

        // Tie the world frame to MEASURED gravity before integrating anything.
        // Without this the filter integrates from identity, so its "up" is merely
        // wherever the device pointed at session start: a lean and a wheelie both
        // read as positive elevation and the app cannot tell them apart.
        //
        // Deferred to the first sample that LOOKS like rest rather than the literal
        // first sample: specific force during acceleration is gravity plus thrust,
        // and anchoring to that would bake the error in permanently.
        if !hasAnchored {
            // Two conditions, and the magnitude band alone was never one of them.
            //
            // 1. The GATE must be open. It already tests the magnitude band, the
            //    rotation-rate ceiling and dwell, and it is computed once upstream —
            //    so consult it instead of reimplementing a weaker copy here.
            // 2. The pose must be NEAR-LEVEL — unless a re-anchor waived it, in which
            //    case the rider has declared this pose level (see `requestReanchor`).
            //    This is the condition the old check was structurally incapable of
            //    expressing: specific-force magnitude is orientation-INVARIANT at
            //    rest — it is g at every orientation — so it cannot reject a tilt. A
            //    device log caught a hand-held 29.3 deg pose (|f| = 9.817, squarely in
            //    band) becoming the definition of level, and the app then reported a
            //    constant -27.87 deg while standing still. At rest f ~= -g*up, so
            //    |f.z|/|f| ~ cos(tilt); 0.94 rejects tilt past ~20 deg while
            //    tolerating a generous cradle angle. Deliberately loose — the gate
            //    carries the strictness.
            let magnitude = sample.specificForce.magnitude
            let nearLevel = magnitude > 1e-6
                && abs(sample.specificForce.z) / magnitude >= config.anchorLevelCosine
            if verdict.isOpen, nearLevel || !anchorRequiresLevel {
                attitude = Quaternion.rotation(from: sample.specificForce,
                                               to: Conventions.worldGravity)
                // The same at-rest sample also fixes the bike axes. Gravity determines
                // `up` and nothing else: it cannot know which horizontal direction is
                // bike-forward, so `fromMeasuredGravity` has to guess, and the guess
                // depends on how the phone happened to be lying. Re-deriving it in
                // full on every re-anchor therefore reassigns which tilt direction
                // counts as a wheelie. A device log showed seven calibrations in one
                // session, each silently redefining that axis, which is why the
                // reported angle's sign felt arbitrary and a real tilt could read as 0.
                //
                // But leaving the axes ALONE is not the answer either: pitch is the
                // elevation of `forward`, so an old `forward` that is not perpendicular
                // to the NEW `up` leaves the pose reading its full tilt — the same log
                // has a 35 deg pose still reporting 35.0 deg after the re-zero that was
                // supposed to make it 0. `releveled(againstMeasuredGravity:)` is the
                // narrow operation this needs: take `up` from the measurement, keep the
                // forward HEADING, and re-orthogonalise. First anchor still derives the
                // heading from scratch, because there is none to keep.
                if hasDerivedAlignment {
                    alignment = alignment.releveled(
                        againstMeasuredGravity: sample.specificForce)
                } else {
                    alignment = MountAlignment.fromMeasuredGravity(
                        specificForce: sample.specificForce,
                        bikeProfileID: alignment.bikeProfileID)
                    hasDerivedAlignment = true
                }
                hasAnchored = true
                anchorRequiresLevel = true
                emitAnchor(time: sample.time, gravity: sample.specificForce)
            }
        }

        guard let previous = time else {
            // The first sample establishes the epoch and is NOT integrated: there is
            // no elapsed interval before it, and assuming one invents rotation the
            // sensor never reported.
            time = sample.time
            lastCorrectedRate = sample.rotationRate - bias
            return
        }

        let raw = sample.time - previous
        if raw <= 0 {
            return                                  // out-of-order sample: ignore
        }
        let lower = 0.5 * nominalDt
        let upper = 4.0 * nominalDt
        if raw < lower {
            dt = lower
        } else if raw > upper {
            dt = upper
            // Inflate Q in proportion to the unmodelled time, so the filter's
            // confidence reflects what it actually saw.
            gapFactor = raw / upper
        } else {
            dt = raw
        }
        time = sample.time

        let corrected = sample.rotationRate - bias
        lastCorrectedRate = corrected

        attitude = (attitude
                    * Quaternion.exp(rotationVector: corrected * dt)).normalized

        // F = [ -skew(w)  -I ]      Phi ~= I + F dt
        //     [    0       0 ]
        // The -I block is what makes bias observable at all: bias error leaks into
        // attitude error at unit rate, so any attitude measurement informs bias.
        let phi = Matrix6(topLeft: Matrix3.identity - skew(corrected) * dt,
                          topRight: Matrix3.identity * -dt,
                          bottomLeft: .zero,
                          bottomRight: .identity)

        let gyroVariance = config.gyroNoiseDensity * config.gyroNoiseDensity
                         * config.nominalSampleRate * dt * gapFactor
        let scale = config.thermalBiasNoiseScale.indices.contains(thermalState)
            ? config.thermalBiasNoiseScale[thermalState]
            : config.thermalBiasNoiseScale.last ?? 1.0
        let biasVariance = config.gyroBiasInstability * config.gyroBiasInstability
                         * dt * scale * gapFactor

        var p = Symmetric6(phi * covariance.m * phi.transposed
                           + Matrix6.diagonal([gyroVariance, gyroVariance, gyroVariance,
                                               biasVariance, biasVariance, biasVariance]))
        p.symmetrise()
        covariance = p

        // 1 Hz heartbeat: pitch deg, applied bias deg/s. Keyed on a constant so it
        // is a pure heartbeat (propagation has no categorical state of its own).
        //
        // Pitch is reported as NaN before an anchor exists. Attitude is identity
        // then, so the number is the raw device axis, not a bike angle — a device
        // log shows -89.7183 deg published 16 ms ahead of the anchor. Logging a
        // sentinel keeps the heartbeat's cadence honest without publishing a lie.
        let degrees = 180.0 / .pi
        diag.emit("propagate", time: sample.time,
                  message: "eskf heartbeat",
                  values: [
                    "pitchDeg": hasAnchored ? pitch * degrees : Double.nan,
                    "isAnchored": hasAnchored ? 1 : 0,
                    "biasXDegPerSec": bias.x * degrees,
                    "biasYDegPerSec": bias.y * degrees,
                    "biasZDegPerSec": bias.z * degrees,
                    "isDegraded": isDegraded ? 1 : 0,
                  ])
    }

    /// Emit the anchor milestone: the gravity vector that fixed the world frame
    /// and the alignment axes it derived. Never coalesced.
    private func emitAnchor(time: TimeInterval, gravity f: Vector3) {
        diag.always(time: time, level: .info,
                    message: "eskf anchor acquired",
                    values: [
                        "gravityX": f.x,
                        "gravityY": f.y,
                        "gravityZ": f.z,
                        "gravityMag": f.magnitude,
                        "forwardX": alignment.forwardInBody.x,
                        "forwardY": alignment.forwardInBody.y,
                        "forwardZ": alignment.forwardInBody.z,
                        "upX": alignment.upInBody.x,
                        "upY": alignment.upInBody.y,
                        "upZ": alignment.upInBody.z,
                    ])
    }

    // MARK: - Measurement 1: gravity

    /// Admits the accelerometer as a gravity reference — or refuses to.
    ///
    /// ## Why inflation is not enough, and this SKIPS instead
    /// The design originally said to inflate this measurement's noise ~100x during
    /// dynamics rather than dropping it, so the covariance never steps. Measurement
    /// proved that wrong, and the reason is worth stating because it is the whole
    /// premise of the product.
    ///
    /// A Kalman filter treats repeated measurements as INDEPENDENT evidence, so it
    /// integrates them: N samples of a measurement with standard deviation sigma
    /// carry the information of one measurement with sigma/sqrt(N). The
    /// accelerometer's error during acceleration is not noise, it is SYSTEMATIC —
    /// thrust of 0.3 g rotates f by a constant atan(0.3) = 16.7 degrees for as long
    /// as the throttle is open. Inflating the variance only slows the convergence
    /// onto that wrong answer; over 3000 samples at 100 Hz even a 10^4 inflation
    /// still settles on the phantom angle, which is exactly what the test
    /// `testSustainedThrustDoesNotDragTheEstimateToThePhantomAngle` measured.
    ///
    /// Variance inflation models UNCORRELATED error. It cannot express "this vector
    /// is reliably wrong in a direction that correlates with the signal". The only
    /// correct handling is not to feed it in.
    ///
    /// So the tiers are:
    ///   - gate open              -> trust it (kappa 1)
    ///   - dwell not yet met      -> conditions ARE quasi-static, just not held long
    ///                               enough, so the residual error genuinely is
    ///                               noise-like (kappa `accelNoiseInflation`)
    ///   - out of band / rotating -> SKIPPED. The direction is systematically wrong.
    ///
    /// Attitude during dynamics is then carried by the gyro, which is what "gyro is
    /// king" means operationally, and bounded by the GNSS-aided pitch measurement,
    /// which subtracts the independently-measured ground acceleration and so does not
    /// share the confound. The gate reopens at every stop, steady cruise and traffic
    /// light, so the anchor is never far away.
    ///
    /// Returns false when the measurement was skipped.
    @discardableResult
    public mutating func updateWithGravity(_ sample: IMUSample,
                                           verdict: ValidityGate.Verdict) -> Bool {
        // A saturated axis has no usable value at any weight.
        guard !sample.saturated else { return false }

        let inflation: Double
        switch verdict.reason {
        case .open:
            inflation = 1.0
        case .dwellNotMet:
            // Quasi-static but unproven. `.dwellNotMet` NO LONGER IMPLIES the
            // magnitude is in band: `Config.gateCloseConfirm` deliberately lets a
            // violation shorter than ~60 ms report `.dwellNotMet` instead of closing
            // the gate, so that engine buzz cannot reset the calibration dwell. The
            // band test therefore has to be applied here, by the consumer.
            //
            // It is applied against the GATE's band, not against
            // `accelDynamicThreshold` alone — that threshold is 0.1 g (0.981 m/s^2),
            // 3.3x looser than the gate's +/-0.03 g (0.294 m/s^2). A sustained 0.3 g
            // thrust sits at 1.044 g, i.e. 0.432 m/s^2 off gravity: outside the gate's
            // band but inside the looser one, so it passed as "quasi-static" and six
            // early updates at inflation 100 dragged a fresh filter the whole way to
            // the phantom 16.7 deg — with every later sample refused, nothing pulled
            // it back. `AttitudeESKFTests` pins exactly this.
            let magnitude = sample.specificForce.magnitude
            guard magnitude >= config.gateSpecificForceLow,
                  magnitude <= config.gateSpecificForceHigh else { return false }
            let deviation = abs(magnitude - Conventions.g)
            guard deviation <= config.accelDynamicThreshold else { return false }
            inflation = config.accelNoiseInflation
        case .specificForceOutOfBand, .rotating, .saturated, .noData:
            return false
        }

        // Predicted specific force: world gravity rotated into the body frame.
        let inverse = Quaternion(w: attitude.w, x: -attitude.x,
                                 y: -attitude.y, z: -attitude.z)
        let predicted = inverse.rotate(Conventions.worldGravity)
        let residual = sample.specificForce - predicted

        // f_B(dTheta) ~= (I - skew(dTheta)) f_hat = f_hat + skew(f_hat) dTheta
        let h = skew(predicted)

        let accelVariance = config.accelNoiseDensity * config.accelNoiseDensity
                          * config.nominalSampleRate * inflation
        return applyVectorUpdate(h: h, residual: residual, noise: accelVariance)
    }

    /// Convenience for callers that only have a boolean gate state.
    @discardableResult
    public mutating func updateWithGravity(_ sample: IMUSample,
                                           gateOpen: Bool) -> Bool {
        updateWithGravity(sample,
                          verdict: ValidityGate.Verdict(
                            isOpen: gateOpen,
                            heldFor: 0,
                            reason: gateOpen ? .open : .specificForceOutOfBand))
    }

    // MARK: - Measurement 2: GNSS-aided pitch

    /// The measurement that makes the run-up informative.
    ///
    /// The accelerometer alone cannot separate tilt from thrust. But the
    /// accelerometer PLUS an independent acceleration measurement can: the
    /// difference is the gravity projection. GNSS supplies that independent value by
    /// differentiating Doppler speed.
    ///
    ///     f_x = -g sin(theta) - a cos(theta)          (longitudinal, bike axes)
    ///     z   = -f_x - a_gnss cos(theta_hat)
    ///     h   = g sin(theta)
    ///     H   = [ g * (forward x upInBody)^T , 0 ]
    ///
    /// With speedAccuracy 0.1 m/s over a 1 s interval the acceleration sigma is
    /// sqrt(2)*0.1 = 0.141 m/s^2, about 0.8 deg of angle — a useful observation once
    /// per second, available DURING acceleration, which is exactly when the gravity
    /// anchor is not.
    ///
    /// Deliberately unavailable during an event: at 1 Hz this cannot track a 1.2 s
    /// ramp, and a Doppler difference straddling onset is meaningless. Its job is
    /// bias containment before onset.
    @discardableResult
    public mutating func updateWithGNSSPitch(longitudinalForce fx: Double,
                                             groundAcceleration a: Double,
                                             accelerationSigma: Double) -> Bool {
        let g = Conventions.g
        let inverse = Quaternion(w: attitude.w, x: -attitude.x,
                                 y: -attitude.y, z: -attitude.z)
        // World up expressed in body coordinates.
        let upInBody = inverse.rotate(Conventions.worldUp)
        let forward = alignment.forwardInBody.normalized

        // sin(theta) = ez . (R * forward) = upInBody . forward
        let sinTheta = max(-1, min(1, forward.dot(upInBody)))
        let cosTheta = max(0.05, (1 - sinTheta * sinTheta).squareRoot())

        let z = -fx - a * cosTheta
        let predicted = g * sinTheta
        let residual = z - predicted

        // d(sin theta)/d(dTheta) = -ez^T R skew(forward), which as a column is
        // skew(forward) * upInBody = forward x upInBody.
        let hVector = forward.cross(upInBody) * g

        let variance = accelerationSigma * accelerationSigma
                     + config.accelNoiseDensity * config.accelNoiseDensity
                     * config.nominalSampleRate
        let applied = applyScalarUpdate(hVector: hVector, residual: residual, noise: variance)
        if applied {
            let degrees = 180.0 / .pi
            diag.always(time: time ?? 0, level: .debug,
                        message: "eskf bias applied",
                        values: [
                            "biasXDegPerSec": bias.x * degrees,
                            "biasYDegPerSec": bias.y * degrees,
                            "biasZDegPerSec": bias.z * degrees,
                            "residual": residual,
                        ])
        }
        return applied
    }

    // MARK: - Readout

    /// Elevation of the bike's forward axis above horizontal, radians.
    public var pitch: Double {
        AxisElevation.pitch(attitude: attitude, forwardInBody: alignment.forwardInBody)
    }

    /// Roll about the bike's forward axis, radians.
    public var roll: Double {
        AxisElevation.roll(attitude: attitude,
                           forwardInBody: alignment.forwardInBody,
                           upInBody: alignment.upInBody)
    }

    /// Pitch rate, rad/s: the component of the bias-corrected body rate that
    /// actually raises the nose.
    public var pitchRate: Double {
        // Nose-up is a negative rotation about the bike's LEFT axis, so project
        // onto it and negate. Doing this through the alignment rather than the
        // device y axis is what keeps a crooked mount honest.
        -lastCorrectedRate.dot(alignment.leftInBody.normalized)
    }

    /// 1-sigma uncertainty on `pitch`, radians.
    ///
    /// Projects the attitude block of the covariance onto the direction that moves
    /// pitch, which is the same Jacobian direction the GNSS measurement uses.
    public var pitchSigma: Double {
        let inverse = Quaternion(w: attitude.w, x: -attitude.x,
                                 y: -attitude.y, z: -attitude.z)
        let upInBody = inverse.rotate(Conventions.worldUp)
        let forward = alignment.forwardInBody.normalized
        let direction = forward.cross(upInBody)
        let magnitude = direction.magnitude
        guard magnitude > 1e-9 else {
            return covariance.quadraticForm(Vector3(0, 1, 0)).squareRoot()
        }
        return covariance.quadraticForm(direction / magnitude).squareRoot()
    }

    /// 1-sigma uncertainty on each gyro bias axis, rad/s.
    public var biasSigma: Vector3 {
        Vector3(covariance[3, 3].squareRoot(),
                covariance[4, 4].squareRoot(),
                covariance[5, 5].squareRoot())
    }

    // MARK: - Shared update machinery

    /// Zeroes the yaw (Z) row of a bias-error gain block, so no measurement update
    /// ever moves `bias.z`.
    ///
    /// Yaw bias is structurally UNOBSERVABLE from gravity: an accelerometer at rest
    /// constrains the two tilt axes and says nothing about rotation about vertical.
    /// Left free, `bias.z` random-walks — a device log has it climbing monotonically
    /// to 5.05 deg/s against a measured truth of 0.111 deg/s, on a phone lying still
    /// on a desk, and still rising. That is not cosmetic: `bias` is subtracted from
    /// the measured rate and the result is integrated into attitude, so once the
    /// phone tilts, body-Z is no longer world-vertical and rotation about it acquires
    /// a component that moves forward's elevation. The pitch leak is zero at exactly
    /// level and grows as sin(tilt) — i.e. worst during the wheelie being measured.
    ///
    /// So do not estimate it: hold the calibrated value, which `BiasEstimator`
    /// measures from an 8-second mean far better than an update carrying no
    /// information about it ever could. X and Y stay fully estimated.
    private func zeroYawBiasGain(_ k2: inout Matrix3) {
        k2[2, 0] = 0
        k2[2, 1] = 0
        k2[2, 2] = 0
    }

    /// Three-dimensional update where `H = [h, 0]`, i.e. the measurement sees
    /// attitude error only. Joseph form throughout.
    private mutating func applyVectorUpdate(h: Matrix3,
                                            residual: Vector3,
                                            noise: Double) -> Bool {
        let p11 = covariance.m.block(row: 0, col: 0)
        let p21 = covariance.m.block(row: 3, col: 0)
        let hT = h.transposed

        // S = H P H^T + R
        let s = h * p11 * hT + Matrix3.identity * noise
        guard let sInverse = s.inverted() else {
            isDegraded = true
            return false
        }

        // K = P H^T S^-1, in two 3x3 blocks because H's right half is zero.
        let k1 = p11 * hT * sInverse
        var k2 = p21 * hT * sInverse
        zeroYawBiasGain(&k2)

        // Inject the correction and reset the error state to zero.
        let deltaTheta = k1 * residual
        let deltaBias = k2 * residual
        attitude = (attitude * Quaternion.exp(rotationVector: deltaTheta)).normalized
        bias = bias + deltaBias

        // P = (I - KH) P (I - KH)^T + K R K^T
        let kh = Matrix6(topLeft: k1 * h, topRight: .zero,
                         bottomLeft: k2 * h, bottomRight: .zero)
        let imkh = Matrix6.identity - kh
        let krkT = Matrix6(topLeft: k1 * k1.transposed * noise,
                           topRight: k1 * k2.transposed * noise,
                           bottomLeft: k2 * k1.transposed * noise,
                           bottomRight: k2 * k2.transposed * noise)

        var p = Symmetric6(imkh * covariance.m * imkh.transposed + krkT)
        p.symmetrise()
        guard p.cholesky() != nil else {
            isDegraded = true
            return false
        }
        covariance = p
        return true
    }

    /// Scalar update where `H = [hVector^T, 0]`. The gain is rank one, so the
    /// covariance update is built from outer products.
    private mutating func applyScalarUpdate(hVector: Vector3,
                                            residual: Double,
                                            noise: Double) -> Bool {
        let p11 = covariance.m.block(row: 0, col: 0)
        let p21 = covariance.m.block(row: 3, col: 0)

        let s = covariance.quadraticForm(hVector) + noise
        guard s > 1e-15 else { return false }

        let k1 = (p11 * hVector) / s
        var k2 = (p21 * hVector) / s
        // Yaw bias is unobservable — see `zeroYawBiasGain`. Here the gain block is
        // already a Vector3, so the projection is exact and trivial.
        k2.z = 0

        attitude = (attitude * Quaternion.exp(rotationVector: k1 * residual)).normalized
        bias = bias + k2 * residual

        let kh = Matrix6(topLeft: Matrix3.outer(k1, hVector), topRight: .zero,
                         bottomLeft: Matrix3.outer(k2, hVector), bottomRight: .zero)
        let imkh = Matrix6.identity - kh
        let krkT = Matrix6(topLeft: Matrix3.outer(k1, k1) * noise,
                           topRight: Matrix3.outer(k1, k2) * noise,
                           bottomLeft: Matrix3.outer(k2, k1) * noise,
                           bottomRight: Matrix3.outer(k2, k2) * noise)

        var p = Symmetric6(imkh * covariance.m * imkh.transposed + krkT)
        p.symmetrise()
        guard p.cholesky() != nil else {
            isDegraded = true
            return false
        }
        covariance = p
        return true
    }

    // MARK: - State transfer, for the delayed-state ring and the smoother

    /// A complete snapshot of the filter, so a state can be rewound, updated in the
    /// past, and re-propagated forward.
    public struct Snapshot: Sendable {
        public var time: TimeInterval
        public var attitude: Quaternion
        public var bias: Vector3
        public var covariance: Symmetric6
        /// RAW measured rate at this sample. Stored un-corrected on purpose:
        /// re-propagation happens after the bias has changed, so the correction must
        /// be re-applied with the new bias rather than baked in.
        public var measuredRate: Vector3
        public var specificForce: Vector3
        public var saturated: Bool
        public var gateOpen: Bool
        /// Kept alongside `gateOpen` so re-propagation reproduces the ORIGINAL
        /// inflation tier. Collapsing it to a boolean would silently re-weight
        /// history and make replay disagree with the live run.
        public var gateReason: ValidityGate.Reason
    }

    public func snapshot(measuredRate: Vector3,
                         specificForce: Vector3,
                         saturated: Bool,
                         gateOpen: Bool,
                         gateReason: ValidityGate.Reason = .specificForceOutOfBand) -> Snapshot {
        Snapshot(time: time ?? 0,
                 attitude: attitude,
                 bias: bias,
                 covariance: covariance,
                 measuredRate: measuredRate,
                 specificForce: specificForce,
                 saturated: saturated,
                 gateOpen: gateOpen,
                 gateReason: gateReason)
    }

    public mutating func restore(_ snapshot: Snapshot) {
        time = snapshot.time
        attitude = snapshot.attitude
        bias = snapshot.bias
        covariance = snapshot.covariance
    }
}
