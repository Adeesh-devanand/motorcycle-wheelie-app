import Foundation
import MotoTelemetryCore
@testable import MotoTelemetryApp

// MARK: - Controlled clock

/// A monotonic clock the test advances by hand, in the same `systemUptime` domain
/// the pipeline uses. Nothing here reads the wall clock or sleeps: time only moves
/// when the test calls `advance(by:)`, so a "held 2 s" scenario is expressed in
/// scripted sample timestamps rather than by waiting 2 real seconds.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: TimeInterval

    init(start: TimeInterval = 1_000) { self.now = start }

    var current: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return now
    }

    /// Advance the clock and return the new time, for stamping the next sample.
    @discardableResult
    func advance(by dt: TimeInterval) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        now += dt
        return now
    }
}

// MARK: - Scripted motion source

/// A `MotionProviding` whose sample stream is driven entirely by the test. It
/// reuses the production protocol verbatim — `RunRecorder` cannot tell it apart
/// from `MotionService` — so the harness exercises the real recorder wiring, not a
/// parallel code path.
///
/// `yield(_:)` pushes one `Sample` into the recorder's consuming task; the test
/// scripts the whole run by calling it with timestamps taken from a `ManualClock`.
/// `finish()` ends the stream deterministically so the consuming task can complete
/// without any timeout.
final class ScriptedMotionSource: MotionProviding, @unchecked Sendable {
    private(set) var samples: AsyncStream<Sample>
    private var continuation: AsyncStream<Sample>.Continuation
    private let lock = NSLock()
    private var started = false
    private var rawCount = 0

    var rawCallbackCount: Int {
        lock.lock(); defer { lock.unlock() }
        return rawCount
    }

    /// Observable so a test can assert the recorder actually started the provider.
    private(set) var startCalls = 0
    private(set) var stopCalls = 0

    init() {
        var cont: AsyncStream<Sample>.Continuation!
        self.samples = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    func start() {
        lock.lock(); startCalls += 1; started = true; lock.unlock()
    }

    func stop() {
        lock.lock(); stopCalls += 1; lock.unlock()
    }

    /// Push one scripted sample into the stream and count it as a raw callback,
    /// mirroring `MotionService`, which increments `rawCallbackCount` per delivery.
    func yield(_ sample: Sample) {
        lock.lock(); rawCount += 1; lock.unlock()
        continuation.yield(sample)
    }

    /// Convenience: script one IMU sample at the given monotonic time.
    func yieldIMU(time: TimeInterval,
                  rotationRate: Vector3 = Vector3(0, 0, 0),
                  specificForce: Vector3 = Vector3(0, 0, -9.80665),
                  saturated: Bool = false) {
        let imu = IMUSample(time: time,
                            rotationRate: rotationRate,
                            specificForce: specificForce,
                            fusedAttitude: nil,
                            saturated: saturated)
        yield(.imu(imu))
    }

    /// End the stream so the recorder's consuming task terminates deterministically.
    func finish() { continuation.finish() }
}

// MARK: - Scripted GNSS source

/// A `SpeedProviding` driven by the test, reusing the production protocol so the
/// recorder's speed task runs its real code path.
final class ScriptedSpeedSource: SpeedProviding, @unchecked Sendable {
    private(set) var fixes: AsyncStream<Sample>
    private var continuation: AsyncStream<Sample>.Continuation
    private let lock = NSLock()

    private(set) var startCalls = 0
    private(set) var stopCalls = 0

    init() {
        var cont: AsyncStream<Sample>.Continuation!
        self.fixes = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    func start() { lock.lock(); startCalls += 1; lock.unlock() }
    func stop() { lock.lock(); stopCalls += 1; lock.unlock() }

    func yield(_ sample: Sample) { continuation.yield(sample) }

    func yieldFix(fixTime: TimeInterval,
                  arrivalTime: TimeInterval,
                  speed: Double,
                  speedAccuracy: Double = 1.0) {
        let fix = GNSSFix(fixTime: fixTime,
                          arrivalTime: arrivalTime,
                          speed: speed,
                          speedAccuracy: speedAccuracy,
                          course: 0,
                          courseAccuracy: -1,
                          latitude: 0,
                          longitude: 0,
                          altitude: 0,
                          horizontalAccuracy: 5)
        yield(.gnss(fix))
    }

    func finish() { continuation.finish() }
}

// MARK: - Isolated temporary store

/// Wraps a `RunRepository` pointed at a fresh temp directory, so a test never
/// touches the real `Documents/runs`. Remove `directory` in tearDown.
///
/// Production is unchanged: a `RunRepository()` with no arguments still resolves
/// `Documents/runs` exactly as before — the injectable `runsDirectory` used here is
/// the only added surface, and only tests pass it.
struct TemporaryRunStore {
    let directory: URL
    let repository: RunRepository

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("k02-runstore-\(UUID().uuidString)", isDirectory: true)
        repository = RunRepository(runsDirectory: directory)
    }

    /// Number of run JSON files physically on disk in the isolated store.
    func fileCount() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.count
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - Fixtures

enum K02Fixture {
    /// A minimally valid `WheelieRun` for the repository-seam flow test. Empty
    /// `samples` is legal for persistence; an end-to-end segmenter-driven save is a
    /// Mac-side follow-up (needs the running pipeline).
    static func run(id: UUID = UUID()) -> WheelieRun {
        let config = RunConfigurationSnapshot(
            angleTarget: MetricRange(lower: 35, upper: 45),
            speedTarget: MetricRange(lower: 0, upper: 0),
            speedGaugeMaximum: 100,
            calibrationID: UUID()
        )
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return WheelieRun(
            id: id,
            startedAt: start,
            endedAt: start.addingTimeInterval(3),
            samples: [],
            configuration: config,
            qualityFlags: []
        )
    }
}

/// Error a test injects through `RunRepository.writeInterceptor` to simulate a
/// failed disk write.
struct InjectedWriteFailure: Error {}
