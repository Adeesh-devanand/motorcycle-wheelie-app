import Foundation

/// Generates a wheelie with KNOWN ground truth, then corrupts it on purpose.
///
/// This is how correctness gets tested without a motorcycle: assert the
/// pipeline recovers the truth within tolerance despite injected vibration,
/// gyro bias, and road grade. Real rides test realism; synthetic tests
/// correctness, and only synthetic gives you a regression suite that fails
/// loudly when the gate breaks.
public struct SyntheticSource: MeasurementSource {
    public struct Scenario: Sendable {
        public var sampleRate: Double = 100.0
        public var duration: TimeInterval = 20.0
        /// Wheelie starts here, ramps to peak, holds, then comes down.
        public var eventStart: TimeInterval = 6.0
        public var rampDuration: TimeInterval = 1.2
        public var holdDuration: TimeInterval = 6.0
        public var peakPitch: Double = 45.0 * .pi / 180
        /// Constant road grade, radians. The pipeline must remove this.
        public var roadGrade: Double = 0.0
        /// Constant gyro bias, rad/s. The pipeline must estimate this.
        public var gyroBias: Vector3 = .zero
        /// Engine vibration injected into specific force, m/s^2 amplitude.
        public var vibrationAmplitude: Double = 0.0
        /// Engine vibration frequency, Hz. Try 83 (5000 rpm twin) and 100
        /// (6000 rpm, which aliases straight to DC at a 100 Hz sample rate).
        public var vibrationFrequency: Double = 83.0
        public var emitGNSS: Bool = true
        public var gnssRate: Double = 1.0

        /// Rotation from bike axes into DEVICE axes, i.e. a crooked mount.
        /// Identity means the phone is perfectly aligned with the bike. Every
        /// emitted vector is rotated by this, so the alignment solver has
        /// something real to recover and the estimator can be tested against a
        /// mount that is not axis-aligned.
        public var mountRotation: Quaternion = .identity

        public init() {}
    }

    public let scenario: Scenario
    private var index: Int = 0
    private var nextGNSSTime: TimeInterval = 0
    private var pendingGNSS: GNSSFix?

    public init(scenario: Scenario = Scenario()) {
        self.scenario = scenario
    }

    /// Ground-truth pitch at time t, radians. Tests compare against this.
    public func truePitch(at t: TimeInterval) -> Double {
        let s = scenario
        let rampEnd = s.eventStart + s.rampDuration
        let holdEnd = rampEnd + s.holdDuration
        let downEnd = holdEnd + s.rampDuration

        if t < s.eventStart { return 0 }
        if t < rampEnd {
            let u = (t - s.eventStart) / s.rampDuration
            return s.peakPitch * smoothstep(u)
        }
        if t < holdEnd { return s.peakPitch }
        if t < downEnd {
            let u = (t - holdEnd) / s.rampDuration
            return s.peakPitch * (1 - smoothstep(u))
        }
        return 0
    }

    public func truePitchRate(at t: TimeInterval) -> Double {
        let h = 1.0 / scenario.sampleRate
        return (truePitch(at: t + h) - truePitch(at: t - h)) / (2 * h)
    }

    public mutating func next() -> Sample? {
        if let fix = pendingGNSS {
            pendingGNSS = nil
            return .gnss(fix)
        }

        let dt = 1.0 / scenario.sampleRate
        let t = Double(index) * dt
        guard t <= scenario.duration else { return nil }
        index += 1

        let pitch = truePitch(at: t) + scenario.roadGrade
        let rate = truePitchRate(at: t)

        // Sustained wheelie needs thrust ~ g*tan(theta) — which is exactly why
        // acceleration and pitch are almost perfectly correlated and the
        // accelerometer alone is systematically confounded here.
        let g = Conventions.g
        let longitudinal = g * tan(min(pitch, 60 * .pi / 180))

        // Specific force in the body frame, per Conventions.specificForce:
        //   f = ( -g sin(theta) - a cos(theta), 0, -g cos(theta) + a sin(theta) )
        // The signs here are NOT free. This generator originally emitted
        //   fx = +a cos(theta) + g sin(theta)
        //   fz = -a sin(theta) - g cos(theta)
        // which is an aerospace-style frame (nose-up positive about +Y, Z down)
        // and contradicts the Z-up convention that AxisElevation and its passing
        // test encode. Nothing caught it: the validity gate only tests |f|, which
        // is 1.000 g either way, and the naive-tilt test uses atan2(fx, -fz),
        // which is sign-symmetric. An estimator built to the old signs would
        // report NEGATIVE angles for real wheelies. See Conventions.swift and
        // ConventionTests.
        var f = Conventions.specificForce(pitch: pitch,
                                          forwardAcceleration: longitudinal)
        var fx = f.x
        var fz = f.z

        if scenario.vibrationAmplitude > 0 {
            let phase = 2 * .pi * scenario.vibrationFrequency * t
            fx += scenario.vibrationAmplitude * sin(phase)
            fz += scenario.vibrationAmplitude * sin(phase + 1.1)
        }
        f = Vector3(fx, 0, fz)

        // A crooked mount rotates every measured vector out of bike axes into
        // device axes. Both channels get the same rotation, which is what makes
        // the alignment recoverable at all.
        let bikeRate = Conventions.rotationRate(pitchRate: rate)
        let mount = scenario.mountRotation
        let measuredRate = mount.rotate(bikeRate) + scenario.gyroBias
        let measuredForce = mount.rotate(f)

        let imu = IMUSample(
            time: t,
            rotationRate: measuredRate,
            specificForce: measuredForce
        )

        if scenario.emitGNSS, t >= nextGNSSTime {
            nextGNSSTime = t + 1.0 / scenario.gnssRate
            // Crude: integrate longitudinal accel for a plausible speed.
            let speed = 12.0 + longitudinal * 0.5
            pendingGNSS = GNSSFix(fixTime: t, arrivalTime: t + 0.25,
                                  speed: speed, speedAccuracy: 0.3)
        }

        return .imu(imu)
    }

    private func smoothstep(_ u: Double) -> Double {
        let x = max(0, min(1, u))
        return x * x * (3 - 2 * x)
    }
}
