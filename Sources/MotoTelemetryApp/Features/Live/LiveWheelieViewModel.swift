import Foundation
import Observation
import os

/// View model for the Live Wheelie screen. Decimates sensor data to 30 Hz
/// for display and tracks recording state.
@Observable
final class LiveWheelieViewModel {

    // MARK: - Display State (30 Hz decimated)

    private(set) var currentAngle: Double = 0       // degrees
    private(set) var currentSpeed: Double = 0       // km/h (or mph per prefs)
    private(set) var pitchRate: Double = 0          // deg/s
    private(set) var calibrationState: CalibrationState = .unavailable
    private(set) var isRecording: Bool = false
    private(set) var sessionElapsed: TimeInterval = 0

    // MARK: - Range Status

    var angleInRange: RangeStatus {
        rangeStatus(value: currentAngle, target: preferences.angleTarget, nearThreshold: 5)
    }

    var speedInRange: RangeStatus {
        rangeStatus(value: currentSpeed, target: preferences.speedTarget, nearThreshold: 5)
    }

    // MARK: - Dependencies

    let preferences: RiderPreferences
    private let calibrationService: CalibrationService

    // MARK: - Private

    private var displayLink: DisplayLinkProxy?
    private var recordingStartTime: Date?
    private var sessionTimer: Timer?
    private let log = Logger(subsystem: "com.mototelemetry.app", category: "LiveWheelieVM")

    // Raw values from sensor pipeline (updated at full rate)
    private var rawAngle: Double = 0
    private var rawSpeed: Double = 0
    private var rawPitchRate: Double = 0

    // MARK: - Init

    init(calibrationService: CalibrationService, preferences: RiderPreferences) {
        self.calibrationService = calibrationService
        self.preferences = preferences
    }

    // MARK: - Lifecycle

    func onAppear() {
        startDisplayDecimation()
        syncCalibrationState()
    }

    func onDisappear() {
        displayLink?.stop()
        displayLink = nil
        sessionTimer?.invalidate()
    }

    // MARK: - Sensor Input (called from pipeline at full rate)

    func updateTelemetry(angle: Double, speed: Double, pitchRate: Double) {
        rawAngle = angle
        rawSpeed = speed
        rawPitchRate = pitchRate
    }

    func updateCalibration(_ state: CalibrationState) {
        calibrationState = state
    }

    // MARK: - User Actions

    func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        recordingStartTime = .now
        sessionElapsed = 0
        startSessionTimer()
        log.info("Recording started")
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        sessionTimer?.invalidate()
        sessionTimer = nil
        recordingStartTime = nil
        log.info("Recording stopped at \(self.sessionElapsed, format: .fixed(precision: 1))s")
    }

    func requestRecalibration() {
        calibrationService.requestRecalibration()
    }

    // MARK: - Private

    private func startDisplayDecimation() {
        displayLink = DisplayLinkProxy { [weak self] in
            self?.decimateToDisplay()
        }
        displayLink?.start()
    }

    /// Called at display refresh rate (capped to 30 Hz by DisplayLinkProxy).
    /// Applies display-only smoothing — never stored.
    private func decimateToDisplay() {
        let alpha = 0.3 // EMA smoothing factor
        currentAngle = currentAngle + alpha * (rawAngle - currentAngle)
        currentSpeed = currentSpeed + alpha * (rawSpeed - currentSpeed)
        pitchRate = rawPitchRate
    }

    private func syncCalibrationState() {
        calibrationState = calibrationService.state
    }

    private func startSessionTimer() {
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let start = self.recordingStartTime else { return }
            self.sessionElapsed = Date.now.timeIntervalSince(start)
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

private final class DisplayLinkProxy {
    private var displayLink: CADisplayLink?
    private let handler: () -> Void
    private var lastFire: CFTimeInterval = 0
    private let minInterval: CFTimeInterval = 1.0 / 30.0

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    func start() {
        displayLink = CADisplayLink(target: self, selector: #selector(tick))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30)
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
