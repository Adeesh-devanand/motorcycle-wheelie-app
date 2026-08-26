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

    private var collectedSamples: [TelemetrySample] = []
    private var sessionStartDate: Date?
    private var sessionStartMonotonic: TimeInterval?
    private var bikeProfileID: UUID?
    private var angleTarget: MetricRange?

    private var motionTask: Task<Void, Never>?
    private var speedTask: Task<Void, Never>?

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

        motionTask = Task { [weak self] in
            guard let self else { return }
            for await sample in self.motionService.samples {
                self.processSample(sample)
            }
        }

        speedTask = Task { [weak self] in
            guard let self else { return }
            for await sample in self.speedService.fixes {
                self.processSample(sample)
            }
        }

        recordingState = .running
        log.info("Recording session started for bike \(bikeProfileID)")
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
        if eventActive, let start = sessionStartMonotonic {
            currentEventDuration = output.time - start
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
            eventActive = true

        case .end(let endTime):
            log.info("Event end at \(endTime, format: .fixed(precision: 3))s")
            pipeline?.lastEventEndTime = endTime
            finalizeCurrentEvent(at: endTime)
            eventActive = false
            currentEventDuration = 0

        case .discarded(let duration):
            log.info("Event discarded (duration: \(duration, format: .fixed(precision: 3))s)")
            eventActive = false
            currentEventDuration = 0
            scorer = RunScorer(config: config)
        }
    }

    private func finalizeCurrentEvent(at endTime: TimeInterval) {
        guard let startDate = sessionStartDate,
              let angleTarget = angleTarget,
              let bikeID = bikeProfileID,
              let calibID = calibrationService.currentEstimate?.id else {
            log.warning("Cannot finalize event — missing session context")
            return
        }

        let endDate = startDate.addingTimeInterval(endTime - (sessionStartMonotonic ?? 0))

        let run = WheelieRun(
            id: UUID(),
            startedAt: startDate,
            endedAt: endDate,
            samples: collectedSamples,
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


