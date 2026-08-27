import Foundation
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
    private(set) var liveGateOpen: Bool = false
    private(set) var liveCueState: CueState = CueState()
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
    private var cueEngine: CueEngine?
    private var segmenter: EventSegmenter?
    private var scorer: RunScorer?

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

    private var motionTask: Task<Void, Never>?
    private var speedTask: Task<Void, Never>?

    /// Serialises `processSample` across the motion and speed tasks. The class is
    /// `@unchecked Sendable` and `@Observable`, neither of which provides any
    /// mutual exclusion.
    private let processLock = NSLock()

    private let log = Logger(subsystem: "com.mototelemetry.app", category: "RunRecorder")

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

    func startSession(bikeProfileID: UUID,
                      mountAlignment: MountAlignment,
                      angleTarget: MetricRange) {
        guard recordingState == .idle else { return }

        self.bikeProfileID = bikeProfileID
        self.angleTarget = angleTarget
        self.sessionStartDate = Date()
        self.sessionStartMonotonic = ProcessInfo.processInfo.systemUptime
        self.collectedSamples = []
        self.sampleCount = 0

        // Initialize pipeline with current calibration
        pipeline = Pipeline(
            config: config,
            alignment: mountAlignment,
            initialBias: calibrationService.currentEstimate
        )

        // Initialize downstream stages
        cueEngine = CueEngine(
            angleTargetUpper: angleTarget.upper * .pi / 180,
            timeToThresholdWarn: config.timeToThresholdWarn,
            audioLatencyCompensation: config.audioLatencyCompensation,
            loopOutPitchRate: config.loopOutPitchRate,
            cueReleaseTime: config.cueReleaseTime
        )
        segmenter = EventSegmenter(config: config)
        scorer = RunScorer(config: config)

        // Start sensor consumption
        motionService.start()
        speedService.start()
        cueRenderer?.start()

        // Both sensor streams funnel through `processSample`, which mutates the
        // value-type `EventSegmenter` with a read-modify-write. These are two
        // independent Tasks on the cooperative pool, so without serialisation two
        // resumptions can each read the SAME pre-write segmenter state, both
        // satisfy the `.arming` guard, and both emit `.onset` — which is the
        // "multiple wheelies start at the same time" symptom. The lock makes the
        // read-modify-write atomic; the critical section is ~200 µs against a
        // 10 ms sample budget.
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

        recordingState = .running
        log.info("Recording session started for bike \(bikeProfileID)")

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
            for _ in 0..<2 {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard let self, self.recordingState == .running else { return }
                if self.sampleCount > 0 { return }
            }
            guard let self,
                  self.recordingState == .running,
                  self.sampleCount == 0,
                  !self.calibrationService.hasSeenSample else { return }
            self.calibrationService.reportSensorsUnavailable(
                reason: "no IMU samples 5 s after starting motion updates")
        }
    }

    func stopSession() {
        guard recordingState != .idle else { return }

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
        cueEngine = nil
        segmenter = nil
        scorer = nil
        recordingState = .idle
        log.info("Recording session stopped. Total samples: \(self.sampleCount)")
    }

    // MARK: - Sample processing

    private func processSample(_ sample: Sample) {
        guard var pipe = pipeline else { return }

        // Feed raw IMU to calibration service for ongoing zeroing
        if case .imu(let imu) = sample, let bikeID = bikeProfileID {
            calibrationService.feedIMU(imu, bikeProfileID: bikeID)
        }

        // Run through pipeline
        guard let output = pipe.process(sample) else {
            pipeline = pipe
            return
        }
        pipeline = pipe

        sampleCount += 1

        // Update live state (rad → deg, m/s → km/h)
        livePitch = output.pitch * 180 / .pi
        livePitchRate = output.pitchRate * 180 / .pi
        liveRoll = output.roll * 180 / .pi
        liveSpeedAvailable = output.speed != nil
        liveSpeed = (output.speed ?? 0) * 3.6
        liveVibration = output.vibration
        liveGateOpen = output.gateOpen

        // Feed calibration pipeline-level tracking
        if let bikeID = bikeProfileID {
            calibrationService.process(output, bikeProfileID: bikeID)
        }

        // Cue engine
        if var cue = cueEngine {
            let cueState = cue.process(pitch: output.pitch,
                                       pitchRate: output.pitchRate,
                                       time: output.time)
            cueEngine = cue
            liveCueState = cueState
            cueRenderer?.update(cueState)
        }

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
            scorer?.beginEvent(onset: onsetTime, entrySpeed: speed)
            eventOnsetTime = onsetTime
            currentEventDuration = 0
            eventActive = true

        case .end(let endTime):
            log.info("Event end at \(endTime, format: .fixed(precision: 3))s")
            pipeline?.lastEventEndTime = endTime
            finalizeCurrentEvent(at: endTime)
            eventActive = false
            eventOnsetTime = nil
            currentEventDuration = 0

        case .discarded(let duration):
            log.info("Event discarded (duration: \(duration, format: .fixed(precision: 3))s)")
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
              let calibID = calibrationService.currentEstimate?.id else {
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

        let windowed = collectedSamples
            .filter { $0.elapsed >= onsetElapsed && $0.elapsed <= endElapsed }
            .map { sample in
                TelemetrySample(id: sample.id,
                                elapsed: sample.elapsed - onsetElapsed,
                                angleDegrees: sample.angleDegrees,
                                speedKPH: sample.speedKPH)
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
            )
        )

        repository.save(run)
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


