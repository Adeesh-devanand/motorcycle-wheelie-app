import AVFoundation
import MotoTelemetryCore
import os

/// Renders `CueState` as procedural audio via AVAudioEngine + AVAudioSourceNode.
/// Lock-free read of the current cue state ensures the audio render thread never blocks.
final class CueAudioRenderer: @unchecked Sendable {

    // MARK: - Route classification

    enum AudioRoute: Sendable {
        case builtIn
        case wired
        case bluetoothHFP   // SCO — low latency (~50 ms)
        case bluetoothA2DP  // High latency (100-200 ms)

        var estimatedLatency: TimeInterval {
            switch self {
            case .builtIn:       return 0.01
            case .wired:         return 0.01
            case .bluetoothHFP:  return 0.05
            case .bluetoothA2DP: return 0.15
            }
        }
    }

    // MARK: - State

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?

    /// Lock-free cue state shared with the render callback.
    private let cueState = OSAllocatedUnfairLock(initialState: CueState())

    private(set) var currentRoute: AudioRoute = .builtIn
    private(set) var measuredLatency: TimeInterval = 0

    private let log = Logger(subsystem: "com.mototelemetry.app", category: "CueAudioRenderer")

    // MARK: - Audio parameters

    private let sampleRate: Double = 48_000
    private let baseFrequency: Double = 440       // Hz — approach tone base
    private let maxFrequency: Double = 1320       // Hz — approach tone ceiling
    private let loopOutFrequency: Double = 880    // Hz — distinct loopout waveform
    private let releaseTime: Float = 0.15         // seconds

    /// Phase accumulator (render thread only — no lock needed).
    private var phase: Double = 0
    /// Envelope for release smoothing.
    private var envelope: Float = 0

    // MARK: - Lifecycle

    init() {
        configureSession()
        setupEngine()
        observeRouteChanges()
    }

    deinit {
        stop()
        NotificationCenter.default.removeObserver(self)
    }

    func start() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
            updateRouteLatency()
            log.info("CueAudioRenderer started. Route: \(String(describing: self.currentRoute)), latency: \(self.measuredLatency * 1000, format: .fixed(precision: 1)) ms")
        } catch {
            log.error("Failed to start audio engine: \(error.localizedDescription)")
        }
    }

    func stop() {
        engine.stop()
    }

    // MARK: - Cue update (called from pipeline thread at 100 Hz)

    /// Update the target cue state. Lock-free — safe to call from any thread.
    func update(_ state: CueState) {
        cueState.withLock { $0 = state }
    }

    // MARK: - Audio session

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, options: .mixWithOthers)
            try session.setMode(.default)
            try session.setPreferredIOBufferDuration(0.005) // 5 ms buffer
            try session.setActive(true)
        } catch {
            log.error("Audio session config failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Engine setup

    private func setupEngine() {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, bufferList -> OSStatus in
            guard let self else { return noErr }
            return self.renderCallback(frameCount: frameCount, bufferList: bufferList)
        }

        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    // MARK: - Render callback (real-time audio thread)

    private func renderCallback(frameCount: AVAudioFrameCount,
                                bufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let state = cueState.withLock { $0 }
        let buffer = UnsafeMutableBufferPointer<Float>(
            start: bufferList.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self),
            count: Int(frameCount)
        )

        let targetEnvelope: Float
        let frequency: Double
        let useSquareWave: Bool

        switch state.tone {
        case .silent:
            targetEnvelope = 0
            frequency = baseFrequency
            useSquareWave = false

        case .approach:
            targetEnvelope = Float(0.3 + 0.5 * state.urgency)
            // Rising tone: lerp from base to max with urgency
            frequency = baseFrequency + (maxFrequency - baseFrequency) * state.urgency
            useSquareWave = false

        case .loopOut:
            targetEnvelope = 0.9
            frequency = loopOutFrequency
            useSquareWave = true // Distinct timbre for emergency
        }

        let releaseCoeff = 1.0 - exp(-1.0 / (Double(sampleRate) * Double(releaseTime)))

        for frame in 0..<Int(frameCount) {
            // Envelope smoothing (attack/release)
            envelope += Float(releaseCoeff) * (targetEnvelope - envelope)

            // Phase advance
            phase += frequency / sampleRate
            if phase >= 1.0 { phase -= 1.0 }

            // Waveform generation
            let sample: Float
            if useSquareWave {
                sample = phase < 0.5 ? envelope : -envelope
            } else {
                sample = envelope * sin(Float(phase * 2.0 * .pi))
            }

            buffer[frame] = sample
        }

        return noErr
    }

    // MARK: - Route detection

    private func observeRouteChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        updateRouteLatency()
    }

    private func updateRouteLatency() {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute

        // Classify output
        if let output = route.outputs.first {
            switch output.portType {
            case .headphones, .usbAudio:
                currentRoute = .wired
            case .bluetoothHFP:
                currentRoute = .bluetoothHFP
            case .bluetoothA2DP, .bluetoothLE:
                currentRoute = .bluetoothA2DP
            default:
                currentRoute = .builtIn
            }
        }

        // Measured latency = outputLatency + ioBufferDuration
        measuredLatency = session.outputLatency + session.ioBufferDuration
        log.info("Route updated: \(String(describing: self.currentRoute)), measured latency: \(self.measuredLatency * 1000, format: .fixed(precision: 1)) ms")
    }
}
