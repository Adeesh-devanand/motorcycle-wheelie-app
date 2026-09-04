import Foundation
import MotoTelemetryCore
import Observation
import os

/// Drives calibration for the beta "calibrate-once" flow and holds its result.
///
/// ## What this is now, and what it used to be
/// This was rebuilt when the app moved to calibrate-on-every-launch with no
/// persistence. The previous version negotiated a re-calibration against a STORED
/// estimate — a whole machine of auto-start budgets, cooldowns, staleness tracking
/// and generation counters existed to answer "the bike has a saved zeroing; may we
/// quietly redo it, and when?". None of that applies here: the app cannot ride
/// until it has calibrated, so calibration is an explicit front-of-flow step, not a
/// background decision. `CalibrationTracker`, the auto-start latch, and the
/// generation counter are gone with it.
///
/// It also no longer consumes `PipelineOutput.gateOpen` — the beta pipeline has no
/// live gate. Calibration is driven directly by feeding raw IMU samples to
/// `BiasEstimator`, whose own internal gate decides when the bike is still enough.
///
/// ## The two products
/// A completed calibration yields a `BiasEstimate` carrying BOTH the gyro bias `b`
/// AND the gravity anchor `measuredGravity`. The gravity vector is what the swipe
/// screen consumes to build the mount alignment; without it there is no alignment
/// at all, since there is deliberately no preset fallback.
@Observable
final class CalibrationService: @unchecked Sendable {

    /// Phase of the launch-time calibration flow, as the UI sees it.
    enum Phase: Equatable {
        /// Waiting for the first sample, or actively collecting. `progress` is nil
        /// until enough samples exist to measure it.
        case measuring(progress: Double?)
        /// The still-window completed; `estimate` carries `b` and the gravity anchor.
        /// The app advances to the swipe screen on this.
        case measured(BiasEstimate)
        /// The attempt failed (too noisy, or the gate never opened). The rider retries.
        case failed(message: String)
        /// The motion hardware reported itself missing — a measurement, never a default.
        case unavailable
    }

    private(set) var phase: Phase = .measuring(progress: nil)
    private(set) var hasSeenSample = false

    /// Which gate condition last reset the dwell, phrased for the rider. This is the
    /// per-sample reason the calibration screen shows the instant the countdown
    /// resets — "too much vibration", "still moving" — rather than a generic wait.
    private(set) var blockingReason: String?

    /// The completed estimate, once `.measured`. Read by the swipe flow.
    var estimate: BiasEstimate? {
        if case .measured(let e) = phase { return e }
        return nil
    }

    /// Alias kept for callers that seed the pipeline from the completed zeroing.
    /// Same value as `estimate`; the old name lives on where it reads naturally.
    var currentEstimate: BiasEstimate? { estimate }

    /// `phase` projected onto the UI-facing `CalibrationState` the status pill and
    /// overlay already consume. The two enums are the same four situations under
    /// different names, so the mapping is total and lossless:
    ///   .measuring(p) -> .calibrating(p)   (p is the fraction of the 2 s window done)
    ///   .measured(e)  -> .calibrated
    ///   .failed(m)    -> .failed(m)
    ///   .unavailable  -> .unavailable
    var state: CalibrationState {
        switch phase {
        case .measuring(let progress):
            return .calibrating(progress: progress)
        case .measured(let estimate):
            return .calibrated(referenceID: estimate.id, calibratedAt: estimate.wallClock)
        case .failed(let message):
            return .failed(message: message)
        case .unavailable:
            return .unavailable
        }
    }

    private let config: Config
    private var estimator: BiasEstimator?
    private var bikeProfileID: UUID
    private let lock = NSLock()
    private let log = Logger(subsystem: "com.mototelemetry.app", category: "CalibrationService")
    private var diag = DiagnosticEmitter(sink: DiagnosticLog.shared, category: "cal")

    init(config: Config = Config(), bikeProfileID: UUID = UUID()) {
        self.config = config
        self.bikeProfileID = bikeProfileID
        self.estimator = BiasEstimator(config: config,
                                       bikeProfileID: bikeProfileID,
                                       thermalState: ProcessInfo.processInfo.thermalState.rawValue,
                                       sink: DiagnosticLog.shared)
    }

    /// Feed one raw IMU sample. Called from `RunRecorder` on the sensor task.
    func feedIMU(_ sample: IMUSample) {
        lock.lock()
        defer { lock.unlock() }

        if !hasSeenSample {
            hasSeenSample = true
            if phase == .unavailable {
                // A sample IS the sensors working: clear a prior unavailable verdict.
                phase = .measuring(progress: nil)
                restartLocked()
            }
            diag.always(time: sample.time, level: .info,
                        message: "first IMU sample — cal path live", values: [:])
        }

        guard var est = estimator else { return }
        guard let progress = est.process(sample) else { estimator = est; return }
        estimator = est
        handle(progress, at: sample.time)
    }

    /// Rider tapped "recalibrate", or the swipe screen sent them back. Discards the
    /// current attempt and starts a fresh still-window.
    func restart() {
        lock.lock()
        defer { lock.unlock() }
        restartLocked()
    }

    private func restartLocked() {
        estimator = BiasEstimator(config: config,
                                  bikeProfileID: bikeProfileID,
                                  thermalState: ProcessInfo.processInfo.thermalState.rawValue,
                                  sink: DiagnosticLog.shared)
        blockingReason = nil
        phase = .measuring(progress: nil)
        log.info("Calibration (re)started")
    }

    /// Called by the sensor layer when the motion hardware reports itself missing.
    /// The ONLY route to `.unavailable` — a measurement, never a default.
    func reportSensorsUnavailable(reason: String) {
        lock.lock()
        defer { lock.unlock() }
        log.error("Motion sensors unavailable: \(reason)")
        phase = .unavailable
    }

    // MARK: - Progress handling

    private func handle(_ progress: BiasEstimator.Progress, at time: TimeInterval) {
        switch progress {
        case .collecting(_, _, _, _):
            blockingReason = nil
            phase = .measuring(progress: progress.fraction)

        case .rejected(let reason):
            // The dwell reset. Name WHY on the sample that reset it — this is the
            // "too much vibration / still moving" feedback the calibration screen
            // surfaces in real time, and the behaviour the rider valued on the ride.
            blockingReason = Self.riderText(for: reason)
            phase = .measuring(progress: nil)

        case .done(let estimate):
            blockingReason = nil
            phase = .measured(estimate)
            log.info("Calibration complete. Sigma \(estimate.worstSigma * 180 / .pi, format: .fixed(precision: 4)) deg/s, gravity \(estimate.measuredGravity != nil ? "captured" : "MISSING")")

        case .failed(let failure):
            blockingReason = nil
            phase = .failed(message: failure.message)
            log.warning("Calibration failed: \(failure.message)")
        }
    }

    /// Rider-facing phrasing for each gate reason. `.vibrating` is the condition
    /// added this cycle: an idling engine swings |f| direction while its mean stays
    /// at 1 g, so it passes the magnitude band but not the spread test.
    static func riderText(for reason: ValidityGate.Reason) -> String? {
        switch reason {
        case .open, .noData:            return nil
        case .rotating:                 return "Still moving — hold it steady"
        case .specificForceOutOfBand:   return "Being moved or tilted — let it settle"
        case .vibrating:                return "Too much vibration — switch the engine off"
        case .saturated:                return "Vibration is off the scale — improve the mount"
        case .dwellNotMet:              return "Almost — keep it still a moment longer"
        }
    }
}
