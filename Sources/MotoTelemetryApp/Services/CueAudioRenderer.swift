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
        var updatedAt: TimeInterval = 0
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
    private let controlLock = NSRecursiveLock()
    private var intendedRunning = false

    var wantsToRun: Bool {
        controlLock.lock(); defer { controlLock.unlock() }
        return intendedRunning
    }
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
    //
    // The transfer curve below is POLICY, not implementation detail, so it now
    // lives in `Config` (v7) and reaches the log header — before, a replay could
    // reproduce what the estimator saw but not what the rider HEARD. Read once at
    // init into `let`s so the render/update paths stay allocation- and lookup-free.
    // Config stores the angle thresholds in RADIANS (like every other angle in the
    // struct); this file works in DEGREES, so the conversion happens HERE, at one
    // place, and nowhere else.

    private let sampleRate: Double = 48_000

    /// Below this angle the renderer is silent. Keeps normal riding, bumps and
    /// lean from making noise (the variometer "climb threshold" convention).
    private let silenceThresholdDegrees: Double

    /// At and above this angle the tone goes solid at full cap — the categorical
    /// past-the-limit signal. Well past a wheelie's balance point, so the whole
    /// usable range stays inside the pulsed zone.
    private let limitDegrees: Double

    /// Ceiling for the amplitude and pitch maps. Angles above clamp here.
    private let pitchCapDegrees: Double

    /// Carrier at the silence threshold. Above the phone speaker's low-end
    /// rolloff and above the helmet wind-noise energy peak (250-500 Hz).
    private let baseFrequency: Double

    /// Carrier at the cap — the ear's most sensitive band (2-5 kHz, peaking
    /// ~3 kHz from ear-canal resonance), worth 6-8 dB of free perceived loudness.
    private let peakFrequency: Double

    /// Beep rate at the silence threshold, and just below the limit. The maximum
    /// stays under the ~20 Hz click-fusion threshold so beeps remain countable,
    /// and lands near the ~10 Hz (100 ms interval) tempo-discrimination optimum.
    private let minPulseRate: Double
    private let maxPulseRate: Double

    /// Fraction of each pulse period that sounds. Short chirp with a long gap at
    /// low angle, widening toward solid as the angle climbs — the far-to-near
    /// progression parking sensors use.
    private let minDutyCycle: Double
    private let maxDutyCycle: Double

    /// Non-linear amplitude curve. Raw amplitude ∝ t^n; perceived loudness then
    /// grows as t^(0.6n) by Stevens' power law, so n = 2 gives clearly
    /// accelerating loudness while keeping the mid range audible.
    private let amplitudeExponent: Double

    /// Fixed internal amplitude ceiling. Below 1.0 for headroom against clipping.
    private let maxAmplitude: Float

    // MARK: - Hysteresis latch (WORK ITEM B5 — the flapping tone)
    //
    // `update(pitchDegrees:)` used to recompute the silence decision from the raw
    // angle on every call with no memory, so at exactly the entry angle — which is
    // exactly where every wheelie begins — vibration walked the reading back and
    // forth across the one threshold and the tone chattered on and off at 100 Hz.
    // The fix is a latch: turn ON above `enterDegrees`, and only turn OFF once the
    // angle has been below `exitDegrees` (which is deliberately lower) for
    // `releaseTime`. Config owns these (`cueEnterPitch`/`cueExitPitch`/
    // `cueReleaseTime`), in radians; converted to degrees here at the one place.
    // `cueDeadband` is applied to the tracked angle so sub-`deadband` jitter cannot
    // move the latched target either.

    /// Enter/exit thresholds in DEGREES (converted from Config's radians once).
    private let enterDegrees: Double
    private let exitDegrees: Double
    /// The tone must stay below `exitDegrees` this long before it releases.
    private let releaseTime: TimeInterval
    /// Pitch changes smaller than this are ignored when deciding to release.
    private let deadbandDegrees: Double

    /// Persistent latch state. `update` is the only writer and runs on the single
    /// pipeline thread (~100 Hz), so no lock is needed between calls; the render
    /// thread never touches it.
    private var isSounding: Bool = false
    /// systemUptime at which the angle first dropped below `exitDegrees` while
    /// sounding; nil while above exit. Release fires once `now - since >= releaseTime`.
    private var belowExitSince: TimeInterval?
    /// Last angle that actually moved the latch decision, for the deadband test.
    private var lastLatchAngle: Double = 0

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

    // MARK: - Precomputed smoothing coefficients
    //
    // these one-pole coefficients depend ONLY on `sampleRate` and the fixed
    // smoothing times, yet were recomputed with three `exp()` calls on EVERY render
    // callback. `sampleRate` never changes after init, so compute them once here.
    // The render thread only reads them. (They are recomputed if the engine is
    // re-established, via `computeSmoothingCoefficients`, though sampleRate does not
    // currently change — see the config-change observer.)
    private var ampCoeff: Float = 0
    private var freqCoeff: Double = 0
    private var gateCoeff: Float = 0

    // MARK: - Interruption state
    //
    // on an AVAudioSession interruption (call, Siri, another app grabbing the
    // session) iOS STOPS the engine. The renderer previously observed only route
    // changes, so after an interruption the safety tone went silent for the rest of
    // the ride with no signal. We now track the interruption and resume on `.ended`
    // with `.shouldResume`. Control-path only; never read from the render thread.
    private var wasRunningBeforeInterruption = false

    // MARK: - Lifecycle

    /// - Parameter config: the tunable transfer curve + latch policy. Defaults to
    ///   `Config()` so existing call sites need no change; the app passes the live
    ///   config so the sound matches the numbers written to the log header.
    init(config: Config = Config()) {
        // Transfer curve (radians in Config -> degrees here, at THE one place).
        let radToDeg = 180.0 / Double.pi
        silenceThresholdDegrees = config.cueSilenceThreshold * radToDeg
        limitDegrees            = config.cueLimitPitch * radToDeg
        pitchCapDegrees         = config.cuePitchCap * radToDeg
        baseFrequency           = config.cueBaseFrequency
        peakFrequency           = config.cuePeakFrequency
        minPulseRate            = config.cueMinPulseRate
        maxPulseRate            = config.cueMaxPulseRate
        minDutyCycle            = config.cueMinDutyCycle
        maxDutyCycle            = config.cueMaxDutyCycle
        amplitudeExponent       = config.cueAmplitudeExponent
        maxAmplitude            = Float(config.cueMaxAmplitude)

        // Hysteresis latch (radians in Config -> degrees here, same one place).
        enterDegrees   = config.cueEnterPitch * radToDeg
        exitDegrees    = config.cueExitPitch * radToDeg
        releaseTime    = config.cueReleaseTime
        deadbandDegrees = config.cueDeadband * radToDeg

        computeSmoothingCoefficients()
        configureSession()
        setupEngine()
        observeRouteChanges()
        observeInterruptions()
        observeConfigurationChanges()
    }

    /// One-pole smoothing coefficients toward each target. Depend only on
    /// `sampleRate` and the fixed smoothing times, so computed once  rather
    /// than three `exp()` per render callback.
    private func computeSmoothingCoefficients() {
        ampCoeff  = Float(1.0 - exp(-1.0 / (sampleRate * amplitudeSmoothingTime)))
        freqCoeff = 1.0 - exp(-1.0 / (sampleRate * frequencySmoothingTime))
        gateCoeff = Float(1.0 - exp(-1.0 / (sampleRate * gateSmoothingTime)))
    }

    deinit {
        stop()
        NotificationCenter.default.removeObserver(self)
    }

    func start() {
        controlLock.lock(); defer { controlLock.unlock() }
        intendedRunning = true
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
        controlLock.lock(); defer { controlLock.unlock() }
        intendedRunning = false
        wasRunningBeforeInterruption = false
        isSounding = false
        belowExitSince = nil
        lastLatchAngle = 0
        cueParameters.withLock { $0 = .silent }
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
        controlLock.lock(); defer { controlLock.unlock() }
        guard intendedRunning, pitchDegrees.isFinite else { return }
        let clamped = max(0, min(pitchDegrees, pitchCapDegrees))
        let now = ProcessInfo.processInfo.systemUptime

        // Hysteresis latch (WORK ITEM B5). The tone used to be gated by a single
        // `clamped >= silenceThresholdDegrees` test recomputed every call with no
        // memory, so at the entry angle — where every wheelie begins — vibration
        // chattered the tone on and off at 100 Hz. Now: turn ON at `enterDegrees`,
        // and stay on until the angle has held below `exitDegrees` (lower, so the
        // boundary is split) for `releaseTime`. `deadbandDegrees` ignores jitter
        // smaller than itself so it cannot by itself drive the release timer.
        if isSounding {
            if clamped >= exitDegrees {
                // Back above exit: cancel any pending release.
                belowExitSince = nil
            } else if abs(clamped - lastLatchAngle) >= deadbandDegrees || belowExitSince != nil {
                // Genuinely below exit (past the deadband). Start/continue the
                // release timer; release once it has held long enough.
                if belowExitSince == nil { belowExitSince = now }
                if let since = belowExitSince, now - since >= releaseTime {
                    isSounding = false
                    belowExitSince = nil
                }
            }
        } else {
            if clamped >= enterDegrees {
                isSounding = true
                belowExitSince = nil
            }
        }
        lastLatchAngle = clamped

        // Latch says silent → emit the silent snapshot and stop. This replaces the
        // old raw-angle deadband guard.
        guard isSounding else {
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
            $0 = CueParameters(updatedAt: now, amplitude: continuous ? maxAmplitude : amplitude,
                               frequency: continuous ? peakFrequency : frequency,
                               pulseRate: pulseRate,
                               dutyCycle: dutyCycle,
                               continuous: continuous)
        }

        // 1 Hz target heartbeat — CONTROL PATH, not the render thread. `update` is
        // called ~100 Hz from the pipeline, so gate emission on a lock-protected
        // timestamp. This logs the SYNTHESIS TARGETS (what we asked the tone to do)
        // for the current angle; the render callback itself is never instrumented.
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
        var params = cueParameters.withLock { $0 }
        if ProcessInfo.processInfo.systemUptime - params.updatedAt > 2.5 { params = .silent }

        // do NOT assume one mono Float buffer of
        // exactly `frameCount` samples. If the hardware format diverges after a route
        // change, `mData` may be nil or the buffer may be smaller than `frameCount`,
        // and binding `count: Int(frameCount)` then writing all of them ran off the
        // end. Bail if the pointer is nil, and cap the write at the buffer's REAL
        // capacity derived from `mDataByteSize`. No logging/allocation here — this is
        // the real-time thread.
        let mBuffers = bufferList.pointee.mBuffers
        guard let base = mBuffers.mData?.assumingMemoryBound(to: Float.self) else {
            return noErr
        }
        let capacity = Int(mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        let framesToRender = min(Int(frameCount), capacity)
        let buffer = UnsafeMutableBufferPointer<Float>(start: base, count: framesToRender)

        // One-pole smoothing coefficients are precomputed — they depend only
        // on sampleRate and the fixed smoothing times, so recomputing exp() per
        // callback was wasted work on the render thread.
        for frame in 0..<framesToRender {
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

    // MARK: - Interruption handling (FIX — the tone dies after a phone call)
    //
    // Before this, the renderer observed ONLY `routeChangeNotification`. On an
    // AVAudioSession interruption (incoming call, Siri, another app taking the
    // session) iOS stops the engine and posts NOTHING that the old code listened
    // for, so the safety cue went silent for the REST of the ride with no signal —
    // the single defect this fix exists to close. We now resume on `.ended` with
    // `.shouldResume`, and if the resume FAILS we shout about it through `diag` at
    // error level rather than failing silently.
    private func observeInterruptions() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }

    @objc private func handleInterruption(_ notification: Notification) {
        controlLock.lock(); defer { controlLock.unlock() }
        guard let info = notification.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else {
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        switch type {
        case .began:
            // iOS has (or is about to) stop our engine. Record whether we were
            // sounding so `.ended` knows to bring it back.
            wasRunningBeforeInterruption = engine.isRunning
            diag.always(time: now, level: .warn,
                        message: "audio interruption began — engine stopped by iOS",
                        values: ["wasRunning": wasRunningBeforeInterruption ? 1 : 0])
        case .ended:
            // Only resume if iOS says we may AND we were running before.
            let options: AVAudioSession.InterruptionOptions
            if let optRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                options = AVAudioSession.InterruptionOptions(rawValue: optRaw)
            } else {
                options = []
            }
            guard intendedRunning, options.contains(.shouldResume), wasRunningBeforeInterruption else {
                diag.always(time: now, level: .warn,
                            message: "audio interruption ended — not resuming",
                            values: ["shouldResume": options.contains(.shouldResume) ? 1 : 0,
                                     "wasRunning": wasRunningBeforeInterruption ? 1 : 0])
                return
            }
            wasRunningBeforeInterruption = false
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                try engine.start()
                updateRouteLatency()
                diag.always(time: now, level: .info,
                            message: "audio engine resumed after interruption",
                            values: [:])
            } catch {
                // SILENT FAILURE is the exact thing being fixed — surface it loud.
                log.error("Failed to resume after interruption: \(error.localizedDescription)")
                diag.always(time: now, level: .error,
                            message: "audio engine resume FAILED after interruption — cue is silent",
                            values: ["code": Double((error as NSError).code)])
            }
        @unknown default:
            break
        }
    }

    // MARK: - Configuration-change handling (FIX)
    //
    // `.AVAudioEngineConfigurationChange` fires when the engine's I/O format changes
    // out from under us — a route change to/from Bluetooth, a sample-rate change,
    // hardware reconfiguration. When it does, the source-node connection can be torn
    // down and the engine left stopped; the render callback then either never runs
    // or previously writes into a mismatched buffer. Re-establish the connection
    // and restart, and if that fails, say so through `diag`.
    private func observeConfigurationChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
    }

    @objc private func handleConfigurationChange(_ notification: Notification) {
        controlLock.lock(); defer { controlLock.unlock() }
        guard intendedRunning else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // Re-establish the source-node -> mixer connection at our fixed format.
        // sampleRate is a `let`, so the precomputed coefficients remain valid; the
        // recompute is here for correctness if that ever changes.
        computeSmoothingCoefficients()
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        if let node = sourceNode {
            engine.connect(node, to: engine.mainMixerNode, format: format)
        }
        // A config change can leave the engine stopped. Restart if it is not running.
        guard !engine.isRunning else {
            diag.always(time: now, level: .info,
                        message: "audio engine reconfigured (still running)",
                        values: [:])
            return
        }
        do {
            try engine.start()
            updateRouteLatency()
            diag.always(time: now, level: .info,
                        message: "audio engine restarted after configuration change",
                        values: [:])
        } catch {
            log.error("Failed to restart after configuration change: \(error.localizedDescription)")
            diag.always(time: now, level: .error,
                        message: "audio engine restart FAILED after configuration change — cue is silent",
                        values: ["code": Double((error as NSError).code)])
        }
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
