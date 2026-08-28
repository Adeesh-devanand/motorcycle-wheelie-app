import AVFoundation
import MotoTelemetryCore
import os

/// Renders the live wheelie angle as a rate-coded warning tone via AVAudioEngine
/// + AVAudioSourceNode, following the design proven by reverse-parking sensors,
/// glider variometers and cockpit warning systems.
///
/// Three cues rise together with pitch angle, in the order the literature ranks
/// their effect on perceived urgency (Edworthy, Loxley & Dennis 1991; Hellier,
/// Edworthy & Dennis 1993):
///
/// 1. **Pulse repetition rate** — the dominant cue. Slow chirps at low angle,
///    accelerating to fast beeps near the limit. Held below the ~20 Hz
///    click-fusion limit (Ungan & Yagcioglu 2014) so individual beeps stay
///    resolvable; above that the ear stops counting and "faster = steeper"
///    becomes unreadable. This is exactly why parking sensors switch to a solid
///    tone rather than beeping ever faster.
/// 2. **Carrier frequency** — rises geometrically, since pitch perception is
///    logarithmic. Lands in the 2-4 kHz band where the ear canal resonates and a
///    tone is perceived 6-8 dB louder than its SPL (ISO 226), and well clear of
///    the 250-500 Hz wind-noise energy peak under a motorcycle helmet.
/// 3. **Amplitude** — rises NON-LINEARLY (`t^amplitudeExponent`). Because
///    perceived loudness follows Stevens' power law (loudness ∝ pressure^0.6),
///    a raw exponent of `n` is felt as `t^(0.6n)`, so the exponent below yields
///    accelerating loudness that rushes up as the angle approaches the limit.
///
/// Past `limitDegrees` the tone goes **solid and full-cap** — the categorical
/// "you are over the edge" signal used by stall warnings, GPWS and the closest
/// zone of every parking sensor.
///
/// The cue is a function of ANGLE ALONE. Pitch *rate* is deliberately not an
/// input: a fast flick upward at a low angle is not a steep wheelie, and letting
/// rate trigger the tone made the cue fire during the run-up, which reads as a
/// false alarm and trains the rider to ignore it. Rate belongs in the segmenter
/// and the UI, not in the sound.
///
/// Below `silenceThresholdDegrees` the renderer is silent, so normal riding,
/// bumps and lean make no noise (the variometer "climb threshold" convention).
///
/// The tone rides UNDER the system volume — iOS scales hardware output by the
/// device volume, so turning the phone up makes it louder, while `maxAmplitude`
/// bounds how loud we ever ask for.
///
/// Lock-free read of the current parameters ensures the audio render thread
/// never blocks.
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

        /// Stable numeric code for the NDJSON `values` map.
        var diagCode: Int {
            switch self {
            case .builtIn:       return 0
            case .wired:         return 1
            case .bluetoothHFP:  return 2
            case .bluetoothA2DP: return 3
            }
        }
    }

    // MARK: - Render parameters

    /// The full set of synthesis targets, published to the render thread as one
    /// atomic snapshot so a frame can never mix old and new values.
    private struct CueParameters: Sendable {
        var amplitude: Float = 0        // 0…maxAmplitude
        var frequency: Double = 1000    // Hz, carrier
        var pulseRate: Double = 2       // Hz, beeps per second
        var dutyCycle: Double = 0.3     // fraction of each pulse period sounding
        var continuous: Bool = false    // true → solid tone, no gating

        static let silent = CueParameters(amplitude: 0,
                                          frequency: 1000,
                                          pulseRate: 2,
                                          dutyCycle: 0.3,
                                          continuous: false)
    }

    // MARK: - State

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?

    /// Lock-free synthesis parameters shared with the render callback.
    private let cueParameters = OSAllocatedUnfairLock(initialState: CueParameters.silent)

    private(set) var currentRoute: AudioRoute = .builtIn
    private(set) var measuredLatency: TimeInterval = 0

    private let log = Logger(subsystem: "com.mototelemetry.app", category: "CueAudioRenderer")

    // MARK: - Diagnostics ("audio")

    /// CONTROL-PATH ONLY. Never touched from `renderCallback` (the real-time audio
    /// thread) — a lock or allocation there would glitch the tone. Heartbeat is
    /// gated at 1 Hz off `systemUptime`; the render thread is untouched.
    private var diag = DiagnosticEmitter(sink: DiagnosticLog.shared, category: "audio")

    // MARK: - Angle mapping

    private let sampleRate: Double = 48_000

    /// Below this angle the renderer is silent. Keeps normal riding, bumps and
    /// lean from making noise (the variometer "climb threshold" convention).
    private let silenceThresholdDegrees: Double = 10

    /// At and above this angle the tone goes solid at full cap — the categorical
    /// past-the-limit signal. Well past a wheelie's balance point, so the whole
    /// usable range stays inside the pulsed zone.
    private let limitDegrees: Double = 70

    /// Ceiling for the amplitude and pitch maps. Angles above clamp here.
    private let pitchCapDegrees: Double = 90

    /// Carrier at the silence threshold. Above the phone speaker's low-end
    /// rolloff and above the helmet wind-noise energy peak (250-500 Hz).
    private let baseFrequency: Double = 1000     // Hz

    /// Carrier at the cap — the ear's most sensitive band (2-5 kHz, peaking
    /// ~3 kHz from ear-canal resonance), worth 6-8 dB of free perceived loudness.
    private let peakFrequency: Double = 3000     // Hz

    /// Beep rate at the silence threshold, and just below the limit. The maximum
    /// stays under the ~20 Hz click-fusion threshold so beeps remain countable,
    /// and lands near the ~10 Hz (100 ms interval) tempo-discrimination optimum.
    private let minPulseRate: Double = 2.0       // Hz
    private let maxPulseRate: Double = 12.0      // Hz

    /// Fraction of each pulse period that sounds. Short chirp with a long gap at
    /// low angle, widening toward solid as the angle climbs — the far-to-near
    /// progression parking sensors use.
    private let minDutyCycle: Double = 0.30
    private let maxDutyCycle: Double = 0.70

    /// Non-linear amplitude curve. Raw amplitude ∝ t^n; perceived loudness then
    /// grows as t^(0.6n) by Stevens' power law, so n = 2 gives clearly
    /// accelerating loudness while keeping the mid range audible. Raise toward
    /// 3-5 for a more violent late rush, lower to 1.67 for perceptually linear.
    private let amplitudeExponent: Double = 2.0

    /// Fixed internal amplitude ceiling. Below 1.0 for headroom against clipping.
    private let maxAmplitude: Float = 0.85

    // MARK: - Smoothing

    /// Amplitude glide, so loudness swells rather than stepping per sample.
    private let amplitudeSmoothingTime: Double = 0.08   // seconds
    /// Carrier glide, so pitch slides rather than jumping between readings.
    private let frequencySmoothingTime: Double = 0.05   // seconds
    /// Pulse gate rise/fall. ~10 ms avoids the click an instant gate produces
    /// (the rise-time guidance in IEC 60601-1-8).
    private let gateSmoothingTime: Double = 0.01        // seconds

    // MARK: - Render-thread accumulators (render thread only — no lock needed)

    private var phase: Double = 0
    private var pulsePhase: Double = 0
    private var amplitudeEnvelope: Float = 0
    private var gateEnvelope: Float = 0
    private var smoothedFrequency: Double = 1000

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
            diag.always(time: ProcessInfo.processInfo.systemUptime, level: .info,
                        message: "audio engine started",
                        values: ["latencyMs": measuredLatency * 1000,
                                 "sampleRate": AVAudioSession.sharedInstance().sampleRate])
        } catch {
            log.error("Failed to start audio engine: \(error.localizedDescription)")
            diag.always(time: ProcessInfo.processInfo.systemUptime, level: .error,
                        message: "audio engine start failed",
                        values: ["code": Double((error as NSError).code)])
        }
    }

    func stop() {
        engine.stop()
        diag.always(time: ProcessInfo.processInfo.systemUptime, level: .info,
                    message: "audio engine stopped", values: [:])
    }

    // MARK: - Cue update (called from pipeline thread at 100 Hz)

    /// Drive the warning tone from the live wheelie angle.
    ///
    /// - Parameter pitchDegrees: current pitch angle in degrees.
    ///
    /// Angle is the only input. Two riders at 40° hear the same thing whether
    /// they got there in a snap or a slow lift, so the sound always means one
    /// thing: "this is how high you are."
    ///
    /// Lock-free — safe to call from any thread.
    func update(pitchDegrees: Double) {
        let clamped = max(0, min(pitchDegrees, pitchCapDegrees))

        // Deadband: silent during normal riding.
        guard clamped >= silenceThresholdDegrees else {
            cueParameters.withLock { $0 = CueParameters.silent }
            return
        }

        // Position through the audible band: 0 at the deadband edge, 1 at the cap.
        let span = pitchCapDegrees - silenceThresholdDegrees
        let t = max(0, min((clamped - silenceThresholdDegrees) / span, 1))

        // Past the limit: solid tone at full cap, top of the pitch range.
        // Categorical, so it cannot be mistaken for "steep".
        let continuous = clamped >= limitDegrees

        // Non-linear amplitude — perceived loudness accelerates as t^(0.6n).
        let amplitude = Float(pow(t, amplitudeExponent)) * maxAmplitude

        // Geometric pitch rise — a constant ratio per unit angle reads as an
        // even climb, because pitch perception is logarithmic.
        let frequency = baseFrequency * pow(peakFrequency / baseFrequency, t)

        // Rate coding — the dominant urgency cue. Note this is the BEEP rate,
        // derived from the angle; it is not the pitch rate of the bike.
        let pulseRate = minPulseRate + (maxPulseRate - minPulseRate) * t
        let dutyCycle = minDutyCycle + (maxDutyCycle - minDutyCycle) * t

        cueParameters.withLock {
            $0 = CueParameters(amplitude: continuous ? maxAmplitude : amplitude,
                               frequency: continuous ? peakFrequency : frequency,
                               pulseRate: pulseRate,
                               dutyCycle: dutyCycle,
                               continuous: continuous)
        }

        // 1 Hz target heartbeat — CONTROL PATH, not the render thread. `update` is
        // called ~100 Hz from the pipeline, so gate emission on a lock-protected
        // timestamp. This logs the SYNTHESIS TARGETS (what we asked the tone to do)
        // for the current angle; the render callback itself is never instrumented.
        let now = ProcessInfo.processInfo.systemUptime
        let due: Bool = lastAudioHeartbeat.withLock { last in
            if now - last >= 1.0 { last = now; return true }
            return false
        }
        if due {
            diag.always(time: now, level: .info, message: "audio target",
                        values: ["pitchDeg": clamped,
                                 "amplitude": Double(continuous ? maxAmplitude : amplitude),
                                 "frequency": continuous ? peakFrequency : frequency,
                                 "pulseRate": pulseRate,
                                 "continuous": continuous ? 1 : 0])
        }
    }

    /// Lock-protected last-heartbeat sample time for the 1 Hz audio-target log.
    private let lastAudioHeartbeat = OSAllocatedUnfairLock<TimeInterval>(initialState: 0)

    // MARK: - Audio session

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, options: .mixWithOthers)
            try session.setMode(.default)
            try session.setPreferredIOBufferDuration(0.005) // 5 ms buffer
            try session.setActive(true)
            diag.always(time: ProcessInfo.processInfo.systemUptime, level: .info,
                        message: "audio session configured (playback/.default)",
                        values: ["bufferDurMs": 5])
        } catch {
            log.error("Audio session config failed: \(error.localizedDescription)")
            diag.always(time: ProcessInfo.processInfo.systemUptime, level: .error,
                        message: "audio session config failed",
                        values: ["code": Double((error as NSError).code)])
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
        let params = cueParameters.withLock { $0 }
        let buffer = UnsafeMutableBufferPointer<Float>(
            start: bufferList.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self),
            count: Int(frameCount)
        )

        // One-pole smoothing coefficients toward each target.
        let ampCoeff = Float(1.0 - exp(-1.0 / (sampleRate * amplitudeSmoothingTime)))
        let freqCoeff = 1.0 - exp(-1.0 / (sampleRate * frequencySmoothingTime))
        let gateCoeff = Float(1.0 - exp(-1.0 / (sampleRate * gateSmoothingTime)))

        for frame in 0..<Int(frameCount) {
            // Glide amplitude and carrier toward their angle-derived targets.
            amplitudeEnvelope += ampCoeff * (params.amplitude - amplitudeEnvelope)
            smoothedFrequency += freqCoeff * (params.frequency - smoothedFrequency)

            // Pulse gate: open while the beep sounds, closed in the gap, held
            // open permanently once past the limit.
            var gateTarget: Float = 1
            if params.continuous {
                pulsePhase = 0
            } else {
                pulsePhase += params.pulseRate / sampleRate
                if pulsePhase >= 1.0 { pulsePhase -= 1.0 }
                gateTarget = pulsePhase < params.dutyCycle ? 1 : 0
            }
            gateEnvelope += gateCoeff * (gateTarget - gateEnvelope)

            // Carrier advance. Phase stays continuous across frequency changes.
            phase += smoothedFrequency / sampleRate
            if phase >= 1.0 { phase -= 1.0 }

            buffer[frame] = amplitudeEnvelope * gateEnvelope * sin(Float(phase * 2.0 * .pi))
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
        diag.always(time: ProcessInfo.processInfo.systemUptime, level: .info,
                    message: "audio route changed",
                    values: ["route": Double(currentRoute.diagCode),
                             "latencyMs": measuredLatency * 1000])
    }
}
