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

    /// Starts as `calibrating` with an indeterminate progress, NOT `.unavailable`.
    ///
    /// Before any sample has arrived we know nothing: claiming the sensors are
    /// unavailable would be a diagnosis nobody measured, and it sent the rider to
    /// check a permission that was never the problem. `.unavailable` is now set
    /// only when the hardware genuinely reports itself missing (see
    /// `reportSensorsUnavailable`).
    private(set) var state: CalibrationState = .calibrating(progress: nil)

    /// True once at least one IMU sample has been seen. Distinguishes "waiting for
    /// the first sample" from "the sensor path is broken".
    private(set) var hasSeenSample = false
    private(set) var biasAge: TimeInterval?

    /// Which validity-gate condition is currently blocking calibration, if any.
    /// Required by R6.2 so the overlay can name the failing condition instead of
    /// showing a generic wait message.
    private(set) var gateReason: ValidityGate.Reason?

    /// `gateReason` phrased for the rider, or nil when nothing is blocking.
    var blockingReasonText: String? {
        switch gateReason {
        case .none, .some(.open):
            return nil
        case .some(.rotating):
            return "Still moving — hold the phone steadier"
        case .some(.specificForceOutOfBand):
            return "Being accelerated or shaken — let it settle"
        case .some(.dwellNotMet):
            return "Almost — keep it still a moment longer"
        case .some(.saturated):
            return "Sensor overloaded by vibration — improve the mount"
        case .some(.noData):
            return "No sensor data arriving"
        }
    }

    // MARK: - Internal (for RunRecorder)

    var currentEstimate: BiasEstimate? { tracker.status.estimate }

    // MARK: - Private

    private let config: Config
    private var estimator: BiasEstimator?
    private var tracker: CalibrationTracker
    private var gateOpenAccumulator: TimeInterval = 0
    private var lastGateOpenTime: TimeInterval?
    private var recalibrationRequested = false
    /// Guards every mutation below. `feedIMU` runs on the sensor Task while
    /// `requestRecalibration` runs on the main thread from a button tap, and
    /// `@Observable` provides no mutual exclusion.
    private let lock = NSLock()
    /// Incremented by every recalibration request; the estimator records which
    /// generation produced it. A stale `estimator = est` write-back from the sensor
    /// thread can therefore no longer resurrect a discarded estimator and wedge the
    /// screen on "Waiting for stable position" — the generation will not match, so
    /// a fresh estimator is built regardless.
    private var recalibrationGeneration = 0
    private var estimatorGeneration = -1
    /// How many times calibration has been auto-started this session.
    ///
    /// This replaces a one-shot `hasAutoStarted` flag that was never reset. With
    /// the flag, the FIRST failure wedged the screen permanently: `handleProgress`
    /// clears `estimator` and `recalibrationRequested` on `.failed`, so the
    /// auto-start condition could never be true again and no further sample did
    /// anything. A bounded retry keeps the original intent — no 100 Hz
    /// failed → calibrating → failed thrash — while letting a transient cause
    /// (one unpaired sample, a bump, someone sitting down) recover by itself.
    private var autoStartAttempts = 0
    private let maxAutoStartAttempts = 3
    /// Monotonic time of the last auto-start, gating the retry cooldown.
    private var lastAutoStartTime: TimeInterval?
    private let autoStartCooldown: TimeInterval = 2.0
    /// Retry interval once the rapid attempts are spent. The budget throttles, it no
    /// longer terminates: a calibration screen that can never retry is a dead screen,
    /// and the usual cause of a failed attempt is the rider still settling.
    private let exhaustedRetryCooldown: TimeInterval = 10.0

    private let log = Logger(subsystem: "com.mototelemetry.app", category: "CalibrationService")

    // MARK: - Diagnostics ("cal")

    /// Heartbeat channel keyed on the state name; one-shot causes go through `always`.
    private var diag = DiagnosticEmitter(sink: DiagnosticLog.shared, category: "cal")

    /// Records a state transition old -> new WITH its cause. Called under `lock`.
    /// `stateName` collapses the enum to a stable greppable token; `gateReason` is
    /// logged alongside so the "stale gateReason over a .failed state" hypothesis
    /// (bug 3) is directly visible in the log.
    private func logStateTransition(_ new: CalibrationState, cause: String, at time: TimeInterval,
                                    extra: [String: Double] = [:]) {
        let old = Self.stateName(state)
        let newName = Self.stateName(new)
        var v = extra
        v["gateReasonSet"] = gateReason == nil ? 0 : 1
        let level: DiagnosticEvent.Level = (newName == "failed" || newName == "unavailable") ? .warn : .info
        diag.always(time: time, level: level,
                    message: "state \(old) -> \(newName) [\(cause)]", values: v)
    }

    private static func stateName(_ s: CalibrationState) -> String {
        switch s {
        case .calibrating:  return "calibrating"
        case .calibrated:   return "calibrated"
        case .failed:       return "failed"
        case .stale:        return "stale"
        case .unavailable:  return "unavailable"
        }
    }

    private static func reasonName(_ r: ValidityGate.Reason?) -> String {
        guard let r else { return "none" }
        return r.rawValue
    }

    // MARK: - Init

    init(config: Config = Config(), bikeProfileID: UUID = UUID()) {
        self.config = config
        self.tracker = CalibrationTracker(config: config, sink: Self.coreSink)
    }

    /// The core-stage sink (bias/gate/eskf/caltrack lines land here with sample
    /// time). Same singleton the app-side channels use, so all lines interleave.
    private static let coreSink: DiagnosticSink = DiagnosticLog.shared

    // MARK: - Pipeline consumption

    /// Feed every `PipelineOutput` from the live pipeline. The service uses gate
    /// state to drive calibration and track staleness.
    func process(_ output: PipelineOutput, bikeProfileID: UUID) {
        let now = output.time

        // Same lock as `feedIMU`. This path also mutates `state`, `estimator` and the
        // gate accumulators, so without it the pipeline task and the sensor task race
        // on exactly the fields the overlay reads.
        lock.lock()
        defer { lock.unlock() }

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
                    thermalState: thermalState,
                    sink: Self.coreSink
                )
                state = .calibrating(progress: 0)
                log.info("Calibration started")
            }
        }

        // Feed IMU-equivalent to the estimator if active
        // NOTE: calibration is driven entirely by `feedIMU`, which receives real raw
        // IMU samples. A placeholder block here used to rebuild a proxy `IMUSample`
        // with `specificForce: .zero`, discard it, and then write `estimator = est`
        // back. That round-trip did no work but was a read-modify-write on
        // `estimator` from a second thread, which could resurrect an estimator that
        // `requestRecalibration()` had just discarded. Removed deliberately.
    }

    /// Direct IMU feed for calibration — called from RunRecorder with raw samples
    /// while the pipeline also runs. This is the real calibration path.
    func feedIMU(_ sample: IMUSample, bikeProfileID: UUID) {
        let thermalState = ProcessInfo.processInfo.thermalState.rawValue

        lock.lock()
        defer { lock.unlock() }

        if !hasSeenSample {
            hasSeenSample = true
            log.info("First IMU sample received — sensor path is live")
            diag.always(time: sample.time, level: .info, message: "first IMU sample — cal path live",
                        values: [:])
        }

        // A sample IS the sensors working. `.unavailable` is set by RunRecorder's
        // 2.5 s watchdog, which fires whenever a restarted session sees no samples
        // in time; without this recovery the screen stayed on "Motion sensors
        // unavailable / Check device permissions" with no way past it even though
        // data was flowing again. Measured presence must clear it, exactly as
        // measured absence sets it.
        if state == .unavailable {
            log.info("IMU samples resumed — clearing unavailable state")
            logStateTransition(.calibrating(progress: nil), cause: "IMU resumed", at: sample.time)
            state = .calibrating(progress: nil)
            estimator = nil
            autoStartAttempts = 0
            lastAutoStartTime = nil
        }

        // Auto-start on the first sample, and retry a bounded number of times
        // after a failure so a transient cause does not wedge the screen. An
        // explicit user request always starts, regardless of the budget.
        //
        // FIX (bug 1, the permanent wedge): the budget is no longer TERMINAL. Once
        // `autoStartAttempts` reached `maxAutoStartAttempts`, no sample could ever
        // start an estimator again and only a manual tap could recover — so a rider
        // who hit three transient failures had a screen that never came back. The
        // budget now only governs how FAST retries happen: `maxAutoStartAttempts`
        // rapid attempts at `autoStartCooldown`, then an indefinite slow retry at
        // `exhaustedRetryCooldown`. Backing off is right; giving up is not, because the
        // cause is usually the rider still settling and it clears by itself.
        let attemptsExhausted = autoStartAttempts >= maxAutoStartAttempts
        let requiredCooldown = attemptsExhausted ? exhaustedRetryCooldown : autoStartCooldown
        let cooldownElapsed = lastAutoStartTime.map { sample.time - $0 >= requiredCooldown } ?? true
        let canAutoStart = cooldownElapsed
        // A pending request outranks whatever `estimator` currently holds: a stale
        // write-back may have resurrected a FINISHED estimator, whose `process()`
        // returns nil forever, so `handleProgress` never runs and the state stays
        // on `.calibrating(progress: nil)` permanently.
        let generationStale = estimatorGeneration != recalibrationGeneration
        if generationStale {
            diag.always(time: sample.time, level: .warn, message: "estimator generation mismatch — rebuilding",
                        values: ["estimatorGen": Double(estimatorGeneration),
                                 "recalGen": Double(recalibrationGeneration)])
            estimator = nil
        }

        // BUG 1/3 instrumentation: heartbeat the auto-start budget so the
        // "flickers then wedges" retry exhaustion is visible. Once
        // autoStartAttempts == maxAutoStartAttempts and no estimator exists, no
        // further sample can start one (only a user request will), which is the
        // permanent wedge. cooldownRemaining shows the 2 s gap between flickers.
        let cooldownRemaining = lastAutoStartTime.map { max(0, autoStartCooldown - (sample.time - $0)) } ?? 0
        diag.emit("autostart:\(estimator == nil ? "idle" : "active")", time: sample.time,
                  level: .info, message: "autostart status",
                  values: ["attempts": Double(autoStartAttempts),
                           "maxAttempts": Double(maxAutoStartAttempts),
                           "cooldownRemaining": cooldownRemaining,
                           "canAutoStart": canAutoStart ? 1 : 0,
                           "hasEstimator": estimator == nil ? 0 : 1,
                           "recalRequested": recalibrationRequested ? 1 : 0])

        if estimator == nil && (canAutoStart || recalibrationRequested || generationStale) {
            autoStartAttempts += 1
            lastAutoStartTime = sample.time
            estimatorGeneration = recalibrationGeneration
            estimator = BiasEstimator(
                config: config,
                bikeProfileID: bikeProfileID,
                thermalState: thermalState,
                sink: Self.coreSink
            )
            logStateTransition(.calibrating(progress: 0), cause: "auto-start attempt \(autoStartAttempts)",
                               at: sample.time,
                               extra: ["attempt": Double(autoStartAttempts),
                                       "maxAttempts": Double(maxAutoStartAttempts)])
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

    /// Called by the sensor layer when the motion hardware reports itself missing.
    /// This is the ONLY route to `.unavailable` — it must be a measurement, never
    /// a default.
    func reportSensorsUnavailable(reason: String) {
        log.error("Motion sensors unavailable: \(reason)")
        diag.always(time: ProcessInfo.processInfo.systemUptime, level: .error,
                    message: "reportSensorsUnavailable: \(reason)",
                    values: ["hasSeenSample": hasSeenSample ? 1 : 0])
        state = .unavailable
    }

    /// Tappable pill: force re-calibration even if current estimate is valid.
    func requestRecalibration() {
        lock.lock()
        defer { lock.unlock() }
        let t = ProcessInfo.processInfo.systemUptime
        diag.always(time: t, level: .info, message: "requestRecalibration",
                    values: ["recalGenBefore": Double(recalibrationGeneration),
                             "autoStartAttemptsBefore": Double(autoStartAttempts)])
        recalibrationRequested = true
        recalibrationGeneration += 1
        autoStartAttempts = 0
        lastAutoStartTime = nil
        gateReason = nil
        // Drop the adopted estimate. Two state sources exist — `tracker.status`
        // (core) and `state` (published) — and `process()` calls `syncState()` on
        // EVERY pipeline output, whose `.calibrated` case unconditionally assigns
        // `state = .calibrated(...)`. That runs BEFORE the
        // `if !recalibrationRequested … return` guard, so leaving the tracker
        // adopted meant the next sensor sample clobbered the `.calibrating` the
        // rider just asked for, and the two writers fought every cycle — the
        // overlay froze. A fresh tracker reports `.unavailable`, which `syncState()`
        // deliberately leaves alone, so the re-zero can actually proceed (R6.10).
        tracker = CalibrationTracker(config: config, sink: Self.coreSink)
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
            // Heartbeat only — collecting fires ~100 Hz, so gate on the "collecting"
            // key + sample-time heartbeat rather than per sample.
            diag.emit("collecting", time: ProcessInfo.processInfo.systemUptime,
                      level: .trace, message: "collecting",
                      values: ["elapsed": elapsed, "required": required,
                               "fraction": required > 0 ? elapsed / required : 0])

        case .rejected(let reason):
            // R6.2: a gate closure resets progress AND the UI reports WHY. Keeping
            // the reason is the difference between "Waiting for stable position",
            // which tells the rider nothing, and naming the one condition that is
            // actually failing.
            let old = Self.reasonName(gateReason)
            gateReason = reason
            gateOpenAccumulator = 0
            lastGateOpenTime = nil
            // Don't clear estimator — it resets internally on next gate open
            diag.emit("reject:\(reason.rawValue)", time: ProcessInfo.processInfo.systemUptime,
                      level: .info, message: "gate reason \(old) -> \(reason.rawValue)",
                      values: [:])

        case .done(let estimate):
            tracker.adopt(estimate)
            recalibrationRequested = false
            gateReason = nil
            estimator = nil
            let t = ProcessInfo.processInfo.systemUptime
            logStateTransition(.calibrated(referenceID: estimate.id, calibratedAt: estimate.wallClock),
                               cause: "estimator done", at: t,
                               extra: ["sigmaDeg": estimate.worstSigma * 180 / .pi])
            state = .calibrated(referenceID: estimate.id, calibratedAt: estimate.wallClock)
            log.info("Calibration complete. Sigma: \(estimate.worstSigma * 180 / .pi, format: .fixed(precision: 4)) deg/s")

        case .failed(let failure):
            estimator = nil
            recalibrationRequested = false
            // FIX (bug 3, the permanent stick): clear `gateReason`. Leaving it set
            // meant `blockingReasonText` kept returning the last gate complaint —
            // typically "Almost — keep it still a moment longer" — and the overlay
            // renders that unconditionally alongside the state text. The rider was
            // therefore shown a still-trying message over a state that had already
            // failed, with nothing indicating the attempt was over.
            gateReason = nil
            let t = ProcessInfo.processInfo.systemUptime
            let retriesRemain = autoStartAttempts < maxAutoStartAttempts

            // FIX (bug 1, the flicker): do not SHOW `.failed` while an automatic retry
            // is still coming. The auto-start budget re-arms after `autoStartCooldown`,
            // so surfacing `.failed` here produced exactly the reported symptom — the
            // overlay flipping failed → calibrating → failed a few times, 2 s apart,
            // for no reason the rider could act on. A retry that is about to happen is
            // still "calibrating"; only a genuinely exhausted attempt is a failure.
            if retriesRemain {
                logStateTransition(.calibrating(progress: nil),
                                   cause: "estimator failed, auto-retry pending", at: t,
                                   extra: ["autoStartAttempts": Double(autoStartAttempts),
                                           "maxAttempts": Double(maxAutoStartAttempts)])
                diag.always(time: t, level: .info,
                            message: "failed — retry pending, not surfaced to rider",
                            values: ["attemptsRemaining":
                                        Double(maxAutoStartAttempts - autoStartAttempts)])
                state = .calibrating(progress: nil)
                log.info("Calibration attempt failed, retrying: \(failure.message)")
                return
            }

            logStateTransition(.failed(message: failure.message),
                               cause: "estimator failed, retries exhausted", at: t,
                               extra: ["autoStartAttempts": Double(autoStartAttempts),
                                       "maxAttempts": Double(maxAutoStartAttempts)])
            state = .failed(message: failure.message)
            log.warning("Calibration failed: \(failure.message)")
        }
    }

    private func syncState() {
        switch tracker.status {
        case .unavailable:
            // The tracker reports `.unavailable` simply because it holds no
            // estimate yet — that is not evidence the sensors are missing. Leave
            // the state alone; only `reportSensorsUnavailable` may make that claim.
            break
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
