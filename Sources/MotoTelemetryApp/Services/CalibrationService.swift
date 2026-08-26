import Foundation
import MotoTelemetryCore
import Observation
import os

/// Bridges the core `BiasEstimator` and `CalibrationTracker` into an app-level
/// observable. Consumes `PipelineOutput` gate verdicts to decide when stationary
/// calibration can proceed, and exposes the result as a UI-friendly `CalibrationState`.
@Observable
final class CalibrationService: @unchecked Sendable {

    // MARK: - Published state

    private(set) var state: CalibrationState = .unavailable
    private(set) var biasAge: TimeInterval?

    // MARK: - Internal (for RunRecorder)

    var currentEstimate: BiasEstimate? { tracker.status.estimate }

    // MARK: - Private

    private let config: Config
    private var estimator: BiasEstimator?
    private var tracker: CalibrationTracker
    private var gateOpenAccumulator: TimeInterval = 0
    private var lastGateOpenTime: TimeInterval?
    private var recalibrationRequested = false
    /// True once calibration has been started automatically. Prevents an endless
    /// failed → calibrating → failed loop, which would fire at the sample rate.
    private var hasAutoStarted = false

    private let log = Logger(subsystem: "com.mototelemetry.app", category: "CalibrationService")

    // MARK: - Init

    init(config: Config = Config(), bikeProfileID: UUID = UUID()) {
        self.config = config
        self.tracker = CalibrationTracker(config: config)
    }

    // MARK: - Pipeline consumption

    /// Feed every `PipelineOutput` from the live pipeline. The service uses gate
    /// state to drive calibration and track staleness.
    func process(_ output: PipelineOutput, bikeProfileID: UUID) {
        let now = output.time

        // Update bias age tracking
        tracker.update(now: now)
        biasAge = tracker.age(at: now)

        // Check for thermal-induced staleness
        let thermalState = ProcessInfo.processInfo.thermalState.rawValue
        tracker.update(now: now, thermalState: thermalState)

        syncState()

        // If already calibrated and not stale/recalibration-requested, nothing to do
        if !recalibrationRequested, case .calibrated = tracker.status { return }

        // Track gate-open duration for auto-calibration trigger
        if output.gateOpen {
            if lastGateOpenTime == nil { lastGateOpenTime = now }
            gateOpenAccumulator = now - (lastGateOpenTime ?? now)
        } else {
            lastGateOpenTime = nil
            gateOpenAccumulator = 0
        }

        // Start estimator when gate has been open long enough
        if gateOpenAccumulator >= 0.5 || recalibrationRequested {
            if estimator == nil {
                estimator = BiasEstimator(
                    config: config,
                    bikeProfileID: bikeProfileID,
                    thermalState: thermalState
                )
                state = .calibrating(progress: 0)
                log.info("Calibration started")
            }
        }

        // Feed IMU-equivalent to the estimator if active
        // The estimator needs raw IMU; we reconstruct from pipeline output fields
        guard var est = estimator else { return }
        let imuProxy = IMUSample(
            time: now,
            rotationRate: output.gyroBias, // estimator uses raw rate; bias field is the current estimate
            specificForce: .zero,           // gate verdict already determined externally
            saturated: false
        )
        // NOTE: In practice the estimator should be fed the actual IMU stream directly.
        // This proxy path is a placeholder — the real integration feeds raw IMU from MotionService.
        _ = imuProxy
        estimator = est
    }

    /// Direct IMU feed for calibration — called from RunRecorder with raw samples
    /// while the pipeline also runs. This is the real calibration path.
    func feedIMU(_ sample: IMUSample, bikeProfileID: UUID) {
        let thermalState = ProcessInfo.processInfo.thermalState.rawValue

        // Auto-start ONCE on the first sample, or whenever the user explicitly
        // asks for a recalibration. Never auto-restart after a failure — the
        // failure is the answer, and restarting at 100 Hz just thrashes the UI.
        if estimator == nil && (!hasAutoStarted || recalibrationRequested) {
            hasAutoStarted = true
            estimator = BiasEstimator(
                config: config,
                bikeProfileID: bikeProfileID,
                thermalState: thermalState
            )
            state = .calibrating(progress: 0)
        }

        guard var est = estimator else { return }

        if let progress = est.process(sample) {
            estimator = est
            handleProgress(progress)
        } else {
            estimator = est
        }
    }

    // MARK: - User actions

    /// Tappable pill: force re-calibration even if current estimate is valid.
    func requestRecalibration() {
        recalibrationRequested = true
        estimator?.restart()
        estimator = nil
        state = .calibrating(progress: nil)
        log.info("Recalibration requested by user")
    }

    /// Called when the bike profile changes — invalidates the current calibration.
    func invalidate(reason: CalibrationStaleReason) {
        let mappedReason: MotoTelemetryCore.CalibrationStaleReason
        switch reason {
        case .timeout:          mappedReason = .aged
        case .thermalDrift:     mappedReason = .thermalShift
        case .biasAgeExceeded:  mappedReason = .aged
        }
        tracker.invalidate(mappedReason)
        syncState()
    }

    // MARK: - Private

    private func handleProgress(_ progress: BiasEstimator.Progress) {
        switch progress {
        case .collecting(let elapsed, let required):
            state = .calibrating(progress: elapsed / required)

        case .rejected:
            // Gate closed mid-calibration; reset and wait for next window
            gateOpenAccumulator = 0
            lastGateOpenTime = nil
            // Don't clear estimator — it resets internally on next gate open

        case .done(let estimate):
            tracker.adopt(estimate)
            recalibrationRequested = false
            estimator = nil
            state = .calibrated(referenceID: estimate.id, calibratedAt: estimate.wallClock)
            log.info("Calibration complete. Sigma: \(estimate.worstSigma * 180 / .pi, format: .fixed(precision: 4)) deg/s")

        case .failed(let failure):
            estimator = nil
            recalibrationRequested = false
            state = .failed(message: failure.message)
            log.warning("Calibration failed: \(failure.message)")
        }
    }

    private func syncState() {
        switch tracker.status {
        case .unavailable:
            if case .calibrating = state { return } // Don't overwrite active calibration
            state = .unavailable
        case .calibrating:
            break // Handled by estimator progress
        case .calibrated(let est):
            state = .calibrated(referenceID: est.id, calibratedAt: est.wallClock)
        case .stale(_, let reason):
            switch reason {
            case .aged:             state = .stale(reason: .biasAgeExceeded)
            case .thermalShift:     state = .stale(reason: .thermalDrift)
            case .bikeProfileChanged: state = .stale(reason: .timeout)
            case .remounted:        state = .stale(reason: .timeout)
            }
        case .failed(let failure):
            state = .failed(message: failure.message)
        }
    }
}
