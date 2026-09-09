import CoreMotion
import Foundation
import MotoTelemetryCore
import os

// MARK: - Protocol

/// Delivers a stream of `Sample.imu` from device motion hardware.
public protocol MotionProviding: Sendable {
    var samples: AsyncStream<Sample> { get }
    /// Raw sensor callbacks received this session, before any pairing decision.
    ///
    /// On the protocol because `RunRecorder`'s watchdog needs it: "no samples
    /// emitted" is two different faults, and only this number separates dead
    /// hardware from a pipeline that is dropping everything. A provider with no raw
    /// layer of its own may report 0.
    var rawCallbackCount: Int { get }
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

    /// Raw CoreMotion callbacks received this session, gyro + accel, before any
    /// pairing decision.
    ///
    /// This is the number that separates "the hardware is dead" from "our pipeline
    /// drops everything". A device log has the watchdog telling the rider *"motion
    /// sensors unavailable — check device permissions"* while 1,839 callbacks arrived
    /// in that same window and were all discarded as unpaired. Emitted counts cannot
    /// tell those two apart; this one can.
    public private(set) var rawCallbackCount: Int = 0

    // MARK: - Private

    private var continuation: AsyncStream<Sample>.Continuation
    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private let config: Config
    private let log = Logger(subsystem: "com.mototelemetry.app", category: "MotionService")

    /// Tolerance for timestamp pairing (seconds), as a fraction of the nominal
    /// sample interval.
    ///
    /// Was a hardcoded 5 ms, which is HALF the 10 ms interval at 100 Hz — and that is
    /// what made pairing a coin flip on the phase relation between two independent
    /// hardware streams. Gyro and accelerometer are started as separate CoreMotion
    /// subscriptions with independent timestamps; if their steady-state offset happens
    /// to exceed 5 ms, no sample ever pairs and the whole session emits almost
    /// nothing. The device log of 2026-09-08 shows both outcomes from the same build:
    /// session 1 emitted 986 samples against 7,907 unpaired (11%, sensor rate ~21 Hz),
    /// session 2 ran a clean 100 Hz. Nothing changed between them but the phase.
    ///
    /// That 11% session is also why calibration failed twice on sigma. Completion
    /// needs `elapsed >= 2 s` AND `n >= requiredSampleCount` (duration x rate x 0.5 =
    /// 100). At full rate the 2 s bound binds and n lands near 200; at a fifth of the
    /// rate the sample floor binds instead and n stops at exactly 100 — which is what
    /// all three `bias finish` lines report. The SEM is `std/sqrt(n)`, so sqrt(100)
    /// instead of sqrt(200) inflates the reported sigma by 1.41x, and the 0.05 deg/s
    /// limit was chosen for the 200-sample case. Measured semX 0.0523 and 0.0552 both
    /// FAILED; the same raw std over 200 samples gives 0.0370 and 0.0390, which pass.
    /// The bike was not moving too much — the stream was starving the estimator.
    ///
    /// 1.5 intervals (15 ms at 100 Hz) makes pairing nearest-neighbour rather than
    /// phase-dependent: whatever the offset, each sample pairs with the closest one
    /// from the other channel and at most one sample of skew is admitted. Safe here
    /// because the two channels are used for different things — the pair carries the
    /// GYRO's timestamp, integration dt comes from that, and the accelerometer is
    /// calibration-only in the beta (gravity anchor and rest detection), where 15 ms
    /// of skew on a stationary bike is nothing.
    private var pairTolerance: TimeInterval {
        config.nominalSampleRate > 0 ? 1.5 / config.nominalSampleRate : 0.015
    }

    /// Pending samples awaiting a pair.
    private var pendingGyro: (time: TimeInterval, rate: Vector3)?
    private var pendingAccel: (time: TimeInterval, force: Vector3)?
    private var latestAttitude: Quaternion?

    /// Lock protecting pairing state. OperationQueue serializes per-handler but
    /// gyro and accel handlers may interleave on the same queue.
    private let lock = NSLock()

    // MARK: - Diagnostics ("sensor")

    /// Structured sink for the shared NDJSON log. 1 Hz heartbeat off SAMPLE time.
    private var diag = DiagnosticEmitter(sink: DiagnosticLog.shared, category: "sensor")
    private var emittedCount = 0
    private var sawFirstSample = false
    private var streamGeneration = 0

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
        let now = ProcessInfo.processInfo.systemUptime
        // BUG 2 instrumentation: this is the `finish()` half. `start()` finishes the
        // OLD stream's continuation before making a new one. Logged as a distinct
        // cause so the log shows unambiguously that a stream ended via finish() here,
        // separate from the consuming Task being cancelled in RunRecorder.stopSession.
        diag.always(time: now, level: .info, message: "stream finished (start: replacing old)",
                    values: ["generation": Double(streamGeneration), "streamEnded": 1])
        continuation.finish()
        var cont: AsyncStream<Sample>.Continuation!
        samples = AsyncStream { cont = $0 }
        continuation = cont
        streamGeneration += 1
        sawFirstSample = false
        emittedCount = 0
        lock.lock()
        rawCallbackCount = 0
        lock.unlock()
        firstEmitTime = nil
        diag.always(time: now, level: .info, message: "stream created (start)",
                    values: ["generation": Double(streamGeneration)])

        let interval = 1.0 / config.nominalSampleRate

        // Gyroscope
        guard manager.isGyroAvailable else {
            log.error("Gyroscope unavailable")
            diag.always(time: now, level: .error, message: "gyro unavailable",
                        values: ["isGyroAvailable": 0])
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
            diag.always(time: now, level: .error, message: "accelerometer unavailable",
                        values: ["isAccelerometerAvailable": 0])
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
        diag.always(time: now, level: .info, message: "started",
                    values: ["hz": config.nominalSampleRate,
                             "gyroAvail": manager.isGyroAvailable ? 1 : 0,
                             "accelAvail": manager.isAccelerometerAvailable ? 1 : 0,
                             "deviceMotionAvail": manager.isDeviceMotionAvailable ? 1 : 0])
    }

    public func stop() {
        manager.stopGyroUpdates()
        manager.stopAccelerometerUpdates()
        manager.stopDeviceMotionUpdates()
        // Clear the pairing state so the next session boots clean.
        //
        // This is bug 4: 3 of 6 sessions in a device log emitted ZERO samples while
        // CoreMotion delivered ~100/s and every sample was discarded as unpaired.
        // A half-sample left stashed here survives into the next `start()` and puts
        // the very first tick into the overwrite phase relation — each gyro finds no
        // pending accel and overwrites its own slot, each accel does likewise — from
        // which timestamp pairing never self-heals, so the whole session emits
        // nothing. `[sensor] first sample` appeared 6-7 ms after stream creation or
        // never at all, which is the signature of a state decided on the first tick.
        // `unpairedCount` is reset too: it was never per-session, so the number
        // logged at stop was a process-cumulative total that over-counted every
        // session after the first and made the diagnostic itself misleading.
        lock.lock()
        pendingGyro = nil
        pendingAccel = nil
        latestAttitude = nil
        let unpairedThisSession = unpairedCount
        unpairedCount = 0
        lock.unlock()
        // Deliberately NOT calling `continuation.finish()`. The stream and its
        // continuation are created once in `init`, so finishing here would end it
        // permanently: a later `start()` would restart CoreMotion but every
        // `for await sample in samples` would return immediately, no sample would
        // ever arrive, and RunRecorder's 2.5 s watchdog would report the sensors
        // as unavailable with no way back. Leaving Live and returning is enough to
        // trigger it. The service is long-lived and restartable; the continuation
        // is finished only when it is torn down.
        log.info("MotionService stopped. Unpaired samples: \(unpairedThisSession)")
        // BUG 2 instrumentation: stop() deliberately does NOT finish the continuation.
        // Logged so the trace shows the stream is STILL LIVE after stop — if the angle
        // freezes, the death was the consuming Task being cancelled (RunRecorder.
        // stopSession → motionTask.cancel()), which puts the stream terminal from the
        // consumer side, NOT a finish() here. This line is what makes the two causes
        // distinguishable in the log.
        diag.always(time: ProcessInfo.processInfo.systemUptime, level: .info,
                    message: "stopped (stream NOT finished — still live)",
                    values: ["streamEnded": 0,
                             "generation": Double(streamGeneration),
                             "unpaired": Double(unpairedThisSession),
                             "emitted": Double(emittedCount)])
    }

    deinit {
        continuation.finish()
    }

    // MARK: - Pairing

    private func receive(gyro rate: Vector3, at time: TimeInterval) {
        lock.lock()
        rawCallbackCount += 1
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
            //
            // An opposite-channel stash older than the tolerance window can never
            // pair with anything that arrives from now on, so EVICT it instead of
            // leaving it to block future matches. Without this the pairing can settle
            // into a stable overwrite phase relation and emit zero for an entire
            // session (bug 4) — the eviction is what makes that state recoverable
            // rather than permanent. It only discards samples that were already
            // unpairable, so a sample that would otherwise have paired is never lost.
            if let accel = pendingAccel, time - accel.time > pairTolerance {
                pendingAccel = nil
                unpairedCount += 1
            }
            if pendingGyro != nil {
                unpairedCount += 1
            }
            pendingGyro = (time, rate)
            lock.unlock()
        }
    }

    private func receive(accel force: Vector3, at time: TimeInterval) {
        lock.lock()
        rawCallbackCount += 1
        if let gyro = pendingGyro, abs(gyro.time - time) <= pairTolerance {
            pendingGyro = nil
            let attitude = latestAttitude
            lock.unlock()
            emit(time: time, rate: gyro.rate, force: force, attitude: attitude)
        } else {
            // Counted and dropped, not zero-filled — see `receive(gyro:at:)`.
            // Stale-stash eviction, same reasoning as the gyro path.
            if let gyro = pendingGyro, time - gyro.time > pairTolerance {
                pendingGyro = nil
                unpairedCount += 1
            }
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

        // Diagnostics: first sample (one-shot) + 1 Hz heartbeat carrying observed
        // rate and cumulative count. Rate discipline: NEVER per sample — the
        // heartbeat is gated on SAMPLE time by DiagnosticEmitter. `emittedCount` is
        // touched only here (OperationQueue serialises this handler pair) plus in
        // start/stop logging, which run when no samples flow.
        emittedCount += 1
        if !sawFirstSample {
            sawFirstSample = true
            diag.always(time: time, level: .info, message: "first sample",
                        values: ["generation": Double(streamGeneration)])
        }
        let observedHz = firstEmitTime.map { t -> Double in
            let dt = time - t
            return dt > 0 ? Double(emittedCount) / dt : 0
        } ?? 0
        if firstEmitTime == nil { firstEmitTime = time }
        diag.emit("live", time: time, level: .info, message: "sensor heartbeat",
                  values: ["hz": observedHz, "count": Double(emittedCount),
                           "generation": Double(streamGeneration)])
    }

    /// Sample time of the first emitted sample this session, for observed-Hz.
    private var firstEmitTime: TimeInterval?

    private func isSaturated(rate: Vector3, force: Vector3) -> Bool {
        let gyroLimit = config.gyroFullScale * 0.99
        let accelLimit = config.accelFullScale * 0.99
        return abs(rate.x) >= gyroLimit || abs(rate.y) >= gyroLimit || abs(rate.z) >= gyroLimit
            || abs(force.x) >= accelLimit || abs(force.y) >= accelLimit || abs(force.z) >= accelLimit
    }
}
