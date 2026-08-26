import CoreMotion
import Foundation
import MotoTelemetryCore
import os

// MARK: - Protocol

/// Delivers a stream of `Sample.imu` from device motion hardware.
public protocol MotionProviding: Sendable {
    var samples: AsyncStream<Sample> { get }
    func start()
    func stop()
}

// MARK: - Implementation

/// Fuses CMMotionManager gyro + accelerometer callbacks at 100 Hz and emits
/// paired `IMUSample` values. Also subscribes to `deviceMotion` to capture
/// Apple's fused attitude for comparison logging.
///
/// Pairing: raw gyro and accel arrive on separate callbacks. We match by nearest
/// timestamp within a 5 ms tolerance window. Unpaired samples are zero-filled on
/// the missing axis and the `unpairedCount` counter is incremented.
public final class MotionService: MotionProviding, @unchecked Sendable {

    // MARK: - Public

    public let samples: AsyncStream<Sample>

    // MARK: - Diagnostics

    public private(set) var unpairedCount: Int = 0

    // MARK: - Private

    private let continuation: AsyncStream<Sample>.Continuation
    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private let config: Config
    private let log = Logger(subsystem: "com.mototelemetry.app", category: "MotionService")

    /// Tolerance for timestamp pairing (seconds).
    private let pairTolerance: TimeInterval = 0.005

    /// Pending samples awaiting a pair.
    private var pendingGyro: (time: TimeInterval, rate: Vector3)?
    private var pendingAccel: (time: TimeInterval, force: Vector3)?
    private var latestAttitude: Quaternion?

    /// Lock protecting pairing state. OperationQueue serializes per-handler but
    /// gyro and accel handlers may interleave on the same queue.
    private let lock = NSLock()

    // MARK: - Init

    public init(config: Config = Config()) {
        self.config = config
        var cont: AsyncStream<Sample>.Continuation!
        self.samples = AsyncStream { cont = $0 }
        self.continuation = cont

        queue.name = "com.mototelemetry.motion"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
    }

    // MARK: - Lifecycle

    public func start() {
        let interval = 1.0 / config.nominalSampleRate

        // Gyroscope
        guard manager.isGyroAvailable else {
            log.error("Gyroscope unavailable")
            return
        }
        manager.gyroUpdateInterval = interval
        manager.startGyroUpdates(to: queue) { [weak self] data, error in
            guard let self, let data else {
                if let error { self?.log.error("Gyro error: \(error.localizedDescription)") }
                return
            }
            let rate = Vector3(data.rotationRate.x,
                               data.rotationRate.y,
                               data.rotationRate.z)
            self.receive(gyro: rate, at: data.timestamp)
        }

        // Accelerometer
        guard manager.isAccelerometerAvailable else {
            log.error("Accelerometer unavailable")
            return
        }
        manager.accelerometerUpdateInterval = interval
        manager.startAccelerometerUpdates(to: queue) { [weak self] data, error in
            guard let self, let data else {
                if let error { self?.log.error("Accel error: \(error.localizedDescription)") }
                return
            }
            // CoreMotion reports in g; convert to m/s^2
            let force = Vector3(data.acceleration.x * 9.80665,
                                data.acceleration.y * 9.80665,
                                data.acceleration.z * 9.80665)
            self.receive(accel: force, at: data.timestamp)
        }

        // Device motion — attitude only, for comparison logging
        if manager.isDeviceMotionAvailable {
            manager.deviceMotionUpdateInterval = interval
            manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] motion, _ in
                guard let self, let motion else { return }
                let q = motion.attitude.quaternion
                self.lock.lock()
                self.latestAttitude = Quaternion(w: q.w, x: q.x, y: q.y, z: q.z)
                self.lock.unlock()
            }
        }

        log.info("MotionService started at \(self.config.nominalSampleRate) Hz")
    }

    public func stop() {
        manager.stopGyroUpdates()
        manager.stopAccelerometerUpdates()
        manager.stopDeviceMotionUpdates()
        continuation.finish()
        log.info("MotionService stopped. Unpaired samples: \(self.unpairedCount)")
    }

    // MARK: - Pairing

    private func receive(gyro rate: Vector3, at time: TimeInterval) {
        lock.lock()
        if let accel = pendingAccel, abs(accel.time - time) <= pairTolerance {
            // Pair found
            pendingAccel = nil
            let attitude = latestAttitude
            lock.unlock()
            emit(time: time, rate: rate, force: accel.force, attitude: attitude)
        } else {
            // Stash; if there was already a pending gyro, flush it zero-filled
            if let stale = pendingGyro {
                let attitude = latestAttitude
                lock.unlock()
                unpairedCount += 1
                emit(time: stale.time, rate: stale.rate,
                     force: .zero, attitude: attitude)
                lock.lock()
            }
            pendingGyro = (time, rate)
            lock.unlock()
        }
    }

    private func receive(accel force: Vector3, at time: TimeInterval) {
        lock.lock()
        if let gyro = pendingGyro, abs(gyro.time - time) <= pairTolerance {
            pendingGyro = nil
            let attitude = latestAttitude
            lock.unlock()
            emit(time: time, rate: gyro.rate, force: force, attitude: attitude)
        } else {
            if let stale = pendingAccel {
                let attitude = latestAttitude
                lock.unlock()
                unpairedCount += 1
                emit(time: stale.time, rate: .zero,
                     force: stale.force, attitude: attitude)
                lock.lock()
            }
            pendingAccel = (time, force)
            lock.unlock()
        }
    }

    // MARK: - Emit

    private func emit(time: TimeInterval, rate: Vector3, force: Vector3,
                      attitude: Quaternion?) {
        let saturated = isSaturated(rate: rate, force: force)
        let sample = IMUSample(
            time: time,
            rotationRate: rate,
            specificForce: force,
            fusedAttitude: attitude,
            saturated: saturated
        )
        continuation.yield(.imu(sample))
    }

    private func isSaturated(rate: Vector3, force: Vector3) -> Bool {
        let gyroLimit = config.gyroFullScale * 0.99
        let accelLimit = config.accelFullScale * 0.99
        return abs(rate.x) >= gyroLimit || abs(rate.y) >= gyroLimit || abs(rate.z) >= gyroLimit
            || abs(force.x) >= accelLimit || abs(force.y) >= accelLimit || abs(force.z) >= accelLimit
    }
}
