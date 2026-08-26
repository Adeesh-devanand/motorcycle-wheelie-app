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
    private let alignment: MountAlignment

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
                initialAttitudeSigma: Double = 5.0 * .pi / 180) {
        self.config = config
        self.alignment = alignment
        self.bias = initialBias?.bias ?? .zero

        if let f = gravityAnchor, f.magnitude > 1e-6 {
            // Specific force points ALONG gravity, so f in body corresponds to
            // (0,0,-1) in world. Rotate body -> world accordingly.
            self.attitude = Quaternion.rotation(from: f, to: Conventions.worldGravity)
        } else {
            self.attitude = .identity
        }

        // Bias variance comes from the calibration that produced it: a filter told
        // its bias is perfect will never correct it.
        let biasSigma = initialBias?.worstSigma ?? (1.0 * .pi / 180)
        let attitudeVariance = initialAttitudeSigma * initialAttitudeSigma
        let biasVariance = biasSigma * biasSigma
        self.covariance = .diagonal([attitudeVariance, attitudeVariance, attitudeVariance,
                                     biasVariance, biasVariance, biasVariance])
    }

    // MARK: - Propagation

    /// Integrates one IMU sample forward. `thermalState` scales bias random walk.
    ///
    /// `dt` is taken from consecutive sample times and clamped: a gap outside the
    /// plausible range is a dropout, and it is recorded and propagated with
    /// inflated process noise rather than pretended away.
    public mutating func propagate(_ sample: IMUSample, thermalState: Int = 0) {
        let nominalDt = 1.0 / config.nominalSampleRate
        var dt = nominalDt
        var gapFactor = 1.0

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
            // Quasi-static but unproven. Still refuse if the magnitude says real
            // acceleration is present, since then the error is systematic again.
            let deviation = abs(sample.specificForce.magnitude - Conventions.g)
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
        return applyScalarUpdate(hVector: hVector, residual: residual, noise: variance)
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
        let k2 = p21 * hT * sInverse

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
        let k2 = (p21 * hVector) / s

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
