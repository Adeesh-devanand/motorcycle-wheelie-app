import Foundation

/// One tagged, timestamped measurement. Every source — live CoreMotion, a
/// replayed log file, the synthetic generator, and later a BLE sensor or our
/// own board — emits this single type into one time-ordered stream.
///
/// `time` is always a MONOTONIC clock in seconds. Never wall-clock: wall-clock
/// jumps and the pipeline must be replayable bit-for-bit.
public enum Measurement: Codable, Sendable {
    case imu(IMUSample)
    case gnss(GNSSFix)
    case baro(BaroSample)
    case wheelSpeed(WheelSpeedSample)

    public var time: TimeInterval {
        switch self {
        case .imu(let s):        return s.time
        case .gnss(let s):       return s.fixTime
        case .baro(let s):       return s.time
        case .wheelSpeed(let s): return s.time
        }
    }
}

public struct IMUSample: Codable, Sendable {
    public var time: TimeInterval
    /// Angular rate, body frame, rad/s. RAW — factory-trimmed but not
    /// bias-corrected by us or by Apple's fusion.
    public var rotationRate: Vector3
    /// Specific force, body frame, m/s^2. This is gravity PLUS linear
    /// acceleration and cannot be decomposed without another measurement.
    public var specificForce: Vector3
    /// Apple's fused attitude when available. Kept for comparison only —
    /// do NOT use as the event-time estimate (its fusion assumes the
    /// long-run mean of specificForce is gravity, which is false for the
    /// entire duration of a wheelie).
    public var fusedAttitude: Quaternion?
    /// True when any axis hit the sensor's full-scale range. Saturated
    /// samples must never enter the gravity anchor.
    public var saturated: Bool

    public init(time: TimeInterval,
                rotationRate: Vector3,
                specificForce: Vector3,
                fusedAttitude: Quaternion? = nil,
                saturated: Bool = false) {
        self.time = time
        self.rotationRate = rotationRate
        self.specificForce = specificForce
        self.fusedAttitude = fusedAttitude
        self.saturated = saturated
    }
}

public struct GNSSFix: Codable, Sendable {
    /// When the fix is FOR. Replay orders on this.
    public var fixTime: TimeInterval
    /// When we were handed it. Differs from fixTime by a few hundred ms;
    /// logged so latency is measurable rather than assumed.
    public var arrivalTime: TimeInterval
    /// Doppler-derived ground speed, m/s. Negative means invalid.
    public var speed: Double
    /// 95% confidence on speed, m/s. Negative means unknown.
    public var speedAccuracy: Double
    /// Course over ground, degrees. Negative means invalid.
    public var course: Double
    public var courseAccuracy: Double
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double
    public var horizontalAccuracy: Double

    public init(fixTime: TimeInterval, arrivalTime: TimeInterval,
                speed: Double, speedAccuracy: Double,
                course: Double = -1, courseAccuracy: Double = -1,
                latitude: Double = 0, longitude: Double = 0,
                altitude: Double = 0, horizontalAccuracy: Double = -1) {
        self.fixTime = fixTime; self.arrivalTime = arrivalTime
        self.speed = speed; self.speedAccuracy = speedAccuracy
        self.course = course; self.courseAccuracy = courseAccuracy
        self.latitude = latitude; self.longitude = longitude
        self.altitude = altitude; self.horizontalAccuracy = horizontalAccuracy
    }

    public var isSpeedValid: Bool { speed >= 0 }
}

public struct BaroSample: Codable, Sendable {
    public var time: TimeInterval
    /// Metres relative to session start.
    public var relativeAltitude: Double
    /// kPa.
    public var pressure: Double

    public init(time: TimeInterval, relativeAltitude: Double, pressure: Double) {
        self.time = time
        self.relativeAltitude = relativeAltitude
        self.pressure = pressure
    }

    /// Dynamic-pressure correction. A port on a moving bike sees 1/2*rho*v^2,
    /// which reads as phantom altitude: ~1 m at 50 km/h, ~4 m at 100 km/h,
    /// ~9 m at 150 km/h. Uncorrected the app reports downhill every time you
    /// accelerate. `k` is calibrated once per mounting position.
    public func correctedAltitude(speed: Double, k: Double) -> Double {
        relativeAltitude - k * speed * speed
    }
}

/// BLE Cycling Speed & Cadence (CSC) profile, front wheel. Event-based:
/// the sensor reports cumulative revolutions, not instantaneous speed.
public struct WheelSpeedSample: Codable, Sendable {
    public var time: TimeInterval
    public var cumulativeRevolutions: UInt32
    /// Sensor's own event timestamp, 1/1024 s units per the CSC spec.
    public var lastEventTime: Double
    /// Metres. Measure it; don't trust the tyre's sidewall number.
    public var wheelCircumference: Double

    public init(time: TimeInterval, cumulativeRevolutions: UInt32,
                lastEventTime: Double, wheelCircumference: Double) {
        self.time = time
        self.cumulativeRevolutions = cumulativeRevolutions
        self.lastEventTime = lastEventTime
        self.wheelCircumference = wheelCircumference
    }
}
