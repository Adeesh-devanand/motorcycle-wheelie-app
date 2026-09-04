import Foundation
import MotoTelemetryCore
import Observation
import QuartzCore
import os

/// View model for the Live Wheelie screen.
///
/// Reads live telemetry from `RunRecorder`, which owns the pipeline and is the
/// single source of estimator output. This view model adds only display concerns:
/// 30 Hz decimation and display-only smoothing, which per ui-spec §7.3 must never
/// reach the stored run.
///
/// There is no manual record control. Per ui-spec §7.6 an attempt begins when the
/// calibrated angle holds above 8° for 150 ms and ends when it holds below 5° for
/// 250 ms, and the completed run is persisted atomically when it ends. The session
/// therefore starts as soon as calibration succeeds and runs until the screen goes
/// away — the rider never presses anything.
/// this view model is `@MainActor`. It reads `RunRecorder`'s live display
/// state and is driven by a `CADisplayLink` that fires on the main run loop, so the
/// whole type belongs to the main actor. The annotation is what lets it read the
/// recorder's `@MainActor` display properties and call its main-actor lifecycle
/// methods without a data race — the recorder stages sensor values off-actor and
/// this side applies them here via `recorder.flushDisplay()`.
@Observable
@MainActor
final class LiveWheelieViewModel {

    // MARK: - Display State (30 Hz decimated)

    private(set) var currentAngle: Double = 0       // degrees
    private(set) var currentSpeed: Double = 0       // km/h
    /// false when the recorder has no valid GNSS speed yet, so the view can
    /// distinguish "no fix" from a real 0 km/h instead of showing 0 for both.
    private(set) var speedAvailable: Bool = false
    private(set) var calibrationState: CalibrationState = .unavailable

    /// R6.2: which gate condition is blocking calibration, phrased for the rider.
    private(set) var blockingReason: String?

    /// Maxima for the CURRENT attempt only. Per ui-spec §7.6 these reset when a
    /// new attempt begins, and per §7.3 no lifetime statistics are shown here.
    private(set) var attemptMaxAngle: Double = 0
    private(set) var attemptMaxSpeed: Double = 0

    /// True while a wheelie is in progress. Drives the §7.2 "wheelie active" row:
    /// configuration controls are disabled for its duration.
    private(set) var eventActive: Bool = false
    /// Live duration of the attempt in progress, seconds. Reads `0.0` when idle.
    private(set) var wheelieTime: TimeInterval = 0

    // MARK: - Range Status

    var angleInRange: RangeStatus {
        rangeStatus(value: currentAngle, target: preferences.angleTarget, nearThreshold: 5)
    }

    var speedInRange: RangeStatus {
        // With no GNSS fix there is no speed to judge, and `currentSpeed` is a HELD
        // value rather than a measurement. Reporting `.inRange` off it would light the
        // meter green on data that does not exist — the one outcome worth actively
        // preventing, since green is the signal the rider steers by. `RangeStatus` has
        // no neutral case, so fall to the non-flattering side instead of inventing one
        // and threading it through the meter.
        guard speedAvailable else { return .outOfRange }
        return rangeStatus(value: currentSpeed, target: preferences.speedTarget, nearThreshold: 5)
    }

    /// Live values are only trustworthy once calibrated. §7.2 requires them frozen
    /// or blank otherwise.
    var isCalibrated: Bool {
        if case .calibrated = calibrationState { return true }
        return false
    }

    // MARK: - Dependencies

    let preferences: RiderPreferences
    private let calibrationService: CalibrationService
    private let recorder: RunRecorder
    private let bikeProfileID: UUID
    /// The measured phone->bike alignment from calibration + swipe. Required — the
    /// live screen is only reachable once it exists.
    private let alignment: MountAlignment

    // MARK: - Private

    private var displayLink: DisplayLinkProxy?
    private var sensorTask: Task<Void, Never>?
    private var sessionStarted = false

    // MARK: - Diagnostics ("live")

    /// Folds the previous standalone `Logger` into the shared diagnostic path so
    /// there is ONE logging mechanism, not two. `.info` still reaches OSLog via the
    /// sink's mirror. Display heartbeat is stamped with `systemUptime` (the shared
    /// clock) so it interleaves with sensor/rec lines, and gated at 1 Hz — the
    /// 30 Hz display tick must never emit per frame.
    private var diag = DiagnosticEmitter(sink: DiagnosticLog.shared, category: "live")
    private var lastHeartbeat: TimeInterval = 0

    // MARK: - Init

    init(calibrationService: CalibrationService,
         preferences: RiderPreferences,
         recorder: RunRecorder,
         alignment: MountAlignment,
         bikeProfileID: UUID = UUID()) {
        self.calibrationService = calibrationService
        self.preferences = preferences
        self.recorder = recorder
        self.alignment = alignment
        self.bikeProfileID = bikeProfileID
    }

    // MARK: - Lifecycle

    func onAppear() {
        diag.always(time: ProcessInfo.processInfo.systemUptime, level: .info,
                    message: "onAppear", values: [:])
        startDisplayDecimation()
        startSession()
    }

    func onDisappear() {
        diag.always(time: ProcessInfo.processInfo.systemUptime, level: .info,
                    message: "onDisappear — stopping display link & session", values: [:])
        displayLink?.stop()
        displayLink = nil
        recorder.stopSession()
        sessionStarted = false
    }

    /// Starts the recording session. This is what asks CoreMotion for updates,
    /// which is what triggers iOS's motion permission prompt, and it is also what
    /// starts calibration — `RunRecorder` feeds every raw IMU sample to
    /// `CalibrationService` as it runs the pipeline.
    private func startSession() {
        guard !sessionStarted else { return }
        sessionStarted = true
        recorder.startSession(
            bikeProfileID: bikeProfileID,
            // The measured mount alignment from calibration + the chassis swipe.
            // There is no preset fallback: the app cannot reach the live screen
            // without a completed calibration and swipe, so `alignment` is always a
            // real capture. `.portraitMount` was removed precisely because a guessed
            // alignment silently swapped lean and pitch.
            mountAlignment: alignment,
            angleTarget: preferences.angleTarget
        )
        diag.always(time: ProcessInfo.processInfo.systemUptime, level: .info,
                    message: "session started (subscribed)", values: [:])
    }

    // MARK: - User Actions

    /// Sends the rider back to recalibrate — the live screen has no re-zero of its
    /// own now, because a re-zero also needs a fresh swipe to rebuild the alignment.
    func requestRecalibration() {
        calibrationService.restart()
    }

    // MARK: - Private

    private func startDisplayDecimation() {
        diag.always(time: ProcessInfo.processInfo.systemUptime, level: .info,
                    message: "display link start (30 Hz)", values: [:])
        displayLink = DisplayLinkProxy { [weak self] in
            self?.decimateToDisplay()
        }
        displayLink?.start()
    }

    /// Called at 30 Hz. Pulls the latest estimator output from the recorder and
    /// applies display-only smoothing — ui-spec §7.3's α ≈ 0.20–0.35. The stored
    /// run uses estimator output, never these interpolated values.
    private func decimateToDisplay() {
        let alpha = 0.3
        // apply the sensor values the recorder staged off-actor onto its
        // observable properties, here on the main actor, before reading them. This is
        // the single coalescing hop — 100 Hz of sensor writes become one apply per
        // 30 Hz display frame.
        recorder.flushDisplay()

        calibrationState = calibrationService.state
        blockingReason = calibrationService.blockingReason

        // BUG 2 heartbeat: the angle CURRENTLY DISPLAYED, at 1 Hz. Cross-referenced
        // against the "sensor heartbeat" lines this shows unambiguously whether a
        // frozen angle is a dead stream (no sensor lines) or a display stall (sensor
        // lines flowing but this value stuck). Runs whether or not calibrated.
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastHeartbeat >= 1.0 {
            lastHeartbeat = now
            diag.always(time: now, level: .info, message: "live heartbeat",
                        values: ["displayedAngle": currentAngle,
                                 "recorderPitch": recorder.livePitch,
                                 "calibrated": isCalibrated ? 1 : 0,
                                 "eventActive": eventActive ? 1 : 0])
        }

        // §7.2: freeze live values unless calibrated.
        guard isCalibrated else { return }

        currentAngle += alpha * (recorder.livePitch - currentAngle)

        // `recorder.liveSpeed` stays 0 until the first GNSS fix, so EMA-ing it
        // unconditionally rendered "0 km/h" for BOTH a stationary bike and a total
        // absence of GNSS — R15.3 says those must not look identical. Drive an
        // explicit `speedAvailable` flag from the recorder and, while no fix exists,
        // HOLD the last displayed speed rather than smoothing toward a fabricated 0.
        // The view shows a dash / "—" when `speedAvailable` is false (see the view).
        speedAvailable = recorder.liveSpeedAvailable
        if speedAvailable {
            currentSpeed += alpha * (recorder.liveSpeed - currentSpeed)
        }

        let wasActive = eventActive
        eventActive = recorder.eventActive
        wheelieTime = recorder.eventActive ? recorder.currentEventDuration : 0

        // §7.6: reset current-attempt maxima only when a NEW attempt begins.
        if eventActive && !wasActive {
            attemptMaxAngle = 0
            attemptMaxSpeed = 0
        }
        if eventActive {
            attemptMaxAngle = max(attemptMaxAngle, recorder.livePitch)
            // only fold a genuine speed reading into the attempt max — while
            // no GNSS fix exists `recorder.liveSpeed` is a placeholder 0, not a
            // measured value, and must not seed the max.
            if speedAvailable {
                attemptMaxSpeed = max(attemptMaxSpeed, recorder.liveSpeed)
            }
        }
    }

    private func rangeStatus(value: Double, target: MetricRange, nearThreshold: Double) -> RangeStatus {
        if value >= target.lower && value <= target.upper {
            return .inRange
        } else if value >= (target.lower - nearThreshold) && value <= (target.upper + nearThreshold) {
            return .near
        } else {
            return .outOfRange
        }
    }
}

// MARK: - Range Status

enum RangeStatus {
    case inRange, near, outOfRange
}

// MARK: - Display Link Proxy (30 Hz cap)

/// `@MainActor` — the display link is added to the `.main` runloop, so `tick`
/// always fires on the main thread, and its handler drives the main-actor view
/// model. Isolating the proxy lets the compiler prove that the handler call is on the
/// main actor instead of forcing a hop.
@MainActor
private final class DisplayLinkProxy {
    private var displayLink: CADisplayLink?
    private let handler: @MainActor () -> Void
    private var lastFire: CFTimeInterval = 0
    private let minInterval: CFTimeInterval = 1.0 / 30.0

    init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    func start() {
        displayLink = CADisplayLink(target: self, selector: #selector(tick))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
        displayLink?.add(to: .main, forMode: .common)
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        guard now - lastFire >= minInterval else { return }
        lastFire = now
        handler()
    }
}
