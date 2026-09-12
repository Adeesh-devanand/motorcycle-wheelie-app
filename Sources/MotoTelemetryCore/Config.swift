import Foundation

/// Every tunable constant, in one versioned struct.
///
/// This gets serialized into each log's header, so a log always says which
/// parameters produced it and an old ride can be replayed against new tuning.
/// Nothing in the pipeline may read a magic number that does not live here.
///
/// ## Versioning contract
/// `version` is incremented whenever a field is added, removed, or its default
/// meaning changes. Decoding is TOLERANT: an older header that lacks newer keys
/// decodes with this struct's current defaults for them, so a v1 log recorded
/// before a field existed still replays. `motolog` prints both the header's
/// version and any override in force, so which parameters produced a number is
/// never ambiguous.
///
/// v1 -> v2: `eventExitPitch` 4 deg -> 5 deg to match docs/ui-spec.md 7.6;
/// added the entry/exit dwells the ui spec required but which had no home here;
/// added the estimator, smoother, cue, quality, writer and display parameters.
///
/// v2 -> v3: calibration made survivable on a running bike, after every one of
/// its guards was found to reject a usable zeroing in favour of none at all.
/// `biasSigmaLimit` 0.01 -> 0.05 deg/s: the old value sat on the gyro's own noise
/// floor, so a zeroing passed or failed on luck rather than on anything the rider
/// controlled, and 0.05 deg/s is the error budget the README already states.
/// Added `gateCloseConfirm`, so a band violation must persist ~60 ms before the
/// gate closes and a single buzz sample can no longer slam it shut — duration, not
/// amplitude, is what separates engine excitation from real acceleration. Added
/// `biasGateGracePeriod`, so a transient dropout no longer discards seconds of
/// accumulation. `calibrationVibrationThreshold` no longer FAILS a zeroing -- it
/// only decides whether an out-of-band rejection is reported as vibration, which is
/// all its own doc comment ever claimed it did.
///
/// v3 -> v4: the calibration gate stopped flapping, and the attitude anchor gained
/// the test it always needed. On a phone merely being HANDLED for 197 s a device log
/// recorded 3,698 gate-reason transitions — 933 `specificForceOutOfBand`, 1,429
/// `rotating` — so a +/-0.03 g band was never going to be satisfied with an engine
/// running. The band is widened to +/-0.10 g for CALIBRATION only
/// (`calibrationSpecificForceLow/High`), because there it is an accelerometer proxy
/// for stillness that never enters the gyro mean, so the cost to the bias estimate is
/// under 0.001 deg/s. It is deliberately NOT widened for the estimator: the same
/// verdict also gates the ESKF's gravity update, where 0.3 g of thrust gives
/// |f| = 1.044 g — inside a +/-0.10 g band — and admitting it converges the filter on
/// the phantom angle atan(0.3) = 16.7 deg, which is the single failure this project
/// exists to prevent. `gateMaxRotationRate` was ALSO tried as a shared 3 -> 5 deg/s
/// and reverted: the estimator keeps 3 and calibration gets
/// `calibrationMaxRotationRate` = 5, because a wider shared limit kept the gate open
/// into the start of a lift and pinned the live angle at zero until it snapped.
/// Added `anchorLevelCosine`: specific-force
/// MAGNITUDE is orientation-invariant at rest, so the anchor's old magnitude-only test
/// could not reject a tilt, and a 29.3 deg hand-held pose became the definition of
/// level for 12 s.
///
/// v5 -> v6: the estimator was REPLACED, not made switchable. The gated ESKF, the
/// RTS smoother, the delayed-state GNSS correction and the grade baseline are gone
/// from this branch; the live path is raw gyro debiased by a constant measured once
/// at calibration. There is deliberately no mode flag: a switch with one live case
/// is the dead code path this deletion existed to remove, and `version` already
/// tells a log which estimator produced it. Added `calibrationVibrationLimit`,
/// which unlike the reporting-only `calibrationVibrationThreshold` actually REJECTS
/// a sample: specific-force magnitude is AC-blind, so engine buzz swings |f|
/// direction violently while its mean stays at 1 g, and a vibration-corrupted
/// gravity anchor would otherwise become the permanent reference for a whole
/// session. Added `alignmentConfidenceMin` for the swipe capture's degeneracy test,
/// the cue's enter/exit pair and deadband (a single threshold with no latch chatters
/// at exactly the angle every wheelie starts at), and the jitter-blur window.
/// Changed defaults: `eventMinDuration` 0.4 -> 1.0 s, `biasCalibrationDuration`
/// 8.0 -> 2.0 s.
///
/// ### v6 -> v7
/// Named the two stream-continuity limits that were previously hardcoded literals:
/// `maxIntegrationDt` (the estimator's "this dt is absurd, resynchronise" cutoff,
/// was a bare `1.0` inside `CalibrateOnceEstimator.integrate`) and `maxSampleGap`
/// (the "the stream lost continuity" cutoff, was a bare `0.5` inside
/// `Pipeline.processIMU`'s gap warning). Both are now read by a second consumer —
/// `EventSegmenter` restarts its entry/exit dwell across a gap, because a dwell is
/// a claim that pitch was SUSTAINED and a gap is precisely the absence of evidence
/// for that. Adding a field is backward-compatible: `init(from:)` is tolerant, so a
/// v6 header decodes with these defaults.
///
/// Also moved the cue's angle-to-tone TRANSFER CURVE out of `CueAudioRenderer`,
/// where the whole policy lived as private `let`s that never reached a log
/// header — so a replay could reproduce the numbers the estimator saw but not
/// the sound the rider actually heard, which for a safety cue is the part that
/// matters. The rider-facing policy is now the `cueSilenceThreshold`,
/// `cueLimitPitch`, `cuePitchCap`, `cueBaseFrequency`, `cuePeakFrequency`,
/// `cueMinPulseRate`, `cueMaxPulseRate`, `cueMinDutyCycle`, `cueMaxDutyCycle`,
/// `cueAmplitudeExponent` and `cueMaxAmplitude` group below. The three angle
/// fields are stored in RADIANS to match every other angle in this struct
/// (`cueEnterPitch`, `eventEntryPitch`, …); the renderer works in degrees and
/// converts on read at one place. The three one-pole smoothing time constants
/// (`amplitudeSmoothingTime`, `frequencySmoothingTime`, `gateSmoothingTime`)
/// deliberately STAYED local to the renderer: they are pure-DSP anti-click and
/// anti-zipper implementation detail — they shape how the tone glides, not what
/// angle maps to what sound — so they are not rider-facing policy and their
/// value does not change what a replay must reproduce.
///
/// ### v7 -> v8
/// More tolerance for real-world noise during calibration, bought from DURATION and
/// not from amplitude: `gateCloseConfirm` 0.06 -> 0.15 s and `biasGateGracePeriod`
/// 0.25 -> 0.5 s. Both govern only whether a transient breach costs the rider the
/// dwell or the progress already accumulated. Neither changes which samples are
/// averaged — `ValidityGate.sampleWithinBand` still refuses every individual
/// violating sample — so the bias budget is untouched. This is what addresses
/// "calibration keeps restarting": the 17:52 device log is a run of `dwellNotMet`
/// where each short tremor burst reset a 0.5 s dwell and one window took 60 s.
///
/// `calibrationMaxRotationRate` was ALSO raised 5 -> 12 deg/s here and REVERTED in
/// the same session. That is the amplitude knob, and it is not safe: a one-sided
/// spike moves the mean directly (one 20 deg/s sample in 600 shifts the bias
/// 0.033 deg/s, most of the 0.05 deg/s budget), and a sustained rotation has zero
/// variance so `biasSigmaLimit` cannot see it at all — a steady 10 deg/s turn was
/// adopted AS the bias, 100 deg of error over a 10 s hold. Two existing tests caught
/// it. The lesson is the v3 lesson again: for a stillness gate, duration
/// discriminates and amplitude does not.
///
/// Note also that `gateMaxRotationRate` and `gateSpecificForceLow/High` no longer
/// have a live consumer: `AttitudeESKF` was deleted in the beta, `BiasEstimator`
/// overrides all three with its `calibration*` counterparts, and the only other
/// `ValidityGate` is the one `motolog replay` builds for gate-open reporting. Their
/// documented "the estimator must not inherit this" reasoning is kept because it is
/// the record of why the split exists, but it now describes an estimator that is
/// gone — do not read those two as live tuning.

public struct Config: Codable, Sendable, Equatable {
    public var version: Int = 9

    // MARK: - Validity gate
    // Opens only when we can PROVE quasi-static, because the accelerometer cannot
    // distinguish lean from turning or tilt from acceleration. At lean angle t the
    // specific-force magnitude is 1/cos(t), so 20 deg = 1.06 g and 30 deg = 1.15 g:
    // a +/-0.03 g window rejects anything past ~14 deg of lean before the rate
    // test even fires.
    //
    // This band is the ESTIMATOR's, and it stays tight.
    // `AttitudeESKFTests.testSustainedThrustDoesNotDragTheEstimateToThePhantomAngle`
    // is why: 0.3 g of forward thrust gives |f| = 1.044 g, so any band looser than
    // about +/-0.04 g calls sustained acceleration "at rest" and feeds its 16.7 deg
    // of phantom tilt straight into the gravity update. Calibration's own, looser
    // band is separate — see `calibrationSpecificForceLow/High`.
    public var gateSpecificForceLow: Double = 0.97 * 9.80665   // m/s^2
    public var gateSpecificForceHigh: Double = 1.03 * 9.80665  // m/s^2
    /// Per-axis rotation ceiling, rad/s. Widened 3 -> 5 deg/s in v4 and NO further:
    /// unlike the specific-force band this bounds real rotation during the 8-second
    /// gyro mean, so a sustained rotation admitted here is averaged straight into
    /// the bias.
    ///
    /// This is the ESTIMATOR's limit and it stays at 3 deg/s. Calibration gets the
    /// wider `calibrationMaxRotationRate` — the same split already applied to the
    /// specific-force band, and for the same reason: the two consumers of this verdict
    /// want different things. Raising the SHARED value to 5 deg/s was tried and
    /// reverted. The 17:52 device log shows why: the verdict also gates the ESKF's
    /// gravity update, so during the slow start of a lift the gate stayed open longer,
    /// the filter kept treating a thrust-contaminated specific force as pure gravity,
    /// and it pinned the reported angle near zero until rotation finally breached the
    /// limit — then the gate closed, gyro integration took over, and the angle raced to
    /// catch up. Measured: pitch 3.59 -> 0.66 -> 0.09 deg with gateOpen=1 while the bike
    /// was already being lifted, then 3.75 -> 19.6 -> 35.3 -> 45.7 once gateOpen=0. The
    /// rider sees "it doesn't move at all and then suddenly shoots up".
    public var gateMaxRotationRate: Double = 3.0 * .pi / 180   // rad/s, per axis
    public var gateDwell: TimeInterval = 0.5                   // must hold this long
    /// How long a band violation must PERSIST before the gate actually closes.
    ///
    /// The gate compares the raw instantaneous sample, as it always did — but a
    /// single violating sample no longer slams it. That instantaneous closure is
    /// what made the gate an accidental vibration detector: on an idling bike one
    /// buzz sample leaves the +/-0.03 g window, closes the gate, resets the dwell
    /// and discards accumulated calibration, so 8 s of unbroken quiet never
    /// assembles and calibration sticks at 0% forever.
    ///
    /// Duration is the right discriminator, not amplitude. Engine excitation
    /// violates the band for at most half a cycle — 83 Hz aliases to 17 Hz at a
    /// 100 Hz sampler, so ~30 ms — while acceleration, braking and lean violate it
    /// for as long as they last. 60 ms therefore rejects buzz and still catches
    /// anything real.
    ///
    /// A LOW-PASS was tried here first and is the wrong mechanism: it delays closure
    /// by its time constant AND attenuates, so a 0.5 g onset reaches only 63% of its
    /// value after one tau and the filter keeps taking contaminated gravity updates
    /// deep into the ramp. `AccuracyMatrixTests` catches that as live error past 2
    /// deg. A confirmation window is exact and bounded: full amplitude, closed after
    /// 60 ms, no attenuation.
    ///
    /// This does NOT address aliasing: a twin at 6000 rpm folds to DC and looks like
    /// a steady tilt at any window length. That is attenuated mechanically, at the
    /// mount.
    ///
    /// Raised 0.06 -> 0.15 s in v8, and this is the RIGHT knob for noise tolerance
    /// because of what it does not touch. It decides only whether a breach costs the
    /// rider the dwell; `ValidityGate.sampleWithinBand` still refuses every
    /// individual violating sample, so nothing extra enters the bias mean and the
    /// accuracy budget is untouched. Contrast `calibrationMaxRotationRate`, where
    /// widening admits contaminated samples into the average.
    ///
    /// 150 ms sits between the two timescales that matter: a tremor or buzz burst is
    /// tens of milliseconds, while acceleration, braking and lean persist for as long
    /// as they last, so real motion still closes the gate ~150 ms in and keeps it
    /// shut. What this fixes is the reported "calibration keeps restarting" — the
    /// 17:52 log is a run of `dwellNotMet` where every short tremor burst reset a
    /// 0.5 s dwell, so the continuous-quiet stretch never assembled and one window
    /// took 60 s.
    public var gateCloseConfirm: TimeInterval = 0.15            // seconds

    /// Specific-force band for the CALIBRATION gate only, m/s^2. +/-0.10 g.
    ///
    /// `BiasEstimator` builds its own `ValidityGate` from these instead of
    /// `gateSpecificForceLow/High`, because the two consumers of a stillness verdict
    /// have opposite sensitivities to a loose band:
    ///
    /// - For the **bias mean** the band is only an accelerometer PROXY for "the bike
    ///   is not moving". It never enters the average, which is a gyro mean, so a
    ///   sample admitted at 1.08 g contributes exactly the same quiet gyro reading as
    ///   one admitted at 1.02 g. Cost of widening: under 0.001 deg/s.
    /// - For the **ESKF gravity update** the band IS the accuracy guard. Specific
    ///   force during acceleration is gravity plus thrust, and 0.3 g of thrust gives
    ///   |f| = 1.044 g — comfortably inside +/-0.10 g — while pointing 16.7 deg wrong.
    ///
    /// So the estimator keeps +/-0.03 g and calibration gets +/-0.10 g. A device log
    /// recorded 933 `specificForceOutOfBand` rejections in 197 s from a phone being
    /// handled on a desk; on an idling bike the tight band made an 8-second window of
    /// unbroken quiet essentially unassemblable, which is the whole reason calibration
    /// never finished. `gateMaxRotationRate` IS now split too — see
    /// `calibrationMaxRotationRate` below and the device evidence on
    /// `gateMaxRotationRate` itself. Dwell remains shared.
    public var calibrationSpecificForceLow: Double = 0.90 * 9.80665   // m/s^2 (-0.10 g)
    public var calibrationSpecificForceHigh: Double = 1.10 * 9.80665  // m/s^2 (+0.10 g)
    /// Calibration's rotation ceiling, rad/s. 5 deg/s against the estimator's 3.
    ///
    /// Split for the same reason as the band above, though the argument is different:
    /// here the admitted rotation DOES enter the gyro mean, but `biasSigmaLimit`
    /// (0.05 deg/s on the SEM) bounds a NOISY zeroing, and a measured healthy SEM of
    /// 0.0018 deg/s leaves 28x of margin.
    ///
    /// **Do not raise this to buy noise tolerance.** Tried in v8 at 12 deg/s and
    /// reverted the same session. Two things make it unsafe, and sigma catches
    /// neither:
    ///
    /// - A one-sided spike moves the mean directly. `ValidityGate.sampleWithinBand`
    ///   carries the arithmetic: one 20 deg/s sample among 600 quiet ones shifts the
    ///   bias by 0.033 deg/s, most of the 0.05 deg/s budget.
    /// - A SUSTAINED rotation has zero variance, so the SEM is ~0 and
    ///   `biasSigmaLimit` passes it. At a 12 deg/s ceiling a bike turning steadily at
    ///   10 deg/s was adopted AS THE BIAS — 100 deg of error over a 10 s hold.
    ///   `CalibrationTests.testMovingBikeIsRejectedWithTheGatesReason` and
    ///   `testAttemptWindowGivesUpAndExplainsWhy` both caught exactly this.
    ///
    /// Amplitude is the wrong discriminator here, as it was for the specific-force
    /// band in v3. Noise tolerance is bought with `gateCloseConfirm` instead: it
    /// decides how long a breach must persist before the DWELL is lost, and changes
    /// nothing about which samples are averaged.
    ///
    /// The estimator must NOT inherit this: see `gateMaxRotationRate` for the device
    /// evidence that a wider shared limit makes the live angle stick at zero during a
    /// lift and then jump.
    public var calibrationMaxRotationRate: Double = 5.0 * .pi / 180   // rad/s, per axis

    /// How much the gyro bias must MOVE before adopting a new estimate re-anchors
    /// the attitude, rad/s. 0.01 deg/s.
    ///
    /// A re-anchor resets the rider's reported angle to zero, so it must be earned.
    /// A device log shows seven calibrations in one session all measuring the same
    /// bias to three decimals (`meanBiasX` -0.097, `meanBiasY` 0.013, `meanBiasZ`
    /// 0.111 every time, SEM 0.0018 deg/s) — six of those re-anchors changed nothing
    /// except to yank the angle back to 0 mid-ride. 0.01 deg/s sits ~5 sigma above
    /// that repeatability, so a genuine change (a remount, or thermal drift, which
    /// runs ~0.1 deg/s over 30 min) still gets through.
    ///
    /// This threshold never blocks a re-anchor the RIDER asked for: tapping the pill
    /// means "this pose is level", which is a statement about the angle reference and
    /// not about the bias at all.
    public var reanchorBiasDelta: Double = 0.01 * .pi / 180     // rad/s

    // MARK: - Cue engine
    // Fire on time-to-threshold, not on crossing it: angle is a lagging indicator
    // and by the time you cross you are committed.
    public var timeToThresholdWarn: TimeInterval = 0.4
    /// Added to the lead time to absorb Bluetooth audio latency.
    /// HFP/SCO ~0.05 s; A2DP is 0.1-0.2 s and too slow — prefer wired or SCO.
    /// Replaced at runtime by the measured route latency when one is available.
    public var audioLatencyCompensation: TimeInterval = 0.05
    /// Pitch rate above which the loop-out warning preempts the approach tone.
    public var loopOutPitchRate: Double = 60.0 * .pi / 180     // rad/s
    /// A sounding tone persists until its condition has been false this long.
    /// Without it a tone chatters on and off across the boundary at 100 Hz.
    public var cueReleaseTime: TimeInterval = 0.15
    /// Tone starts at this pitch. Matches `eventEntryPitch` so the audio and the
    /// segmenter agree on what counts as up.
    public var cueEnterPitch: Double = 10.0 * .pi / 180        // rad
    /// Tone stops at this pitch — deliberately BELOW `cueEnterPitch`, so the gate
    /// latches. `CueAudioRenderer` shipped with one 10 deg comparison and no
    /// latched state, and 10 deg is exactly where every wheelie begins, so
    /// vibration toggled the tone on and off through the boundary. This is the
    /// same defect as `eventExitPitch` solves one layer up.
    public var cueExitPitch: Double = 7.0 * .pi / 180          // rad
    /// The tone ignores pitch changes smaller than this, so it tracks the wheelie
    /// rather than the vibration. Starting guess; owed a number from real ride
    /// data. The renderer's one-pole audio glides do NOT substitute — they smooth
    /// the tone, not the decision, so a flapping decision still flaps.
    public var cueDeadband: Double = 0.5 * .pi / 180           // rad

    // MARK: - Cue transfer curve (angle -> tone)
    // The angle-to-tone mapping the renderer synthesises. Lived as private lets
    // inside `CueAudioRenderer`, so none of it reached this struct and therefore
    // none of it reached a log header: a replay could reproduce what the estimator
    // saw but not what the rider HEARD. For a safety cue the sound is the output,
    // so its policy belongs here with everything else a log must be able to
    // reconstruct. Angles are in RADIANS to match the rest of this struct; the
    // renderer converts to degrees on read, at one place.
    //
    // NOTE these are the SAME angle as `cueEnterPitch`/`cueExitPitch` above but a
    // different job: enter/exit are the ON/OFF latch (FIX B5), whereas
    // `cueSilenceThreshold`…`cuePitchCap` shape the tone once it IS on. They are
    // kept distinct rather than folded together because the latch boundary and the
    // synthesis floor answer different questions and can be tuned independently.
    /// Below this angle the renderer is silent. Keeps normal riding, bumps and
    /// lean from making noise (the variometer "climb threshold" convention).
    public var cueSilenceThreshold: Double = 10.0 * .pi / 180  // rad
    /// At and above this angle the tone goes solid at full cap — the categorical
    /// past-the-limit signal. Well past a wheelie's balance point, so the whole
    /// usable range stays inside the pulsed zone.
    public var cueLimitPitch: Double = 70.0 * .pi / 180        // rad
    /// Ceiling for the amplitude and pitch maps. Angles above clamp here.
    public var cuePitchCap: Double = 90.0 * .pi / 180          // rad
    /// Carrier at the silence threshold. Above the phone speaker's low-end rolloff
    /// and above the helmet wind-noise energy peak (250-500 Hz).
    public var cueBaseFrequency: Double = 1000.0              // Hz
    /// Carrier at the cap — the ear's most sensitive band (2-5 kHz, peaking ~3 kHz
    /// from ear-canal resonance), worth 6-8 dB of free perceived loudness.
    public var cuePeakFrequency: Double = 3000.0             // Hz
    /// Beep rate at the silence threshold. Rises with angle toward `cueMaxPulseRate`.
    public var cueMinPulseRate: Double = 2.0                 // Hz
    /// Beep rate just below the limit. Kept under the ~20 Hz click-fusion threshold
    /// so beeps stay countable, near the ~10 Hz tempo-discrimination optimum.
    public var cueMaxPulseRate: Double = 12.0                // Hz
    /// Fraction of each pulse period sounding at the silence threshold — a short
    /// chirp with a long gap.
    public var cueMinDutyCycle: Double = 0.30
    /// Fraction sounding just below the limit — widened toward solid, the
    /// far-to-near progression parking sensors use.
    public var cueMaxDutyCycle: Double = 0.70
    /// Non-linear amplitude curve exponent. Raw amplitude ∝ t^n; perceived loudness
    /// then grows as t^(0.6n) by Stevens' power law, so n = 2 gives clearly
    /// accelerating loudness while keeping the mid range audible. Raise toward 3-5
    /// for a more violent late rush, lower to 1.67 for perceptually linear.
    public var cueAmplitudeExponent: Double = 2.0
    /// Fixed internal amplitude ceiling. Below 1.0 for headroom against clipping;
    /// iOS still scales the final output by the device volume on top of this.
    public var cueMaxAmplitude: Double = 0.85

    // MARK: - Event segmentation
    public var eventEntryPitchRate: Double = 15.0 * .pi / 180  // rad/s
    /// 10 deg. Nothing below this counts as a wheelie and nothing below this is
    /// clocked: in the 0-10 deg band the reported angle is dominated by
    /// suspension travel, driveway lips and mount slop rather than by riding, so
    /// counting it inflates both the attempt count and every duration.
    public var eventEntryPitch: Double = 10.0 * .pi / 180      // rad
    /// 7 deg, preserving 3 deg of hysteresis below entry. Duration is therefore
    /// "time above 10 deg" plus the 10->7 deg tail on the way down; setting exit
    /// equal to entry would chatter one wheelie into several at 100 Hz, so the
    /// tail is the price of a stable segment boundary.
    public var eventExitPitch: Double = 7.0 * .pi / 180        // rad
    public var eventEntryDwell: TimeInterval = 0.15
    public var eventExitDwell: TimeInterval = 0.25
    /// 1.0 s. An event shorter than this is DISCARDED, not shortened: a curb lip
    /// or a loft over a crest is not a wheelie and must not reach a leaderboard.
    /// Raised from 0.4 s deliberately — it rejects more borderline pop-ups at the
    /// cost of discarding genuine-but-very-short lofts, which is the right trade
    /// for a leaderboard that should only show real holds. Note this is a REJECT,
    /// not a delay: samples buffer from the interpolated 10 deg crossing, so the
    /// committed event's metrics see the entry ramp where a real peak can occur.
    public var eventMinDuration: TimeInterval = 1.0
    /// Deadband on pitch rate when locating the hold window's boundaries, so
    /// vibration does not produce spurious zero crossings.
    public var holdRateEpsilon: Double = 1.0 * .pi / 180       // rad/s

    // MARK: - Stream continuity
    // Two different questions about the same gap, which is why they are two fields
    // and not one. `maxIntegrationDt` asks "can I integrate across this?" and its
    // answer must be generous, because a legitimate 100 Hz stream that hiccups for
    // 200 ms is still worth integrating. `maxSampleGap` asks "was the signal
    // CONTINUOUS across this?" and its answer must be strict, because a dwell timer
    // and a gap-warning both depend on continuity rather than on magnitude.
    /// Beyond this, a dt is treated as a stream jump rather than a real interval:
    /// integrating it would rotate attitude by a fabricated amount, so the sample is
    /// skipped and the estimator resynchronises on the next pair.
    public var maxIntegrationDt: TimeInterval = 1.0
    /// Beyond this, the stream is considered to have lost continuity. Raises
    /// `QualityFlags.gapExceeded`, and restarts any dwell in progress: a dwell is a
    /// claim that pitch stayed above a threshold for a span, and across a gap there
    /// is no evidence either way, so the conservative reading is to start over.
    public var maxSampleGap: TimeInterval = 0.5

    // MARK: - Bias
    // Dominant error term in the whole system. A stationary average drives it to
    // ~0.002 deg/s, but self-heating walks it ~0.1 deg/s over 30 min, which is a
    // whole degree over a 10 s hold. So: track bias age and degrade reported
    // confidence with it.
    /// 2.0 s of continuously-clean stillness. Shortened from 8.0 s for the beta,
    /// and the arithmetic supports it: at `gyroNoiseDensity` 0.004 deg/s/sqrt(Hz)
    /// and 100 Hz, per-sample sigma is ~0.028 deg/s, so the standard error over
    /// 200 samples is ~0.002 deg/s — far inside `biasSigmaLimit` (0.05 deg/s).
    /// It is thinner against low-frequency wander, which is what 8 s was guarding;
    /// `biasSigmaLimit` still gates the result, so a bad window FAILS rather than
    /// passing quietly.
    public var biasCalibrationDuration: TimeInterval = 2.0
    public var biasStaleAfter: TimeInterval = 300.0            // seconds
    /// How long a zeroing attempt may fail to open the gate before it gives up
    /// and tells the rider why, rather than spinning indefinitely.
    public var biasAttemptWindow: TimeInterval = 30.0
    /// A zeroing whose per-axis sigma exceeds this FAILS, naming the axis.
    ///
    /// This is the STANDARD ERROR OF THE MEAN, `std/sqrt(n)`, not the raw spread:
    /// at 100 Hz over 8 s, n is ~800 and sqrt(n) ~28, so this limit demands a raw
    /// gyro spread under 1.4 deg/s. The previous 0.01 deg/s demanded under
    /// 0.28 deg/s, which is the noise floor of the sensor itself -- a zeroing then
    /// passed or failed on luck rather than on anything the rider could change,
    /// and the observed failures were 0.02-0.09 deg/s.
    ///
    /// What a breach actually costs is the point: bias error integrates linearly
    /// into angle, so 0.05 deg/s is 0.5 deg over a 10 s hold, which is exactly the
    /// budget stated in the README. Refusing a 0.02 deg/s estimate leaves the
    /// filter with NO bias at all, and an uncalibrated consumer gyro sits at
    /// 1-5 deg/s -- 10-50 deg over the same hold. The old limit therefore traded a
    /// 0.2 deg error for a 20 deg one. This limit is kept only as a ceiling
    /// against a zeroing taken while the bike was genuinely moving.
    public var biasSigmaLimit: Double = 0.05 * .pi / 180       // rad/s
    /// How long the validity gate may be CONTINUOUSLY closed before accumulated
    /// progress is discarded.
    ///
    /// Previously any single closed sample called `resetAccumulation()`, throwing
    /// away every sample collected so far and resetting the dwell. One 10 ms blip
    /// -- 0.2 deg of rotation, or one bump in the road -- cost 8 s of work, which
    /// on a running bike meant the 8 s never completed. Progress is now PAUSED
    /// across a dropout shorter than this and only discarded once the gate has
    /// been closed long enough that the bike may genuinely have moved or been
    /// re-oriented. Paused time does not count toward the required duration, so
    /// the estimate is still built from a full 8 s of quiet samples.
    ///
    /// Raised 0.25 -> 0.5 s in v8, alongside `gateCloseConfirm`, and safe for the same
    /// reason: a grace period governs whether ACCUMULATED progress survives a
    /// dropout, never which samples are averaged. Every sample taken during the
    /// dropout is still refused by `sampleWithinBand`. Paired with the longer
    /// confirmation window so a tremor burst neither closes the gate nor, if it does,
    /// throws away the seconds already collected.
    public var biasGateGracePeriod: TimeInterval = 0.5          // seconds
    /// Bias process-noise multiplier by ProcessInfo.ThermalState raw value
    /// (nominal, fair, serious, critical).
    public var thermalBiasNoiseScale: [Double] = [1.0, 2.0, 4.0, 8.0]

    // MARK: - Sensor noise
    public var gyroBiasInstability: Double = 3.0 * .pi / 180 / 3600 // rad/s

    // MARK: - Metrics
    /// Below this many GNSS fixes inside an event, distance reports nil rather
    /// than a fabricated number.
    public var distanceMinFixes: Int = 4

    // MARK: - In-range intervals (docs/ui-spec.md 9.6)
    // Order of operations is load-bearing: merge gaps FIRST, then drop short
    // fragments. Filtering first would delete jitter around a band edge as three
    // sub-threshold fragments and then have nothing left to merge.
    public var intervalMinDuration: TimeInterval = 0.15
    public var intervalMergeGap: TimeInterval = 0.10

    // MARK: - Quality and aliasing disclosure
    /// Corner of the one-pole high-pass whose RMS is the vibration indicator.
    public var highFreqCutoff: Double = 20.0                   // Hz
    /// Above this 1 s RMS, calibration fails and rides are flagged. The fix named
    /// to the rider is mechanical isolation, never a software setting.
    public var highFreqRMSThreshold: Double = 1.5              // m/s^2
    /// Standard deviation of |specific force| above which a stationary
    /// calibration is rejected as too shaky, m/s^2. A separate, much lower
    /// threshold than the ride-time one, and a different statistic.
    ///
    /// The validity gate's specific-force window is +/-0.03 g, i.e. 0.294 m/s^2,
    /// so any vibration big enough to reach `highFreqRMSThreshold` has already
    /// been rejected by the gate — instantaneously, since the gate does not
    /// average. That left the vibration failure unreachable during calibration
    /// and told a rider with a buzzing mount that the bike "is not level and
    /// still", which is true but useless. So: the gate remains the detector, and
    /// this threshold decides whether an out-of-band rejection is REPORTED as
    /// vibration. It must sit below the gate's window to be reachable.
    ///
    /// As of v3 this is REPORTING ONLY and can no longer fail a zeroing. It used to,
    /// which made calibrating on a running bike impossible and mid-ride
    /// recalibration impossible outright. The justification does not survive
    /// inspection: the bias estimate is the MEAN of the gyro, and averaging is
    /// precisely the operation that removes zero-mean vibration -- its uncertainty
    /// falls as `std/sqrt(n)`, which `biasSigmaLimit` already bounds. Only two paths
    /// turn vibration into a DC error that a mean cannot reject: SATURATION, whose
    /// non-linear rail rectifies AC into DC and which is still a hard reject on its
    /// own flag, and ALIASING, which a spread test cannot see at all. So this
    /// measurement never defended against the case that can actually hurt, and
    /// blocked the case that cannot.
    public var calibrationVibrationThreshold: Double = 0.1  // m/s^2
    /// Standard deviation of |specific force| above which the gate REJECTS a
    /// sample, m/s^2. Distinct from `calibrationVibrationThreshold` above, which is
    /// reporting-only; this one actually closes the gate.
    ///
    /// It exists because the note above is right about averaging and wrong about
    /// this being harmless. Averaging removes zero-mean vibration from the GYRO
    /// mean, yes — but calibration also produces the GRAVITY anchor, and the
    /// accelerometer's specific-force magnitude is AC-blind: engine buzz swings the
    /// force DIRECTION violently while |f| averages to almost exactly 1 g, so
    /// in-band vibration passes the band test untouched. The resulting tilted
    /// `gHat` becomes the permanent reference for every pitch reading in the
    /// session, with no way to detect it afterwards. `magnitudeStdDev` sees it
    /// regardless of what frequency it aliased down from, including DC.
    ///
    /// Set BELOW the calibration band (+/-0.10 g = 0.98 m/s^2) to be reachable.
    /// Starting value; owed a number from real idle-and-blip data.
    public var calibrationVibrationLimit: Double = 0.35     // m/s^2
    /// Runs whose reported uncertainty exceeds these are marked lowConfidence and
    /// excluded from personal bests.
    public var liveSigmaLimit: Double = 3.0 * .pi / 180        // rad

    // MARK: - Mount alignment

    /// Minimum |p| for a swipe-derived alignment, where p is the swipe direction
    /// with its gravity component removed. Below this the swipe carried NO yaw
    /// information and the naive answer is not noisy but 90 deg WRONG — it returns
    /// the bike's lateral axis, which puts the entire wheelie angle into the roll
    /// channel. So the solve refuses and the caller takes the screen-normal branch.
    ///
    /// |p| = sin(angle between the swipe and gravity), so 0.35 is about 20 deg of
    /// separation. It is not an extra calculation: it is the norm of the vector the
    /// solve already had to compute.
    public var alignmentConfidenceMin: Double = 0.35

    // MARK: - Jitter blur (beta recorded runs)
    /// Width of the zero-phase blur window, in samples. Must be ODD so the window
    /// is centred; an even width would shift the series in time, which is the one
    /// thing this filter exists not to do.
    ///
    /// 9 samples at 100 Hz is 90 ms — comfortably shorter than the fastest real
    /// pitch dynamics (DC-3 Hz) and long enough to average down vibration jitter.
    /// Too narrow leaves jitter; too wide starts eating the real peak. Owed a
    /// number from real ride data.
    public var blurWindowSamples: Int = 9
    /// Below this many samples an event is stored RAW with
    /// `QualityFlags.smoothingUnavailable` set, rather than blurred with a window
    /// wider than the data.
    public var blurMinSamples: Int = 25

    // MARK: - Barometer
    /// Dynamic-pressure coefficient for the barometer channel, calibrated per mount.
    /// Unused by the estimator — grade is not corrected at all in this build — but the
    /// channel stays in the wire format, so its coefficient stays with it.
    public var baroDynamicPressureK: Double = 0.0

    // MARK: - Logging and display
    public var nominalSampleRate: Double = 100.0               // Hz
    /// Rate of the decimated display series stored with a run. Raw stays in the
    /// session log and is hydrated on demand.
    public var displayDecimationRate: Double = 30.0            // Hz
    /// Ring-buffer depth between the sensor callback and the disk writer.
    /// Overwrite is FORBIDDEN: a full buffer increments a drop counter that
    /// surfaces in the integrity report and must be zero for a session to be
    /// trusted. Silently dropping raw samples would defeat the point of the log.
    public var writerRingCapacity: Int = 8192
    /// fsync cadence. This is what bounds "a force-quit loses at most 1 s".
    public var fsyncInterval: TimeInterval = 1.0
    /// Frames of full-screen white at ride start, as a visual alignment mark for
    /// an external camera. Replaces the withdrawn audio chirp.
    ///
    /// INERT as of 2026-09-04: its only consumer, `SyncFlashView`, was unreachable
    /// (no caller, no preview) and has been deleted. Kept rather than removed
    /// because the video-cross-correlation workflow it serves is still a wanted
    /// feature and this is the tuned value for it — but nothing reads it today, so
    /// do not infer from its presence that a sync flash happens.
    public var syncFlashFrames: Int = 6
    /// Full-scale ranges used to set IMUSample.saturated, with a 1% margin.
    public var gyroFullScale: Double = 2000.0 * .pi / 180      // rad/s
    public var accelFullScale: Double = 16.0 * 9.80665         // m/s^2


    // MARK: - Stationary drift recovery (v9)
    // Conservative stop-only updates. GNSS uses raw speed AND its error bound,
    // never the display's noise-floor-clamped zero. Unknown speed disables recovery.
    public var stationaryDwell: TimeInterval = 3.0
    public var stationaryMaxSpeed: Double = 0.3                // m/s
    public var stationaryMaxSpeedAccuracy: Double = 0.5        // m/s
    public var stationaryMaxRate: Double = 0.5 * .pi / 180      // rad/s, debiased
    public var stationaryForceTolerance: Double = 0.015 * 9.80665
    public var stationaryForceChange: Double = 0.0035 * 9.80665 // ~0.2 degree
    public var stationaryGyroChange: Double = 0.05 * .pi / 180
    public var alignmentScreenNormalMin: Double = 0.2

    public init() {}

    /// Tolerant decoding, required by the versioning contract above.
    ///
    /// Swift's synthesized `init(from:)` calls `decode` rather than
    /// `decodeIfPresent` for non-optional properties, so a default value does NOT
    /// make a missing key survive — a v1 header would throw `keyNotFound` on
    /// every field added in v2, and every log recorded before this commit would
    /// become unreadable. Hence the explicit initializer: absent keys fall back to
    /// this version's defaults, present keys win.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? fallback
        }

        version = try get(.version, d.version)
        stationaryDwell = try get(.stationaryDwell, d.stationaryDwell)
        stationaryMaxSpeed = try get(.stationaryMaxSpeed, d.stationaryMaxSpeed)
        stationaryMaxSpeedAccuracy = try get(.stationaryMaxSpeedAccuracy, d.stationaryMaxSpeedAccuracy)
        stationaryMaxRate = try get(.stationaryMaxRate, d.stationaryMaxRate)
        stationaryForceTolerance = try get(.stationaryForceTolerance, d.stationaryForceTolerance)
        stationaryForceChange = try get(.stationaryForceChange, d.stationaryForceChange)
        stationaryGyroChange = try get(.stationaryGyroChange, d.stationaryGyroChange)
        alignmentScreenNormalMin = try get(.alignmentScreenNormalMin, d.alignmentScreenNormalMin)


        gateSpecificForceLow  = try get(.gateSpecificForceLow, d.gateSpecificForceLow)
        gateSpecificForceHigh = try get(.gateSpecificForceHigh, d.gateSpecificForceHigh)
        gateMaxRotationRate   = try get(.gateMaxRotationRate, d.gateMaxRotationRate)
        gateDwell             = try get(.gateDwell, d.gateDwell)
        gateCloseConfirm      = try get(.gateCloseConfirm, d.gateCloseConfirm)
        calibrationSpecificForceLow  = try get(.calibrationSpecificForceLow, d.calibrationSpecificForceLow)
        calibrationSpecificForceHigh = try get(.calibrationSpecificForceHigh, d.calibrationSpecificForceHigh)
        calibrationMaxRotationRate   = try get(.calibrationMaxRotationRate, d.calibrationMaxRotationRate)
        reanchorBiasDelta     = try get(.reanchorBiasDelta, d.reanchorBiasDelta)

        timeToThresholdWarn      = try get(.timeToThresholdWarn, d.timeToThresholdWarn)
        audioLatencyCompensation = try get(.audioLatencyCompensation, d.audioLatencyCompensation)
        loopOutPitchRate         = try get(.loopOutPitchRate, d.loopOutPitchRate)
        cueReleaseTime           = try get(.cueReleaseTime, d.cueReleaseTime)
        cueEnterPitch            = try get(.cueEnterPitch, d.cueEnterPitch)
        cueExitPitch             = try get(.cueExitPitch, d.cueExitPitch)
        cueDeadband              = try get(.cueDeadband, d.cueDeadband)

        cueSilenceThreshold = try get(.cueSilenceThreshold, d.cueSilenceThreshold)
        cueLimitPitch       = try get(.cueLimitPitch, d.cueLimitPitch)
        cuePitchCap         = try get(.cuePitchCap, d.cuePitchCap)
        cueBaseFrequency    = try get(.cueBaseFrequency, d.cueBaseFrequency)
        cuePeakFrequency    = try get(.cuePeakFrequency, d.cuePeakFrequency)
        cueMinPulseRate     = try get(.cueMinPulseRate, d.cueMinPulseRate)
        cueMaxPulseRate     = try get(.cueMaxPulseRate, d.cueMaxPulseRate)
        cueMinDutyCycle     = try get(.cueMinDutyCycle, d.cueMinDutyCycle)
        cueMaxDutyCycle     = try get(.cueMaxDutyCycle, d.cueMaxDutyCycle)
        cueAmplitudeExponent = try get(.cueAmplitudeExponent, d.cueAmplitudeExponent)
        cueMaxAmplitude     = try get(.cueMaxAmplitude, d.cueMaxAmplitude)

        eventEntryPitchRate = try get(.eventEntryPitchRate, d.eventEntryPitchRate)
        eventEntryPitch     = try get(.eventEntryPitch, d.eventEntryPitch)
        eventExitPitch      = try get(.eventExitPitch, d.eventExitPitch)
        eventEntryDwell     = try get(.eventEntryDwell, d.eventEntryDwell)
        eventExitDwell      = try get(.eventExitDwell, d.eventExitDwell)
        eventMinDuration    = try get(.eventMinDuration, d.eventMinDuration)
        holdRateEpsilon     = try get(.holdRateEpsilon, d.holdRateEpsilon)

        maxIntegrationDt    = try get(.maxIntegrationDt, d.maxIntegrationDt)
        maxSampleGap        = try get(.maxSampleGap, d.maxSampleGap)

        biasCalibrationDuration = try get(.biasCalibrationDuration, d.biasCalibrationDuration)
        biasStaleAfter          = try get(.biasStaleAfter, d.biasStaleAfter)
        biasAttemptWindow       = try get(.biasAttemptWindow, d.biasAttemptWindow)
        biasSigmaLimit          = try get(.biasSigmaLimit, d.biasSigmaLimit)
        biasGateGracePeriod     = try get(.biasGateGracePeriod, d.biasGateGracePeriod)
        thermalBiasNoiseScale   = try get(.thermalBiasNoiseScale, d.thermalBiasNoiseScale)

        gyroBiasInstability  = try get(.gyroBiasInstability, d.gyroBiasInstability)

        distanceMinFixes = try get(.distanceMinFixes, d.distanceMinFixes)

        intervalMinDuration = try get(.intervalMinDuration, d.intervalMinDuration)
        intervalMergeGap    = try get(.intervalMergeGap, d.intervalMergeGap)

        highFreqCutoff       = try get(.highFreqCutoff, d.highFreqCutoff)
        highFreqRMSThreshold = try get(.highFreqRMSThreshold, d.highFreqRMSThreshold)
        calibrationVibrationThreshold = try get(.calibrationVibrationThreshold,
                                                   d.calibrationVibrationThreshold)
        calibrationVibrationLimit = try get(.calibrationVibrationLimit,
                                               d.calibrationVibrationLimit)
        liveSigmaLimit       = try get(.liveSigmaLimit, d.liveSigmaLimit)

        alignmentConfidenceMin = try get(.alignmentConfidenceMin, d.alignmentConfidenceMin)

        blurWindowSamples = try get(.blurWindowSamples, d.blurWindowSamples)
        blurMinSamples    = try get(.blurMinSamples, d.blurMinSamples)

        nominalSampleRate     = try get(.nominalSampleRate, d.nominalSampleRate)
        displayDecimationRate = try get(.displayDecimationRate, d.displayDecimationRate)
        writerRingCapacity    = try get(.writerRingCapacity, d.writerRingCapacity)
        fsyncInterval         = try get(.fsyncInterval, d.fsyncInterval)
        syncFlashFrames       = try get(.syncFlashFrames, d.syncFlashFrames)
        baroDynamicPressureK  = try get(.baroDynamicPressureK, d.baroDynamicPressureK)
        gyroFullScale         = try get(.gyroFullScale, d.gyroFullScale)
        accelFullScale        = try get(.accelFullScale, d.accelFullScale)

    }
}
