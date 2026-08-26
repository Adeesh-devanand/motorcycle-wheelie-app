import AVFoundation
import Foundation
import os

/// Records a .caf audio sidecar during vibration characterization mode.
/// ONLY instantiated in vibration mode — never during ride or bench sessions.
/// Implements the rev-sweep protocol: 3 seconds per 500 rpm band with prompts.
final class VibrationRecorder: @unchecked Sendable {

    // MARK: - Sweep state

    enum SweepState: Sendable, Equatable {
        case idle
        case awaitingPermission
        case ready
        case recording(band: RPMBand)
        case paused(nextBand: RPMBand)
        case complete
        case failed(String)
    }

    struct RPMBand: Sendable, Equatable {
        let index: Int
        let lowerRPM: Int
        let upperRPM: Int

        var label: String { "\(lowerRPM)–\(upperRPM) RPM" }
        var durationSeconds: TimeInterval { 3.0 }
    }

    // MARK: - Published

    private(set) var state: SweepState = .idle
    private(set) var currentBandElapsed: TimeInterval = 0
    private(set) var bands: [RPMBand] = []
    private(set) var prompt: String?

    // MARK: - Private

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?
    private var bandStartTime: Date?

    private let rpmBandWidth: Int = 500
    private let rpmStart: Int = 1000
    private let rpmEnd: Int = 10000
    private let secondsPerBand: TimeInterval = 3.0

    private let log = Logger(subsystem: "com.mototelemetry.app", category: "VibrationRecorder")

    // MARK: - Init

    init(rpmRange: ClosedRange<Int> = 1000...10000) {
        // Build band schedule
        var b: [RPMBand] = []
        var lower = rpmRange.lowerBound
        var idx = 0
        while lower < rpmRange.upperBound {
            let upper = min(lower + rpmBandWidth, rpmRange.upperBound)
            b.append(RPMBand(index: idx, lowerRPM: lower, upperRPM: upper))
            lower = upper
            idx += 1
        }
        self.bands = b
    }

    // MARK: - Permission

    /// Lazily requests mic permission. Call before `startSweep()`.
    func requestPermission() async -> Bool {
        state = .awaitingPermission

        if #available(iOS 17.0, *) {
            let granted = await AVAudioApplication.requestRecordPermission()
            state = granted ? .ready : .failed("Microphone permission denied")
            return granted
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    Task { @MainActor in
                        self.state = granted ? .ready : .failed("Microphone permission denied")
                        continuation.resume(returning: granted)
                    }
                }
            }
        }
    }

    // MARK: - Sweep control

    /// Starts the rev-sweep recording session.
    func startSweep() {
        guard case .ready = state, let firstBand = bands.first else {
            log.error("Cannot start sweep in state: \(String(describing: self.state))")
            return
        }

        do {
            try setupAudioEngine()
            startBand(firstBand)
        } catch {
            state = .failed(error.localizedDescription)
            log.error("Sweep start failed: \(error.localizedDescription)")
        }
    }

    /// Advance to the next band. Called by the UI when the rider is ready.
    func advanceToNextBand() {
        guard case .paused(let nextBand) = state else { return }
        startBand(nextBand)
    }

    /// Stop recording and finalize the .caf file.
    func stopSweep() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        audioFile = nil
        state = .complete
        log.info("Vibration sweep complete. File: \(self.recordingURL?.lastPathComponent ?? "nil")")
    }

    /// The URL of the recorded .caf sidecar, available after sweep completes.
    var sidecarURL: URL? { recordingURL }

    // MARK: - Band timing

    /// Called from a display-link or timer to update band elapsed time.
    func tick() {
        guard case .recording = state, let start = bandStartTime else { return }
        currentBandElapsed = Date().timeIntervalSince(start)

        // Auto-advance when band duration met
        if currentBandElapsed >= secondsPerBand {
            completeBand()
        }
    }

    // MARK: - Private

    private func setupAudioEngine() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        // Create output file
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let filename = "vibration_\(ISO8601DateFormatter().string(from: Date())).caf"
        let url = docs.appendingPathComponent(filename)
        recordingURL = url

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        audioFile = file

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            do {
                try self.audioFile?.write(from: buffer)
            } catch {
                self.log.error("Write failed: \(error.localizedDescription)")
            }
        }

        try engine.start()
        self.audioEngine = engine
        log.info("Audio engine started for vibration recording")
    }

    private func startBand(_ band: RPMBand) {
        state = .recording(band: band)
        bandStartTime = Date()
        currentBandElapsed = 0
        prompt = "Hold \(band.label) steady for 3 seconds"
        log.info("Recording band \(band.index): \(band.label)")
    }

    private func completeBand() {
        guard case .recording(let band) = state else { return }

        // Find next band
        let nextIndex = band.index + 1
        if nextIndex < bands.count {
            let nextBand = bands[nextIndex]
            state = .paused(nextBand: nextBand)
            prompt = "Ready for \(nextBand.label)? Tap to continue."
        } else {
            stopSweep()
        }
    }
}
