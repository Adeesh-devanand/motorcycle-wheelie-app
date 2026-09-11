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

    /// How long a rider-facing reason stays on screen before a different one may replace
    /// it. Long enough to read a short sentence; short enough that the text still tracks
    /// what the bike is doing. See `publishReason`.
    private static let reasonMinimumDisplay: TimeInterval = 1.5

    /// When the currently displayed reason was published. Main actor, like the mirror it
    /// describes.
    @MainActor private var reasonShownAt: Date = .distantPast
    @MainActor private var reasonRepublishScheduled = false

    // MARK: - Authoritative state
    //
    // The three properties ABOVE are `@Observable` MIRRORS, written only on the main
    // actor. The three below are the AUTHORITATIVE state, written on the sensor
    // thread under `lock`.
    //
    // They used to be one and the same, and that is what hung the app on
    // re-calibrate. `feedIMU` runs on the sensor task at 100 Hz from inside
    // `RunRecorder.processLock`, and wrote these `@Observable` properties directly.
    // So the sensor thread took `processLock` -> `lock` -> the observation
    // registrar's internal state, while the main thread took the registrar's state
    // (re-rendering `CalibrationScreen`, which reads `phase` and `blockingReason`)
    // and then wanted `processLock` inside `stopSession()`. Two locks, acquired in
    // opposite orders.
    //
    // Re-calibrate is the ONE action that does all of it in a single run-loop turn —
    // mutate `phase` on the main actor, swap the view hierarchy so SwiftUI re-tracks
    // its dependencies, and call `stopSession` — which is why it hung every time and
    // why nothing else did. The 2026-09-08 device log shows it exactly:
    // "Calibration (re)started", then "onDisappear", and then `stopSession`'s FIRST
    // diagnostic never prints while only MotionService's lock-free `sensor heartbeat`
    // survives, forever.
    private var internalPhase: Phase = .measuring(progress: nil)
    private var internalBlockingReason: String?
    private var internalHasSeenSample = false
    /// At most one publish hop in flight, so 100 Hz of samples costs one main-actor
    /// hop per turn instead of a `Task` per sample.
    private var publishScheduled = false

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
    ///
    /// Writes only the lock-guarded authoritative state and asks for a main-actor
    /// publish. It must never touch the `@Observable` mirrors — see the note on
    /// `internalPhase` for the deadlock that caused.
    func feedIMU(_ sample: IMUSample) {
        lock.lock()
        defer { lock.unlock() }

        if !internalHasSeenSample {
            internalHasSeenSample = true
            if internalPhase == .unavailable {
                // A sample IS the sensors working: clear a prior unavailable verdict.
                internalPhase = .measuring(progress: nil)
                restartLocked()
            }
            diag.always(time: sample.time, level: .info,
                        message: "first IMU sample — cal path live", values: [:])
            schedulePublishLocked()
        }

        guard var est = estimator else { return }
        guard let progress = est.process(sample) else { estimator = est; return }
        estimator = est
        handle(progress, at: sample.time)
        schedulePublishLocked()
    }

    // MARK: - Publishing

    /// Ask for the mirrors to be refreshed on the main actor. Call with `lock` held.
    ///
    /// Coalesced: while a hop is already pending, further samples are free. Progress
    /// still lands within one main-actor turn, and the sensor thread never blocks on
    /// the main actor — it only enqueues.
    private func schedulePublishLocked() {
        guard !publishScheduled else { return }
        publishScheduled = true
        Task { @MainActor [weak self] in
            self?.publish()
        }
    }

    /// Copy authoritative state onto the `@Observable` mirrors. Main actor only.
    @MainActor
    private func publish() {
        lock.lock()
        publishScheduled = false
        let newPhase = internalPhase
        let newReason = internalBlockingReason
        let newSeen = internalHasSeenSample
        lock.unlock()

        // Guarded so an unchanged value does not invalidate a SwiftUI view — the
        // `.collecting` path re-publishes the same phase on most samples.
        if phase != newPhase { phase = newPhase }
        if hasSeenSample != newSeen { hasSeenSample = newSeen }
        publishReason(newReason)
    }

    /// Move `blockingReason` toward `newReason`, but never faster than a rider can read.
    ///
    /// The authoritative reason is per-sample, and on an unsteady phone the gate rejects
    /// for a DIFFERENT cause from one sample to the next — rotating, then out of band,
    /// then dwell-not-met, with `.collecting` (nil) interleaved. Published raw at sensor
    /// rate that is several changes a second, and the rider reported the result exactly:
    /// the yellow text cycles too fast to read anything until the bike is already still,
    /// by which point the message is gone. The view's 0.25 s crossfade made it worse,
    /// restarting mid-fade so the text never resolved.
    ///
    /// So a displayed reason is LATCHED for `reasonMinimumDisplay`. Deliberately here in
    /// the publish path rather than in the view: the mirrors are what every consumer reads,
    /// and the authoritative `internalBlockingReason` stays instantaneous, so diagnostics
    /// and the log are unaffected.
    ///
    /// Note it also latches a change to nil. A momentary pass mid-wobble would otherwise
    /// blank the warning for a few frames and bring it straight back, which is the same
    /// flicker seen from the other side.
    @MainActor
    private func publishReason(_ newReason: String?) {
        guard blockingReason != newReason else { return }

        // Nothing on screen yet: show it at once. The FIRST warning must never be
        // delayed — it is the one that tells the rider why the countdown just reset.
        guard blockingReason != nil else {
            blockingReason = newReason
            reasonShownAt = Date.now
            return
        }

        let shownFor = Date.now.timeIntervalSince(reasonShownAt)
        guard shownFor >= Self.reasonMinimumDisplay else {
            // Too soon. Keep the current text and come back when its time is up, at which
            // point whatever is true THEN gets published — not this now-stale value.
            scheduleReasonRepublish(after: Self.reasonMinimumDisplay - shownFor)
            return
        }

        blockingReason = newReason
        reasonShownAt = Date.now
    }

    /// One pending re-publish at a time; a burst of rejections all coalesce onto it.
    @MainActor
    private func scheduleReasonRepublish(after delay: TimeInterval) {
        guard !reasonRepublishScheduled else { return }
        reasonRepublishScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
            self?.republishCurrentReason()
        }
    }

    /// Deliberately a SYNCHRONOUS method rather than the body of the `Task` above.
    /// `NSLock.lock()` is `noasync` — taking it directly inside an async context is a
    /// warning today and an error under Swift 6 — so the lock is taken from here, which is
    /// an ordinary main-actor call the task makes after its sleep. Same shape as
    /// `publish()`, which is why that one is clean too.
    @MainActor
    private func republishCurrentReason() {
        reasonRepublishScheduled = false
        lock.lock()
        let current = internalBlockingReason
        lock.unlock()
        publishReason(current)
    }

    /// Rider tapped "recalibrate", or the swipe screen sent them back. Discards the
    /// current attempt and starts a fresh still-window.
    ///
    /// `@MainActor` so the mirrors are updated SYNCHRONOUSLY, which matters: the
    /// caller swaps the view hierarchy to `CalibrationScreen` in the same turn, and
    /// that screen calls `onCompleted` the moment it sees `.measured`. Publishing
    /// asynchronously would leave the stale `.measured` visible for a frame and bounce
    /// the rider straight back to the swipe screen. Both callers — the pill and the
    /// screen's own "Try again" — are already on the main actor.
    @MainActor
    func restart() {
        lock.lock()
        restartLocked()
        let newPhase = internalPhase
        let newReason = internalBlockingReason
        lock.unlock()

        phase = newPhase
        // Straight to the mirror, bypassing `publishReason`'s dwell. An explicit rider
        // action must not inherit the previous attempt's warning: the latch exists to stop
        // the text CYCLING, not to hold a message across a restart the rider asked for.
        // Resetting `reasonShownAt` also means the new attempt's first warning appears at
        // once rather than waiting out a dwell it never started.
        blockingReason = newReason
        reasonShownAt = .distantPast
    }

    private func restartLocked() {
        internalHasSeenSample = false
        estimator = BiasEstimator(config: config,
                                  bikeProfileID: bikeProfileID,
                                  thermalState: ProcessInfo.processInfo.thermalState.rawValue,
                                  sink: DiagnosticLog.shared)
        internalBlockingReason = nil
        internalPhase = .measuring(progress: nil)
        log.info("Calibration (re)started")
    }

    /// Called by the sensor layer when the motion hardware reports itself missing.
    /// The ONLY route to `.unavailable` — a measurement, never a default.
    func reportSensorsUnavailable(reason: String) {
        lock.lock()
        defer { lock.unlock() }
        log.error("Motion sensors unavailable: \(reason)")
        internalPhase = .unavailable
        schedulePublishLocked()
    }

    // MARK: - Progress handling

    /// Call with `lock` held. Writes authoritative state only; the caller schedules
    /// the main-actor publish.
    private func handle(_ progress: BiasEstimator.Progress, at time: TimeInterval) {
        switch progress {
        case .collecting(_, _, _, _):
            internalBlockingReason = nil
            internalPhase = .measuring(progress: progress.fraction)

        case .rejected(let reason):
            // The dwell reset. Name WHY on the sample that reset it — this is the
            // "too much vibration / still moving" feedback the calibration screen
            // surfaces in real time, and the behaviour the rider valued on the ride.
            internalBlockingReason = Self.riderText(for: reason)
            internalPhase = .measuring(progress: nil)

        case .done(let estimate):
            internalBlockingReason = nil
            internalPhase = .measured(estimate)
            log.info("Calibration complete. Sigma \(estimate.worstSigma * 180 / .pi, format: .fixed(precision: 4)) deg/s, gravity \(estimate.measuredGravity != nil ? "captured" : "MISSING")")

        case .failed(let failure):
            internalBlockingReason = nil
            internalPhase = .failed(message: failure.message)
            log.warning("Calibration failed: \(failure.message)")
        }
    }

    /// Rider-facing phrasing for each gate reason. `.vibrating` is the condition
    /// added this cycle: an idling engine swings |f| direction while its mean stays
    /// at 1 g, so it passes the magnitude band but not the spread test.
    static func riderText(for reason: ValidityGate.Reason) -> String? {
        switch reason {
        case .open, .noData:            return nil
        case .rotating:                 return String(localized: "Still moving — hold it steady")
        case .specificForceOutOfBand:   return String(localized: "Being moved or tilted — let it settle")
        case .vibrating:                return String(localized: "Too much vibration — switch the engine off")
        case .saturated:                return String(localized: "Vibration is off the scale — improve the mount")
        case .dwellNotMet:              return String(localized: "Almost — keep it still a moment longer")
        }
    }
}
