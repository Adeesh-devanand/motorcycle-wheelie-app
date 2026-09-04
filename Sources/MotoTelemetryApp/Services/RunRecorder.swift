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

    private(set) var recordingState: RecordingState = .idle
    private(set) var livePitch: Double = 0           // degrees
    private(set) var livePitchRate: Double = 0       // deg/s
    private(set) var liveRoll: Double = 0            // degrees
    private(set) var liveSpeed: Double = 0           // km/h
    /// False when no GNSS fix has produced a valid speed yet. R15.3 forbids
    /// fabricating 0: a stationary bike and an absent fix must not look identical.
    /// `liveSpeed` stays 0 for compatibility; consult this before displaying it.
    private(set) var liveSpeedAvailable: Bool = false
    private(set) var liveVibration: Double = 0       // m/s²
    private(set) var eventActive: Bool = false
    private(set) var currentEventDuration: TimeInterval = 0
    private(set) var sampleCount: Int = 0

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

    /// Interpolated onset time of the attempt in progress. The live timer is
    /// `output.time - eventOnsetTime`; using `sessionStartMonotonic` instead made
    /// the timer jump straight to the session's elapsed time the moment an attempt
    /// began (a wheelie 85 s into a session displayed 85 s).
    private var eventOnsetTime: TimeInterval?

    /// Id of the calibration currently reflected in the pipeline's anchor. When a new
    /// estimate is adopted this changes, which is how a completed re-zero is detected.
    private var lastCalibrationID: UUID?
    /// Bias vector the attitude anchor was last established against — the reference
    /// for the material-change test in `processSample`.

    private var collectedSamples: [TelemetrySample] = []
    private var sessionStartDate: Date?
    private var sessionStartMonotonic: TimeInterval?
    private var bikeProfileID: UUID?
    private var angleTarget: MetricRange?

    private var motionTask: Task<Void, Never>?
    private var speedTask: Task<Void, Never>?

    /// Serialises `processSample` across the motion and speed tasks. The class is
    /// `@unchecked Sendable` and `@Observable`, neither of which provides any
    /// mutual exclusion.
    private let processLock = NSLock()

    private let log = Logger(subsystem: "com.mototelemetry.app", category: "RunRecorder")

    // MARK: - Diagnostics ("rec")

    private var diag = DiagnosticEmitter(sink: DiagnosticLog.shared, category: "rec")

    /// Records the raw, unprocessed sensor stream for desk replay. Behind a flag,
    /// default ON — the user needs data for the TestFlight bugs. Set false to skip.
    var rawRecordingEnabled = true
    private var rawRecorder: RawSampleRecorder?
    /// Current raw-log size in bytes, surfaced for the UI.
    private(set) var rawLogSizeBytes: UInt64 = 0
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

        motionTask = Task { [weak self] in
            guard let self else { return }
            for await sample in self.motionService.samples {
                self.processLock.lock()
                self.processSample(sample)
                self.processLock.unlock()
            }
        }

        speedTask = Task { [weak self] in
            guard let self else { return }
            for await sample in self.speedService.fixes {
                self.processLock.lock()
                self.processSample(sample)
                self.processLock.unlock()
            }
        }
    }

    /// Start the sensor stream WITHOUT a recording pipeline, so calibration (and the
    /// swipe that follows) can run before an alignment exists. `processSample` feeds
    /// every raw IMU sample to `CalibrationService` and then early-returns on the nil
    /// pipeline, so nothing is scored or stored yet. `startSession` later promotes
    /// this same running stream to a full recording session — the stream is never
    /// started twice.
    func startSensing(bikeProfileID: UUID) {
        guard recordingState == .idle else { return }
        self.bikeProfileID = bikeProfileID
        self.sessionStartMonotonic = ProcessInfo.processInfo.systemUptime
        startSensorTasks()
        recordingState = .sensing
        log.info("Sensing started (calibration phase) for bike \(bikeProfileID)")
    }

    func startSession(bikeProfileID: UUID,
                      mountAlignment: MountAlignment,
                      angleTarget: MetricRange) {
        // Reachable from .idle (no prior sensing) OR .sensing (calibration ran
        // first, the normal path). Refuse only if already recording.
        guard recordingState != .running else { return }

        self.bikeProfileID = bikeProfileID
        self.angleTarget = angleTarget
        self.sessionStartDate = Date()
        self.sessionStartMonotonic = ProcessInfo.processInfo.systemUptime
        self.collectedSamples = []
        self.sampleCount = 0
        self.lastCalibrationID = calibrationService.estimate?.id

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
            self?.diag.always(time: ProcessInfo.processInfo.systemUptime, level: .info,
                              message: "watchdog armed (2×2.5s)", values: [:])
            for _ in 0..<2 {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard let self, self.recordingState == .running else { return }
                if self.sampleCount > 0 { return }
            }
            guard let self,
                  self.recordingState == .running,
                  self.sampleCount == 0,
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
                                          "emitted": Double(self.sampleCount)])
                self.log.error("Motion callbacks arriving (\(raw)) but no paired samples emitted — pairing fault, not a hardware fault")
                return
            }

            self.diag.always(time: ProcessInfo.processInfo.systemUptime, level: .error,
                             message: "watchdog FIRED — reporting sensors unavailable",
                             values: ["sampleCount": Double(self.sampleCount),
                                      "rawCallbacks": 0])
            self.calibrationService.reportSensorsUnavailable(
                reason: "no IMU samples and no raw motion callbacks 5 s after starting motion updates")
        }
    }

    func stopSession() {
        guard recordingState != .idle else { return }

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
                             "sampleCount": Double(sampleCount)])

        motionTask?.cancel()
        speedTask?.cancel()
        motionTask = nil
        speedTask = nil

        motionService.stop()
        speedService.stop()
        cueRenderer?.stop()

        // If an event was in progress, finalize it
        if eventActive {
            finalizeCurrentEvent(at: ProcessInfo.processInfo.systemUptime)
        }

        pipeline = nil
        segmenter = nil
        scorer = nil
        recordingState = .idle
        rawRecorder?.finish()
        rawLogSizeBytes = rawRecorder?.fileSizeBytes ?? rawLogSizeBytes
        rawRecorder = nil
        log.info("Recording session stopped. Total samples: \(self.sampleCount)")
        diag.always(time: ProcessInfo.processInfo.systemUptime, level: .info,
                    message: "session stopped",
                    values: ["totalSamples": Double(sampleCount),
                             "rawLogBytes": Double(rawLogSizeBytes)])
    }

    // MARK: - Sample processing

    private func processSample(_ sample: Sample) {
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

        sampleCount += 1
        batchCount += 1

        // 1 Hz processing heartbeat (gated on output time), carrying cumulative
        // sample count, per-heartbeat batch size, live pitch and the raw-log size.
        if rawRecorder != nil { rawLogSizeBytes = rawRecorder!.fileSizeBytes }
        let emitted = diag.emit("processing", time: output.time, level: .info,
                                message: "rec heartbeat",
                                values: ["samples": Double(sampleCount),
                                         "batch": Double(batchCount),
                                         "pitchDeg": output.pitch * 180 / .pi,
                                         "rawLogBytes": Double(rawLogSizeBytes)])
        if emitted { batchCount = 0 }

        // Update live state (rad → deg, m/s → km/h)
        livePitch = output.pitch * 180 / .pi
        livePitchRate = output.pitchRate * 180 / .pi
        liveRoll = output.roll * 180 / .pi
        liveSpeedAvailable = output.speed != nil
        liveSpeed = (output.speed ?? 0) * 3.6
        liveVibration = output.vibration

        // No calibrationService.process(output): the beta pipeline has no live gate,
        // and calibration is driven directly by feedIMU above. Pipeline output no
        // longer carries a gate verdict to track.

        // Warning tone: beep rate, carrier pitch and volume all rise with the
        // live ANGLE alone; solid tone past the limit angle. The predictive
        // CueEngine that once also drove a UI badge was removed — it read pitch
        // RATE, never reached the speaker, and was dead weight once the cue was
        // decided as angle-only.
        cueRenderer?.update(pitchDegrees: livePitch)

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
            if isActive != eventActive {
                eventActive = isActive
                pipeline?.eventActive = isActive
            }
        }

        // Track event duration
        if eventActive, let onset = eventOnsetTime {
            currentEventDuration = output.time - onset
        }

        // Feed scorer during active events
        if eventActive {
            scorer?.addSample(time: output.time,
                             pitch: output.pitch,
                             pitchRate: output.pitchRate,
                             roll: output.roll)
        }

        // Bridge to TelemetrySample for UI
        let telemetrySample = bridgeToTelemetrySample(output)
        collectedSamples.append(telemetrySample)
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
            currentEventDuration = 0
            eventActive = true

        case .end(let endTime):
            log.info("Event end at \(endTime, format: .fixed(precision: 3))s")
            diag.always(time: endTime, level: .info, message: "event end",
                        values: ["end": endTime,
                                 "duration": eventOnsetTime.map { endTime - $0 } ?? -1])
            pipeline?.lastEventEndTime = endTime
            finalizeCurrentEvent(at: endTime)
            eventActive = false
            eventOnsetTime = nil
            currentEventDuration = 0

        case .discarded(let duration):
            log.info("Event discarded (duration: \(duration, format: .fixed(precision: 3))s)")
            diag.always(time: time, level: .info, message: "event discarded",
                        values: ["duration": duration])
            eventActive = false
            eventOnsetTime = nil
            currentEventDuration = 0
            scorer = RunScorer(config: config)
        }
    }

    private func finalizeCurrentEvent(at endTime: TimeInterval) {
        guard let startDate = sessionStartDate,
              let sessionStart = sessionStartMonotonic,
              let onset = eventOnsetTime,
              let angleTarget = angleTarget,
              let bikeID = bikeProfileID,
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
                speedTarget: MetricRange(lower: 0, upper: 100),
                speedGaugeMaximum: 100,
                calibrationID: calibID
            ),
            qualityFlags: flags
        )

        repository.save(run)
        diag.always(time: endTime, level: .info, message: "event finalized — windowed & saved",
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
            speedKPH: (output.speed ?? 0) * 3.6
        )
    }
}


