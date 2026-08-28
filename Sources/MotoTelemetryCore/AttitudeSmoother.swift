import Foundation

/// The post-ride Rauch-Tung-Striebel smoother: a forward pass and a backward pass,
/// so information available AFTER an event corrects the event itself.
///
/// ## Why this produces a better number than the live filter
/// During a wheelie the accelerometer is systematically useless, so attitude is
/// carried by the gyro from whatever it knew at onset. The live filter can only ever
/// use the past. But when the wheel comes down the gate reopens and a run of clean
/// gravity measurements pins attitude and bias tightly — and that information is
/// about the same gyro bias that was corrupting the estimate five seconds earlier.
/// The backward pass carries it back through the event. This is the number that goes
/// on a leaderboard.
///
/// ## Why the error state needs care here
/// The forward filter resets its error state to zero after every update, so every
/// stored `dx(k|k)` is identically zero. Feeding those into the textbook RTS
/// recursion `dx(k|N) = C dx(k+1|N)` yields zero corrections everywhere — a smoother
/// that does nothing, very convincingly. The fix is to run the recursion on the
/// DISCREPANCY between nominal trajectories rather than on the reset error:
///
///     d(k+1)   = smoothed(k+1)  boxminus  predicted(k+1)
///     d(k|N)   = C(k) * d(k+1)
///     smoothed(k) = updated(k)  boxplus   d(k|N)
///
/// where boxminus takes a quaternion logarithm for the attitude part. The predicted
/// state at k+1 is a deterministic function of the updated state at k, so this
/// discrepancy is real and non-zero, and it is what actually transports the landing's
/// information backwards.
public struct AttitudeSmoother {

    /// One recorded sample of the forward pass.
    public struct Input: Sendable {
        public var time: TimeInterval
        /// RAW measured rate. Stored un-corrected because the backward pass
        /// re-derives predictions with different bias values.
        public var rotationRate: Vector3
        public var specificForce: Vector3
        public var saturated: Bool
        public var verdict: ValidityGate.Verdict

        public init(time: TimeInterval,
                    rotationRate: Vector3,
                    specificForce: Vector3,
                    saturated: Bool,
                    verdict: ValidityGate.Verdict) {
            self.time = time
            self.rotationRate = rotationRate
            self.specificForce = specificForce
            self.saturated = saturated
            self.verdict = verdict
        }
    }

    public struct Output: Sendable, Equatable {
        public var time: TimeInterval
        public var attitude: Quaternion
        public var bias: Vector3
        /// Grade-uncorrected axis elevation, radians.
        public var pitch: Double
        /// 1-sigma on pitch after smoothing, radians. Strictly smaller than the
        /// forward filter's, which is the whole point.
        public var pitchSigma: Double
    }

    public enum Failure: Error, Equatable {
        /// Not enough gate-open samples AFTER the event for the backward pass to
        /// carry anything useful. Reported rather than smoothed against nothing.
        case insufficientPostEventAnchor(found: Int, required: Int)
        case tooFewSamples(Int)
        /// The covariance lost positive-definiteness, so C(k) cannot be formed.
        case notPositiveDefinite(atIndex: Int)
    }

    /// Per-sample forward-pass storage. 47 doubles = 376 bytes.
    ///
    /// Phi(k) and P(k+1|k) are NOT stored: both are deterministic functions of the
    /// stored rate, dt and P(k|k), so recomputing them in the backward pass trades a
    /// few microseconds for a third of the memory. On a whole 30-minute session that
    /// is the difference between ~34 MB and ~75 MB of transient allocation — which is
    /// why the smoother is windowed per event anyway (see `smooth(window:)`).
    private struct Recorded {
        var time: TimeInterval
        var rate: Vector3              // raw
        var dt: Double
        var attitude: Quaternion       // q(k|k)
        var bias: Vector3              // b(k|k)
        var covariance: Symmetric6     // P(k|k)
    }

    private let config: Config
    private let alignment: MountAlignment

    public init(config: Config, alignment: MountAlignment) {
        self.config = config
        self.alignment = alignment
    }

    /// Smooths a window of samples. The caller is expected to pass an event plus
    /// `Config.smootherWindowMargin` either side, not a whole session.
    ///
    /// `eventEnd` is used only to count the post-event gravity anchor; pass nil to
    /// skip that check (used by tests and by whole-window smoothing).
    public func smooth(window samples: [Input],
                       eventEnd: TimeInterval? = nil,
                       initialBias: BiasEstimate?,
                       thermalState: Int = 0) -> Result<[Output], Failure> {
        guard samples.count >= 3 else {
            return .failure(.tooFewSamples(samples.count))
        }

        if let end = eventEnd {
            let anchor = samples.filter { $0.time > end && $0.verdict.isOpen }.count
            guard anchor >= config.smootherMinAnchorSamples else {
                return .failure(.insufficientPostEventAnchor(
                    found: anchor, required: config.smootherMinAnchorSamples))
            }
        }

        // MARK: Forward pass

        var filter = AttitudeESKF(config: config,
                                  alignment: alignment,
                                  initialBias: initialBias,
                                  gravityAnchor: samples.first(where: { $0.verdict.isOpen })?
                                                        .specificForce
                                                 ?? samples[0].specificForce)
        var recorded: [Recorded] = []
        recorded.reserveCapacity(samples.count)

        var previousTime: TimeInterval?
        for sample in samples {
            let imu = IMUSample(time: sample.time,
                               rotationRate: sample.rotationRate,
                               specificForce: sample.specificForce,
                               saturated: sample.saturated)
            filter.propagate(imu, verdict: sample.verdict, thermalState: thermalState)
            filter.updateWithGravity(imu, verdict: sample.verdict)

            let dt = previousTime.map { sample.time - $0 } ?? (1.0 / config.nominalSampleRate)
            previousTime = sample.time

            recorded.append(Recorded(time: sample.time,
                                     rate: sample.rotationRate,
                                     dt: max(dt, 1e-9),
                                     attitude: filter.attitude,
                                     bias: filter.bias,
                                     covariance: filter.covariance))
        }

        // MARK: Backward pass

        var smoothedAttitude = [Quaternion](repeating: .identity, count: recorded.count)
        var smoothedBias = [Vector3](repeating: .zero, count: recorded.count)
        var smoothedCovariance = [Symmetric6](repeating: Symmetric6(.identity),
                                             count: recorded.count)

        // The last sample's smoothed estimate IS its filtered estimate: there is no
        // future information beyond the end of the window.
        let last = recorded.count - 1
        smoothedAttitude[last] = recorded[last].attitude
        smoothedBias[last] = recorded[last].bias
        smoothedCovariance[last] = recorded[last].covariance

        var index = last - 1
        while index >= 0 {
            let here = recorded[index]
            let next = recorded[index + 1]

            // Recompute Phi(k) and P(k+1|k) from what was stored.
            let corrected = next.rate - here.bias
            let dt = next.dt
            let phi = Matrix6(topLeft: Matrix3.identity - skew(corrected) * dt,
                              topRight: Matrix3.identity * -dt,
                              bottomLeft: .zero,
                              bottomRight: .identity)

            let gyroVariance = config.gyroNoiseDensity * config.gyroNoiseDensity
                             * config.nominalSampleRate * dt
            let scale = config.thermalBiasNoiseScale.indices.contains(thermalState)
                ? config.thermalBiasNoiseScale[thermalState]
                : config.thermalBiasNoiseScale.last ?? 1.0
            let biasVariance = config.gyroBiasInstability * config.gyroBiasInstability
                             * dt * scale
            var predicted = Symmetric6(
                phi * here.covariance.m * phi.transposed
                + Matrix6.diagonal([gyroVariance, gyroVariance, gyroVariance,
                                    biasVariance, biasVariance, biasVariance]))
            predicted.symmetrise()

            // C(k) = P(k|k) Phi^T P(k+1|k)^-1, computed by solving rather than
            // inverting: an explicit inverse of a near-singular covariance amplifies
            // error and destroys the symmetry the next step depends on.
            guard let solved = predicted.solve(phi * here.covariance.m) else {
                return .failure(.notPositiveDefinite(atIndex: index))
            }
            // solve gives P(k+1|k)^-1 * (Phi P(k|k)); transpose to get
            // P(k|k) Phi^T P(k+1|k)^-1 since P(k|k) and P(k+1|k) are symmetric.
            let c = solved.transposed

            // The predicted NOMINAL at k+1, from the updated nominal at k.
            let predictedAttitude = (here.attitude
                * Quaternion.exp(rotationVector: corrected * dt)).normalized
            let predictedBias = here.bias

            // d(k+1) = smoothed(k+1) boxminus predicted(k+1)
            let attitudeDiscrepancy =
                (predictedAttitude.conjugate * smoothedAttitude[index + 1]).log
            let biasDiscrepancy = smoothedBias[index + 1] - predictedBias

            // d(k|N) = C(k) d(k+1)
            let d = Matrix6.apply(c, attitudeDiscrepancy, biasDiscrepancy)

            smoothedAttitude[index] = (here.attitude
                * Quaternion.exp(rotationVector: d.top)).normalized
            smoothedBias[index] = here.bias + d.bottom

            // P(k|N) = P(k|k) + C (P(k+1|N) - P(k+1|k)) C^T
            let difference = smoothedCovariance[index + 1].m - predicted.m
            var updated = Symmetric6(here.covariance.m + c * difference * c.transposed)
            updated.symmetrise()
            smoothedCovariance[index] = updated

            index -= 1
        }

        // MARK: Readout

        var out: [Output] = []
        out.reserveCapacity(recorded.count)
        for i in 0..<recorded.count {
            let attitude = smoothedAttitude[i]
            let pitch = AxisElevation.pitch(attitude: attitude,
                                           forwardInBody: alignment.forwardInBody)
            // Project the attitude covariance onto the direction that moves pitch.
            let upInBody = attitude.conjugate.rotate(Conventions.worldUp)
            let direction = alignment.forwardInBody.normalized.cross(upInBody)
            let magnitude = direction.magnitude
            let sigma = magnitude > 1e-9
                ? smoothedCovariance[i].quadraticForm(direction / magnitude).squareRoot()
                : smoothedCovariance[i].quadraticForm(Vector3(0, 1, 0)).squareRoot()

            out.append(Output(time: recorded[i].time,
                              attitude: attitude,
                              bias: smoothedBias[i],
                              pitch: pitch,
                              pitchSigma: sigma))
        }
        return .success(out)
    }

    /// Memory footprint per stored sample, in bytes. Exposed so the windowing
    /// decision can be checked against a number rather than an assumption.
    ///
    /// `MemoryLayout<Recorded>.stride` is NOT the answer and reports about 104 bytes:
    /// `Matrix6` holds its 36 elements in a `[Double]`, so the struct contains an
    /// 8-byte pointer and the real storage lives on the heap. The figure below counts
    /// that properly.
    ///
    /// Worth noting separately, because it bites elsewhere: that same boxing means
    /// every `Matrix6` and `Symmetric6` operation allocates. In this smoother, which
    /// runs once post-ride, that is irrelevant. In the live filter at 100 Hz it is
    /// allocation churn in the hot path, and it is the first thing to look at if
    /// T3.11's on-device budget is missed - a fixed-size inline representation would
    /// remove it.
    public static var bytesPerSample: Int {
        let inlineFields = MemoryLayout<TimeInterval>.size      // time
                         + MemoryLayout<Vector3>.size           // rate
                         + MemoryLayout<Double>.size            // dt
                         + MemoryLayout<Quaternion>.size        // attitude
                         + MemoryLayout<Vector3>.size           // bias
        // The covariance's 36 doubles plus Swift array header/capacity overhead.
        let heapCovariance = 36 * MemoryLayout<Double>.size + 32
        return inlineFields + heapCovariance
    }
}

extension Matrix6 {
    /// Applies a 6x6 to a 6-vector expressed as two 3-vectors.
    static func apply(_ m: Matrix6, _ top: Vector3, _ bottom: Vector3)
        -> (top: Vector3, bottom: Vector3) {
        let v = [top.x, top.y, top.z, bottom.x, bottom.y, bottom.z]
        var out = [Double](repeating: 0, count: 6)
        for i in 0..<6 {
            var s = 0.0
            for j in 0..<6 { s += m[i, j] * v[j] }
            out[i] = s
        }
        return (Vector3(out[0], out[1], out[2]), Vector3(out[3], out[4], out[5]))
    }
}
