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

    /// Recreated by `start()`. It cannot be a `let`: cancelling the consuming Task
    /// (which `RunRecorder.stopSession` does) puts an `AsyncStream` into a TERMINAL
    /// state, after which every `yield` is silently discarded forever. Not calling
    /// `continuation.finish()` in `stop()` is therefore not enough — a restarted
    /// session must be handed a brand-new stream or it receives nothing at all, which
    /// showed up as a frozen angle after leaving the Live tab and returning.
    public private(set) var samples: AsyncStream<Sample>

    // MARK: - Diagnostics

    public private(set) var unpairedCount: Int = 0

    // MARK: - Private

    private var continuation: AsyncStream<Sample>.Continuation
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
        // Hand this session a fresh stream. The previous one is terminal once its
        // consumer Task was cancelled, so reusing it would deliver nothing. Safe to do
        // here because `RunRecorder.startSession` calls `start()` BEFORE it subscribes.
        continuation.finish()
        var cont: AsyncStream<Sample>.Continuation!
        samples = AsyncStream { cont = $0 }
        continuation = cont

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
        // Deliberately NOT calling `continuation.finish()`. The stream and its
        // continuation are created once in `init`, so finishing here would end it
        // permanently: a later `start()` would restart CoreMotion but every
        // `for await sample in samples` would return immediately, no sample would
        // ever arrive, and RunRecorder's 2.5 s watchdog would report the sensors
        // as unavailable with no way back. Leaving Live and returning is enough to
        // trigger it. The service is long-lived and restartable; the continuation
        // is finished only when it is torn down.
        log.info("MotionService stopped. Unpaired samples: \(self.unpairedCount)")
    }

    deinit {
        continuation.finish()
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
            // Stash; if there was already a pending gyro, count it and DROP it.
            //
            // Design §16.2 says to emit the unpaired sample with the missing channel
            // zero-filled, but a fabricated channel poisons every consumer. A zero
            // `specificForce` has magnitude 0, outside the gate's
            // [gateSpecificForceLow, gateSpecificForceHigh] band, so it closes the
            // gate and clears the dwell. Marking it `saturated` instead is worse:
            // `BiasEstimator.process` calls `resetAccumulation()` on a saturated
            // sample, wiping all 8 seconds of collected progress, and the sample is
            // fed to the vibration detector before the gate, where a 0 among ~9.8
            // readings inflates the spread into a spurious "too much vibration".
            // A half-measured sample is evidence of nothing, so it is counted and
            // dropped rather than invented.
            if pendingGyro != nil {
                unpairedCount += 1
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
            // Counted and dropped, not zero-filled — see `receive(gyro:at:)`.
            if pendingAccel != nil {
                unpairedCount += 1
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
