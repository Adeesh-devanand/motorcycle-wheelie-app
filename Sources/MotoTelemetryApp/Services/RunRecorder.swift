import Foundation
import MotoTelemetryCore
import Observation
import os

/// Hosts a live `Pipeline` instance, consumes sensor streams from `MotionService`
/// and `SpeedService`, and bridges `PipelineOutput` → `TelemetrySample` for the UI.
/// On event end, builds a `WheelieRun` and persists via `RunRepository`.
@Observable
final class RunRecorder: @unchecked Sendable {

    // MARK: - Live state (for ViewModel binding)

    enum RecordingState: Sendable, Equatable {
        case idle
        /// Sensor stream live, feeding calibration, but no recording pipeline yet.
        case sensing
        case running
        case paused
    }

    // MARK: - Live state (for ViewModel binding)
    //
    // Data race: this class is `@Observable` + `@unchecked Sendable` but is
    // NOT `@MainActor`, while SwiftUI observes these properties on the main actor.
    // `processSample` runs on two detached sensor Tasks at 100 Hz — `processLock`
    // serialises those two writers against each OTHER, but gives no exclusion against
    // the main actor reading the same `@Observable` storage. Under Swift 6 strict
    // concurrency that cross-actor read/write is a hard data race.
    //
    // Fix: every UI-facing property below is `@MainActor`-isolated, so it is only
    // ever mutated on the main actor. The sensor tasks never touch them directly.
    // Instead `processSample` (under the lock, off-actor) stages the latest values
    // into `pendingDisplay`, a plain lock-protected value type; the main-actor
    // `flushDisplay()` copies that snapshot into the observable properties. The view
    // model already ticks at 30 Hz on the main actor, so it calls `flushDisplay()`
    // once per display frame — coalescing 100 Hz of sensor writes into 30 Hz of
    // main-actor applies. No `Task` is spawned per sample, and no `await` runs inside
    // the critical section.

    @MainActor private(set) var recordingState: RecordingState = .idle
    @MainActor private(set) var livePitch: Double = 0           // degrees
    @MainActor private(set) var livePitchRate: Double = 0       // deg/s
    @MainActor private(set) var liveRoll: Double = 0            // degrees
    @MainActor private(set) var liveSpeed: Double = 0           // km/h
    /// False when no GNSS fix has produced a valid speed yet. R15.3 forbids
    /// fabricating 0: a stationary bike and an absent fix must not look identical.
    /// `liveSpeed` stays 0 for compatibility; consult this before displaying it.
    @MainActor private(set) var liveSpeedAvailable: Bool = false
    @MainActor private(set) var liveVibration: Double = 0       // m/s²
    @MainActor private(set) var eventActive: Bool = false
    @MainActor private(set) var currentEventDuration: TimeInterval = 0
    @MainActor private(set) var sampleCount: Int = 0
    /// Current raw-log size in bytes, surfaced for the UI.
    @MainActor private(set) var rawLogSizeBytes: UInt64 = 0

    /// Latest UI values staged by `processSample` under `processLock`, drained onto
    /// the observable properties by `flushDisplay()` on the main actor. A plain value
    /// type so it can be read-modify-written inside the critical section with no
    /// isolation concerns.
    private struct PendingDisplay {
        var pitch: Double = 0
        var pitchRate: Double = 0
        var roll: Double = 0
        var speed: Double = 0
        var speedAvailable: Bool = false
        var vibration: Double = 0
        var eventActive: Bool = false
        var currentEventDuration: TimeInterval = 0
        var sampleCount: Int = 0
        var rawLogSizeBytes: UInt64 = 0
    }
    /// Guarded by `processLock`.
    private var pendingDisplay = PendingDisplay()

    // MARK: - Dependencies

    private let motionService: any MotionProviding
    private let speedService: any SpeedProviding
    private let calibrationService: CalibrationService
    private let repository: RunRepository
    private let config: Config
    private let cueRenderer: CueAudioRenderer?

    // MARK: - Pipeline internals

    private var pipeline: Pipeline?
    private var segmenter: EventSegmenter?
    private var scorer: RunScorer?

    // Internal hot-path mirrors of UI state, mutated on the sensor tasks under
    // `processLock`. Kept SEPARATE from the `@MainActor` observable properties so the
    // sensor path never touches main-actor storage; the observable copies are updated
    // only by `flushDisplay()`.
    private var internalSampleCount: Int = 0
    private var internalEventActive: Bool = false
    private var internalRawLogSizeBytes: UInt64 = 0
    private var internalCurrentEventDuration: TimeInterval = 0

    /// Monotonically increasing session id. Bumped on every `startSession` /
    /// `startSensing` and read at the top of `processSample` : a sample that
    /// arrives after the session it belongs to has stopped — an in-flight
    /// `processSample` on a task that was cancelled but not awaited — carries the OLD
    /// epoch and is dropped, so it can neither mutate state after stop nor race the
    /// next session's pipeline. `stopSession` does not await the tasks (that would
    /// force `stopSession`/`onDisappear` to become async — see the note there), so
    /// this guard is what actually makes the stop safe.
    private var sessionEpoch: UInt64 = 0

    /// Interpolated onset time of the attempt in progress. The live timer is
    /// `output.time - eventOnsetTime`; using `sessionStartMonotonic` instead made
    /// the timer jump straight to the session's elapsed time the moment an attempt
    /// began (a wheelie 85 s into a session displayed 85 s).
    private var eventOnsetTime: TimeInterval?

    private var collectedSamples: [TelemetrySample] = []
    private var sessionStartDate: Date?
    private var sessionStartMonotonic: TimeInterval?
    private var bikeProfileID: UUID?
    private var angleTarget: MetricRange?
    /// Session speed settings, captured at `startSession` so a saved run records the
    /// configuration it was ridden under rather than a constant.
    private var speedTarget: MetricRange = MetricRange(lower: 0, upper: 0)
    private var speedGaugeMaximum: Double = 100
    /// When false the rider has switched the speedometer off: GNSS is not consulted,
    /// no speed reaches the display, and a saved run stores 0 for every speed field.
    private var speedEnabled: Bool = true

    private var motionTask: Task<Void, Never>?
    private var speedTask: Task<Void, Never>?

    /// Serialises `processSample` across the motion and speed tasks. The class is
    /// `@unchecked Sendable` and `@Observable`, neither of which provides any
    /// mutual exclusion.
    private let processLock = NSLock()

    /// Runs finalised by `processSample` — off the main actor, under `processLock` —
    /// and waiting to be handed to `RunRepository` on the main actor. Guarded by
    /// `processLock`.
    ///
    /// This queue exists because saving inline was hanging the app. `repository.save`
    /// JSON-encodes the run, writes it to disk atomically, and appends to
    /// `RunRepository.allRuns`, which is `@Observable` and read by SwiftUI. Doing that
    /// from `finalizeCurrentEvent` meant:
    ///
    /// 1. The sensor thread held `processLock` across a synchronous FILE WRITE, while
    ///    the main thread takes the same lock 30x a second in `flushDisplay()`. Every
    ///    event end therefore blocked the main thread for the length of a disk write.
    /// 2. `allRuns` was mutated OFF the main actor while SwiftUI read it on the main
    ///    actor — an `@Observable` data race, and the notification it fires can reach
    ///    main-actor observers from a thread already holding a lock the main actor
    ///    wants. That is the lock inversion, and it matches the device log exactly:
    ///    `sensor heartbeat` continues at 100 Hz (MotionService's own callback, which
    ///    takes no lock) while `pipe`, `rec` and `live` heartbeats all stop dead after
    ///    "event end", with "event finalized — windowed & saved" never printed.
    ///
    /// Draining happens on the main actor with no lock held: from `flushDisplay()` on
    /// the display tick, and from `stopSession()`, which needs its own drain because
    /// the view model stops the display link BEFORE calling it.
    private var pendingSavedRuns: [WheelieRun] = []

    private let log = Logger(subsystem: "com.mototelemetry.app", category: "RunRecorder")

    // MARK: - Diagnostics ("rec")

    private var diag = DiagnosticEmitter(sink: DiagnosticLog.shared, category: "rec")

    /// Records the raw, unprocessed sensor stream for desk replay. Behind a flag,
    /// default ON — the user needs data for the TestFlight bugs. Set false to skip.
    var rawRecordingEnabled = true
    private var rawRecorder: RawSampleRecorder?
    private var batchCount = 0

    // MARK: - Init

    init(motionService: any MotionProviding,
         speedService: any SpeedProviding,
         calibrationService: CalibrationService,
         repository: RunRepository,
         config: Config = Config(),
         cueRenderer: CueAudioRenderer? = nil) {
        self.motionService = motionService
        self.speedService = speedService
        self.calibrationService = calibrationService
        self.repository = repository
        self.config = config
        self.cueRenderer = cueRenderer
    }

    // MARK: - Session lifecycle

    /// Starts CoreMotion + GPS and the two consuming Tasks. Shared by `startSensing`
    /// (calibration phase) and `startSession` (recording), so the stream is wired the
    /// same way in both and never started twice.
    ///
    /// Both sensor streams funnel through `processSample`, which mutates the
    /// value-type `EventSegmenter` with a read-modify-write. These are two
    /// independent Tasks on the cooperative pool, so without serialisation two
    /// resumptions can each read the SAME pre-write segmenter state, both satisfy the
    /// `.arming` guard, and both emit `.onset` — the "multiple wheelies start at once"
    /// symptom. The lock makes the read-modify-write atomic; the critical section is
    /// ~200 µs against a 10 ms sample budget.
    private func startSensorTasks() {
        motionService.start()
        speedService.start()

        // Bind each task to a fresh session id. `startSensorTasks` is the ONLY place
        // tasks are created, so bumping here (and again in `stopSession`) means the
        // epoch identifies THIS pair of tasks' lifetime. The sensing→recording
        // promotion in `startSession` reuses these same tasks without calling this
        // method, so it must NOT bump — the tasks stay valid across the promotion.
        // `processSample` compares against the live `sessionEpoch` and drops any
        // sample whose task outlived its session .
        processLock.lock()
        sessionEpoch &+= 1
        let epoch = sessionEpoch
        processLock.unlock()

        motionTask = Task { [weak self] in
            guard let self else { return }
            for await sample in self.motionService.samples {
                self.processLocked(sample, epoch: epoch)
            }
        }

        speedTask = Task { [weak self] in
            guard let self else { return }
            for await sample in self.speedService.fixes {
                self.processLocked(sample, epoch: epoch)
            }
        }
    }

    /// Takes `processLock` around `processSample`. Deliberately **synchronous**:
    /// `NSLock.lock()` is unavailable from an async context — the compiler cannot
    /// prove no suspension happens between `lock` and `unlock` inside a `for await`
    /// body, and in Swift 6 that is a hard error rather than a warning. Nothing on
    /// this path awaits, so hoisting the critical section into a non-async function
    /// states that fact in a form the checker accepts. `defer` also makes the unlock
    /// survive an early return added later.
    private func processLocked(_ sample: Sample, epoch: UInt64) {
        processLock.lock()
        defer { processLock.unlock() }
        processSample(sample, epoch: epoch)
    }

    /// Start the sensor stream WITHOUT a recording pipeline, so calibration (and the
    /// swipe that follows) can run before an alignment exists. `processSample` feeds
    /// every raw IMU sample to `CalibrationService` and then early-returns on the nil
    /// pipeline, so nothing is scored or stored yet. `startSession` later promotes
    /// this same running stream to a full recording session — the stream is never
    /// started twice.
    @MainActor
    func startSensing(bikeProfileID: UUID) {
        guard recordingState == .idle else { return }
        self.bikeProfileID = bikeProfileID
        self.sessionStartMonotonic = ProcessInfo.processInfo.systemUptime
        startSensorTasks()
        recordingState = .sensing
        log.info("Sensing started (calibration phase) for bike \(bikeProfileID)")
    }

    @MainActor
    func startSession(bikeProfileID: UUID,
                      mountAlignment: MountAlignment,
                      angleTarget: MetricRange,
                      speedTarget: MetricRange,
                      speedGaugeMaximum: Double,
                      speedEnabled: Bool) {
        // Reachable from .idle (no prior sensing) OR .sensing (calibration ran
        // first, the normal path). Refuse from .running AND .paused: the guard used
        // to be `!= .running`, which let a .paused session fall through and start a
        // SECOND pair of sensor tasks — the `!= .sensing` check below then passed,
        // overwriting motionTask/speedTask and leaking the first pair's handles (the
        // streams stayed live with no way to cancel them). Only .idle/.sensing may
        // legally begin a recording.
        guard recordingState == .idle || recordingState == .sensing else { return }

        self.bikeProfileID = bikeProfileID
        self.angleTarget = angleTarget
        // Recorded so a saved run carries the target the rider was ACTUALLY riding
        // to. These used to be hardcoded at the point of use — `MetricRange(0...100)`
        // and a `100` ceiling — while `angleTarget` correctly used the session value,
        // so every run ever saved claimed a speed target spanning the whole gauge and
        // Run Details drew the blue band across the entire chart.
        self.speedTarget = speedEnabled ? speedTarget : MetricRange(lower: 0, upper: 0)
        self.speedGaugeMaximum = speedGaugeMaximum
        self.speedEnabled = speedEnabled
        self.sessionStartDate = Date()
        self.sessionStartMonotonic = ProcessInfo.processInfo.systemUptime
        self.collectedSamples = []
        self.sampleCount = 0
        // Reset the hot-path mirrors and the staged snapshot. Do NOT bump
        // `sessionEpoch` here: on the .sensing path the sensor tasks are reused
        // (their epoch must stay valid), and on the .idle path `startSensorTasks`
        // below bumps it. The late-sample guard is anchored to task lifetime,
        // not session start.
        processLock.lock()
        internalSampleCount = 0
        internalEventActive = false
        internalRawLogSizeBytes = 0
        pendingDisplay = PendingDisplay()
        processLock.unlock()

        // Initialize pipeline with the calibration result. In the beta flow the
        // rider cannot reach this screen until calibration has completed and the
        // swipe alignment is captured, so both are present.
        pipeline = Pipeline(
            config: config,
            alignment: mountAlignment,
            initialBias: calibrationService.estimate,
            gravityAnchor: calibrationService.estimate?.measuredGravity,
            sink: DiagnosticLog.shared
        )

        // Raw recorder — full-rate unprocessed trace for desk replay (default ON).
        if rawRecordingEnabled {
            let rec = RawSampleRecorder(config: config, bikeProfileID: bikeProfileID)
            rawRecorder = rec
            diag.always(time: sessionStartMonotonic ?? ProcessInfo.processInfo.systemUptime,
                        level: .info, message: "raw recorder started", values: [:])
        }

        // Initialize downstream stages
        segmenter = EventSegmenter(config: config)
        scorer = RunScorer(config: config)

        // Start the sensor stream only if sensing did not already start it during
        // the calibration phase — otherwise the tasks are already draining.
        if recordingState != .sensing {
            startSensorTasks()
        }

        // Speedometer off: release GNSS rather than merely discarding its output.
        // `bestForNavigation` location is the most expensive thing this app asks the
        // OS for, and holding it to feed a meter that is not on screen is the kind of
        // silent cost the rider cannot see. Suppression downstream (the pipeline read
        // and the telemetry bridge) is what guarantees 0 in the record; this is what
        // stops paying for the fix. Re-enabling takes effect on the next session,
        // which the re-calibrate path already restarts.
        if !speedEnabled {
            speedTask?.cancel()
            speedTask = nil
            speedService.stop()
            diag.always(time: sessionStartMonotonic ?? ProcessInfo.processInfo.systemUptime,
                        level: .info, message: "speedometer disabled — GNSS released",
                        values: ["speedEnabled": 0])
        }

        cueRenderer?.start()

        recordingState = .running
        log.info("Recording session started for bike \(bikeProfileID)")
        diag.always(time: sessionStartMonotonic ?? ProcessInfo.processInfo.systemUptime,
                    level: .info, message: "session started",
                    values: ["hasInitialBias": calibrationService.estimate == nil ? 0 : 1])

        // Watchdog: if no sample has arrived shortly after starting, the sensor
        // path is genuinely broken — denied permission, missing hardware, or a
        // dead stream. Only then may we claim the sensors are unavailable.
        // Measuring the absence of data beats trusting `isGyroAvailable`, which
        // reports hardware presence and says nothing about delivery.
        Task { [weak self] in
            // Two chances, five seconds total. CoreMotion delivery can be slow to
            // spin up after a restart, and a single 2.5 s miss was enough to strand
            // the UI on "Motion sensors unavailable / Check device permissions" —
            // a screen with no way out. Never contradict evidence either: if an IMU
            // sample has EVER arrived in this process the sensors demonstrably
            // exist, so claiming otherwise is a false negative, not a diagnosis.
            //
            // this Task is not on the main actor, so it must not read the
            // `@MainActor` observable state directly. `recordingState` is hopped via a
            // main-actor read; sample counts come from `internalSampleCount`, the
            // lock-protected hot-path counter (which is what the sensor tasks bump),
            // so the watchdog measures the same "emitted" quantity as before without
            // touching main-actor storage.
            self?.diag.always(time: ProcessInfo.processInfo.systemUptime, level: .info,
                              message: "watchdog armed (2×2.5s)", values: [:])
            func isRunning() async -> Bool {
                guard let self else { return false }
                return await MainActor.run { self.recordingState == .running }
            }
            func emittedSamples() -> Int {
                guard let self else { return 0 }
                self.processLock.lock(); defer { self.processLock.unlock() }
                return self.internalSampleCount
            }
            for _ in 0..<2 {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard await isRunning() else { return }
                if emittedSamples() > 0 { return }
            }
            guard let self,
                  await isRunning(),
                  emittedSamples() == 0,
                  !self.calibrationService.hasSeenSample else { return }

            // What kind of silence is this? The watchdog measures EMITTED samples,
            // and for five seconds it has seen none — but "none emitted" is two
            // completely different faults. If raw CoreMotion callbacks are arriving,
            // the hardware is demonstrably alive and our own pairing is dropping
            // everything (bug 4); a device log shows this path telling the rider to
            // check device permissions while 1,839 callbacks landed in that same
            // window. Claiming a permissions problem then is a false diagnosis, and it
            // sends them to a settings screen that was never the issue.
            let raw = self.motionService.rawCallbackCount
            if raw > 0 {
                self.diag.always(time: ProcessInfo.processInfo.systemUptime, level: .error,
                                 message: "watchdog FIRED — sensors ALIVE but nothing emitted (pairing fault)",
                                 values: ["rawCallbacks": Double(raw),
                                          "emitted": Double(emittedSamples())])
                self.log.error("Motion callbacks arriving (\(raw)) but no paired samples emitted — pairing fault, not a hardware fault")
                return
            }

            self.diag.always(time: ProcessInfo.processInfo.systemUptime, level: .error,
                             message: "watchdog FIRED — reporting sensors unavailable",
                             values: ["sampleCount": 0,
                                      "rawCallbacks": 0])
            self.calibrationService.reportSensorsUnavailable(
                reason: "no IMU samples and no raw motion callbacks 5 s after starting motion updates")
        }
    }

    @MainActor
    func stopSession() {
        guard recordingState != .idle else { return }

        // Late work on stop: we cancel the consuming Tasks but deliberately do
        // NOT await them here — awaiting would make `stopSession` (and therefore
        // `LiveWheelieViewModel.onDisappear`, a synchronous SwiftUI lifecycle hook)
        // `async`, which it cannot be without a wrapping `Task` that reintroduces the
        // very ordering race we are closing. Instead we invalidate the session id
        // BEFORE cancelling: bumping `sessionEpoch` under the lock means any
        // `processSample` already in flight (or that resumes after cancel) carries the
        // stale epoch and early-returns, so it can neither mutate state after stop nor
        // race the next `startSession`. The bump is under the lock so it is ordered
        // against a concurrent `processSample`'s epoch read.
        processLock.lock()
        sessionEpoch &+= 1
        let emitted = internalSampleCount
        processLock.unlock()

        // Cancelling the consuming Task is what actually kills the AsyncStream —
        // `MotionService.stop()` deliberately leaves its continuation live. This is the
        // suspected mechanism behind "the angle stops responding after leaving Live",
        // so the death is recorded explicitly with a machine-readable flag rather than
        // left to be inferred from message prose.
        diag.always(time: ProcessInfo.processInfo.systemUptime, level: .info,
                    message: "consuming Tasks cancelled — sensor streams die here",
                    values: ["streamEnded": 1,
                             "motionTaskLive": motionTask == nil ? 0 : 1,
                             "speedTaskLive": speedTask == nil ? 0 : 1,
                             "sampleCount": Double(emitted)])

        motionTask?.cancel()
        speedTask?.cancel()
        motionTask = nil
        speedTask = nil

        motionService.stop()
        speedService.stop()
        cueRenderer?.stop()

        // close an event still OPEN at stream end. Previously a ride stopped
        // while still lofted lost its event entirely — the segmenter only emitted on
        // an in-stream boundary crossing, so a hold that never came back down was
        // silently dropped, biasing recorded runs toward the shortest/typical holds
        // and away from the longest. `EventSegmenter.finish()` closes such an event
        // and re-applies the SAME minDuration rule (a hold too short to count is
        // returned as `.discarded`, not promoted). Route its transition through the
        // exact `handleTransition` path the in-loop `.end`/`.discarded` cases use so
        // the scorer is finalised and the run recorded identically. The segmenter is
        // a value type, so take the lock for the read-modify-write; the sensor tasks
        // are cancelled by now but the lock keeps this ordered against any that is
        // still draining its final buffered sample.
        processLock.lock()
        if var seg = segmenter {
            let transition = seg.finish()
            segmenter = seg
            if let transition {
                // `finish()` returns only `.end`/`.discarded`, both of which
                // `handleTransition` already handles (it finalises the scorer and,
                // for `.end`, records the event via `finalizeCurrentEvent`). The `at:`
                // argument is only the diag timestamp for the `.discarded` case; use
                // the event's end time when known, else the current uptime.
                let at: TimeInterval
                switch transition.kind {
                case .end(let endTime): at = endTime
                case .discarded, .onset: at = ProcessInfo.processInfo.systemUptime
                }
                handleTransition(transition, at: at, speed: nil)
            }
        }
        internalEventActive = false
        processLock.unlock()

        // Write whatever `seg.finish()` just closed. Must be after the unlock: the
        // save touches the disk and `@Observable` repository state, and this method
        // runs on the main actor.
        drainPendingSaves()

        pipeline = nil
        segmenter = nil
        scorer = nil
        recordingState = .idle
        eventActive = false
        rawRecorder?.finish()
        let finalSize = rawRecorder?.fileSizeBytes ?? internalRawLogSizeBytes
        internalRawLogSizeBytes = finalSize
        rawLogSizeBytes = finalSize
        rawRecorder = nil
        log.info("Recording session stopped. Total samples: \(emitted)")
        diag.always(time: ProcessInfo.processInfo.systemUptime, level: .info,
                    message: "session stopped",
                    values: ["totalSamples": Double(emitted),
                             "rawLogBytes": Double(finalSize)])
    }

    /// Copies the latest staged sensor values onto the `@MainActor` observable
    /// properties . Called from the view model's 30 Hz display tick, so 100 Hz
    /// of sensor writes coalesce into one main-actor apply per display frame — no Task
    /// per sample, no cross-actor write of `@Observable` storage.
    @MainActor
    func flushDisplay() {
        processLock.lock()
        let snap = pendingDisplay
        // Taken in the SAME critical section as the display snapshot, so the 30 Hz
        // tick costs one lock acquisition rather than two.
        let finished = pendingSavedRuns
        if !finished.isEmpty { pendingSavedRuns.removeAll(keepingCapacity: true) }
        processLock.unlock()

        livePitch = snap.pitch
        livePitchRate = snap.pitchRate
        liveRoll = snap.roll
        liveSpeed = snap.speed
        liveSpeedAvailable = snap.speedAvailable
        liveVibration = snap.vibration
        eventActive = snap.eventActive
        currentEventDuration = snap.currentEventDuration
        sampleCount = snap.sampleCount
        rawLogSizeBytes = snap.rawLogSizeBytes

        // AFTER the unlock, on the main actor. The disk write and the `@Observable`
        // mutation must not happen under `processLock` or off the main actor.
        saveFinished(finished)
    }

    /// Hand runs finalised off-actor to the repository. Main actor, no lock held.
    ///
    /// `stopSession()` needs this separately from `flushDisplay()`: the view model
    /// stops the 30 Hz display link before calling it, so a run closed by
    /// `EventSegmenter.finish()` would otherwise sit in the queue and never be
    /// written — losing exactly the run the `finish()` fix was added to save.
    @MainActor
    private func drainPendingSaves() {
        processLock.lock()
        let finished = pendingSavedRuns
        pendingSavedRuns.removeAll(keepingCapacity: true)
        processLock.unlock()
        saveFinished(finished)
    }

    @MainActor
    private func saveFinished(_ runs: [WheelieRun]) {
        for run in runs {
            repository.save(run)
            diag.always(time: ProcessInfo.processInfo.systemUptime, level: .info,
                        message: "run saved", values: ["samples": Double(run.samples.count)])
        }
    }

    // MARK: - Sample processing

    private func processSample(_ sample: Sample, epoch: UInt64) {
        // Late work on stop: this may be an in-flight sample on a task that
        // was cancelled but not awaited. If its session has ended (or a new one has
        // begun), `epoch` no longer matches `sessionEpoch` — drop it, so it cannot
        // record raw data, feed calibration, or mutate the next session's pipeline.
        // Runs under `processLock` (held by the caller), so the comparison is ordered
        // against `stopSession`'s bump.
        guard epoch == sessionEpoch else { return }

        // Raw trace and calibration run BEFORE the pipeline guard, so they work
        // during the sensing-only phase (calibration + swipe) when `pipeline` is
        // still nil. The rider is calibrating precisely when there is no pipeline yet.
        rawRecorder?.record(sample)
        if case .imu(let imu) = sample {
            calibrationService.feedIMU(imu)
        }

        // No pipeline until the swipe is confirmed and `startSession` builds it.
        // During calibration + swipe this is the normal, expected early return.
        guard var pipe = pipeline else { return }

        // No mid-ride re-anchor block: in the calibrate-once flow calibration
        // COMPLETES before the pipeline is built, and the pipeline is born anchored
        // from the estimate's gravity vector (see `startSession`). There is no
        // adopt-a-new-estimate-mid-session path to react to, so the seven-re-anchors
        // -in-one-session bug that block guarded against cannot occur.

        // Run through pipeline
        guard let output = pipe.process(sample) else {
            pipeline = pipe
            return
        }
        pipeline = pipe

        internalSampleCount += 1
        batchCount += 1

        // 1 Hz processing heartbeat (gated on output time), carrying cumulative
        // sample count, per-heartbeat batch size, live pitch and the raw-log size.
        if let rawRecorder { internalRawLogSizeBytes = rawRecorder.fileSizeBytes }
        let heartbeatEmitted = diag.emit("processing", time: output.time, level: .info,
                                message: "rec heartbeat",
                                values: ["samples": Double(internalSampleCount),
                                         "batch": Double(batchCount),
                                         "pitchDeg": output.pitch * 180 / .pi,
                                         "rawLogBytes": Double(internalRawLogSizeBytes)])
        if heartbeatEmitted { batchCount = 0 }

        // Compute the live display values (rad → deg, m/s → km/h). these are
        // NOT written to the `@Observable` properties here — that would be an
        // off-main-actor write of storage SwiftUI reads. They are staged into
        // `pendingDisplay` at the end of this critical section and applied on the main
        // actor by `flushDisplay()`.
        let pitchDeg = output.pitch * 180 / .pi
        let pitchRateDeg = output.pitchRate * 180 / .pi
        let rollDeg = output.roll * 180 / .pi
        // With the speedometer switched off there is no speed reading at all: not a
        // held value, not a zero standing in for one. `speedAvailable` false is the
        // same signal the app already uses for "no GNSS fix", so the display shows a
        // dash (and the card is hidden), the attempt max stays 0, and the saved run
        // records 0 — rather than a number nobody was watching.
        let speedAvailable = speedEnabled && output.speed != nil
        let speedKPH = speedEnabled ? (output.speed ?? 0) * 3.6 : 0
        let vibration = output.vibration

        // No calibrationService.process(output): the beta pipeline has no live gate,
        // and calibration is driven directly by feedIMU above. Pipeline output no
        // longer carries a gate verdict to track.

        // Warning tone: beep rate, carrier pitch and volume all rise with the
        // live ANGLE alone; solid tone past the limit angle. The predictive
        // CueEngine that once also drove a UI badge was removed — it read pitch
        // RATE, never reached the speaker, and was dead weight once the cue was
        // decided as angle-only.
        cueRenderer?.update(pitchDegrees: pitchDeg)

        // Event segmenter
        if var seg = segmenter {
            if let transition = seg.process(time: output.time,
                                            pitch: output.pitch,
                                            pitchRate: output.pitchRate) {
                segmenter = seg
                handleTransition(transition, at: output.time, speed: output.speed)
            } else {
                segmenter = seg
            }

            // Update event-active flag on pipeline for GNSS suppression
            let isActive = seg.state == .active || seg.state == .arming
            if isActive != internalEventActive {
                internalEventActive = isActive
                pipeline?.eventActive = isActive
            }
        }

        // Track event duration
        if internalEventActive, let onset = eventOnsetTime {
            internalCurrentEventDuration = output.time - onset
        }

        // Feed scorer during active events
        if internalEventActive {
            scorer?.addSample(time: output.time,
                             pitch: output.pitch,
                             pitchRate: output.pitchRate,
                             roll: output.roll)
        }

        // Bridge to TelemetrySample for UI
        let telemetrySample = bridgeToTelemetrySample(output)
        collectedSamples.append(telemetrySample)

        // Stage the latest display values (still under `processLock`, no `await`).
        // `flushDisplay()` copies these onto the observable properties on the main
        // actor at the 30 Hz display tick.
        pendingDisplay.pitch = pitchDeg
        pendingDisplay.pitchRate = pitchRateDeg
        pendingDisplay.roll = rollDeg
        pendingDisplay.speed = speedKPH
        pendingDisplay.speedAvailable = speedAvailable
        pendingDisplay.vibration = vibration
        pendingDisplay.eventActive = internalEventActive
        pendingDisplay.currentEventDuration = internalEventActive ? internalCurrentEventDuration : 0
        pendingDisplay.sampleCount = internalSampleCount
        pendingDisplay.rawLogSizeBytes = internalRawLogSizeBytes
    }

    // MARK: - Event handling

    private func handleTransition(_ transition: EventSegmenter.Transition,
                                  at time: TimeInterval,
                                  speed: Double?) {
        switch transition.kind {
        case .onset(let onsetTime):
            log.info("Event onset at \(onsetTime, format: .fixed(precision: 3))s")
            diag.always(time: onsetTime, level: .info, message: "event onset",
                        values: ["onset": onsetTime, "speed": speed ?? -1])
            scorer?.beginEvent(onset: onsetTime, entrySpeed: speed)
            eventOnsetTime = onsetTime
            internalCurrentEventDuration = 0
            internalEventActive = true

        case .end(let endTime):
            log.info("Event end at \(endTime, format: .fixed(precision: 3))s")
            diag.always(time: endTime, level: .info, message: "event end",
                        values: ["end": endTime,
                                 "duration": eventOnsetTime.map { endTime - $0 } ?? -1])
            // (Removed `pipeline?.lastEventEndTime = endTime`: that core property was
            // deleted — it was write-only, two callers set it and nothing ever read
            // it, so the assignment no longer compiles and had no effect anyway.)
            finalizeCurrentEvent(at: endTime)
            internalEventActive = false
            eventOnsetTime = nil
            internalCurrentEventDuration = 0

        case .discarded(let duration):
            log.info("Event discarded (duration: \(duration, format: .fixed(precision: 3))s)")
            diag.always(time: time, level: .info, message: "event discarded",
                        values: ["duration": duration])
            internalEventActive = false
            eventOnsetTime = nil
            internalCurrentEventDuration = 0
            scorer = RunScorer(config: config)
        }
    }

    private func finalizeCurrentEvent(at endTime: TimeInterval) {
        guard let startDate = sessionStartDate,
              let sessionStart = sessionStartMonotonic,
              let onset = eventOnsetTime,
              let angleTarget = angleTarget,
              // A bike profile must exist for the event to be valid, but nothing
              // below consumes it: `WheelieRun` has no bike field, so the value is
              // required and then discarded. Kept as a requirement, not a binding.
              bikeProfileID != nil,
              let calibID = calibrationService.estimate?.id else {
            log.warning("Cannot finalize event — missing session context")
            return
        }

        // `collectedSamples` holds SESSION-relative elapsed values and spans the whole
        // session, but R19.4's display series is RUN-relative and covers the attempt.
        // Stored as-is, an attempt that began 85 s into a session plotted at x = 85 on
        // a 0...duration axis, leaving the left of the chart empty. Window to the
        // attempt and re-base to its onset.
        let onsetElapsed = onset - sessionStart
        let endElapsed = endTime - sessionStart

        var windowed = collectedSamples
            .filter { $0.elapsed >= onsetElapsed && $0.elapsed <= endElapsed }
            .map { sample in
                TelemetrySample(id: sample.id,
                                elapsed: sample.elapsed - onsetElapsed,
                                angleDegrees: sample.angleDegrees,
                                blurredAngleDegrees: nil,
                                speedKPH: sample.speedKPH)
            }

        // Jitter blur: the recorded-run cleaner. Zero-phase, so it removes vibration
        // wiggle without shifting the curve in time. It does NOT correct drift — see
        // JitterBlur — and cannot fail destructively; a run too short to blur simply
        // keeps raw values and is flagged so it is never shown as if it were cleaned.
        var flags: QualityFlags = []
        let rawAngles = windowed.map(\.angleDegrees)
        switch JitterBlur(config: config).blur(rawAngles) {
        case .success(let blurred):
            for i in windowed.indices { windowed[i].blurredAngleDegrees = blurred[i] }
        case .failure:
            flags.insert(.smoothingUnavailable)
        }

        // Both dates now share the onset origin, so `WheelieRun.duration` is the
        // ATTEMPT length. Previously `startedAt` was the session start while `endedAt`
        // was the attempt end, making duration "session start to attempt end" — which
        // is what inflated the chart's x-domain.
        let attemptStart = startDate.addingTimeInterval(onsetElapsed)
        let attemptEnd = startDate.addingTimeInterval(endElapsed)

        let run = WheelieRun(
            id: UUID(),
            startedAt: attemptStart,
            endedAt: attemptEnd,
            samples: windowed,
            configuration: RunConfigurationSnapshot(
                angleTarget: angleTarget,
                speedTarget: speedTarget,
                speedGaugeMaximum: speedGaugeMaximum,
                calibrationID: calibID
            ),
            qualityFlags: flags
        )

        // Queued, NOT saved here. This runs under `processLock`, usually on a sensor
        // thread; see `pendingSavedRuns` for why saving inline froze the app.
        pendingSavedRuns.append(run)
        diag.always(time: endTime, level: .info, message: "event finalized — windowed & queued",
                    values: ["collected": Double(collectedSamples.count),
                             "windowed": Double(windowed.count),
                             "onsetElapsed": onsetElapsed,
                             "endElapsed": endElapsed])
        collectedSamples.removeAll(keepingCapacity: true)

        // Reset scorer for next event
        scorer = RunScorer(config: config)
    }

    // MARK: - Bridge

    /// Converts a `PipelineOutput` (radians, m/s) to a `TelemetrySample` (degrees, km/h).
    private func bridgeToTelemetrySample(_ output: PipelineOutput) -> TelemetrySample {
        let elapsed: TimeInterval
        if let start = sessionStartMonotonic {
            elapsed = output.time - start
        } else {
            elapsed = 0
        }

        return TelemetrySample(
            id: UUID(),
            elapsed: elapsed,
            angleDegrees: output.pitch * 180 / .pi,
            // 0, not the pipeline's speed, when the speedometer is off. `maxSpeed`
            // and `averageSpeed` on `WheelieRun` are derived from this field, so this
            // is the single place that makes a run recorded with speed off report 0
            // everywhere it is read.
            speedKPH: speedEnabled ? (output.speed ?? 0) * 3.6 : 0
        )
    }
}


