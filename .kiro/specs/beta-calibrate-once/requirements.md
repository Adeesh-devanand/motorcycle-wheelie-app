# Requirements — Beta "calibrate-once", v1.0 (as shipped)

## 1. What this is

A **deliberate simplification** of the v1.0 gated-ESKF design, shipped and ridden.
It is not a bug-fix pass and not a refactor: the beta **replaced** the ESKF as the
product's estimator. The gated ESKF, the RTS smoother, the delayed-state GNSS
correction and the grade baseline are **deleted from this branch** — they are not
disabled behind a flag, not a selectable second path, and not "still there just in
case." Git holds them on `main` and `staging/core-pipeline`; the shipped app does
not.

> **Reversal from the original spec, recorded because the reversal is the point.**
> The first draft of this document called the beta a second estimator that lives
> *alongside* the ESKF, selected by a `Config` enum. That was implemented — an
> `EstimatorMode` / `DriftCompensation` pair was written — and then **removed before
> shipping**. A switch with exactly one live case is the dead code path this
> project keeps producing; keeping a whole second estimator "in case" is that same
> failure mode with a nicer name. This project's signature defect is a subsystem
> that is complete, tested, and has no caller — documentation once described a
> smoother that nothing invoked. So the beta does not add a second live path; it
> takes the one path out. `Config.version` (now 6) is what a log carries to say
> which estimator produced it. There is no mode flag to read.

**The one-sentence architecture:** the live number is raw gyro integrated from a
once-measured alignment and bias, with the accelerometer never touching the ride;
the recorded number is that same series with its jitter blurred out offline. The
accelerometer is used exactly once — to measure "down" during a stationary
calibration — and is never recorded and never on the live path.

### 1.1 Why this fork exists

The built ESKF pipeline was correct and tested, and the rider could not use it. A
real test ride produced: a cue tone that rose and fell with vibration rather than
with the wheelie, a calibration that could only be completed with the engine off,
and run detail screens reading `0.0s` because `IntervalDetector` is not bridged.
The beta trades the ESKF's live accuracy for a path with fewer moving parts, so
the next ride produces a number the rider can check against video.

### 1.2 What is deliberately given up

| Given up | Consequence | Bought back by |
|---|---|---|
| Live gravity updates (ESKF) | Live angle drifts with thermal bias walk | Nothing live; recorded runs get a jitter blur (R7), not a drift correction |
| Continuous bias re-estimation | `b` is measured once, at calibration temperature | Nothing in the beta. Post-beta: a measured drift model (§13) |
| Automatic re-zero at every stop | Only a user-requested re-calibration re-zeroes | Nothing. Accepted. |
| The accelerometer entirely (except the calibration read) | No absolute reference to correct drift after a wheelie | Nothing. Accepted — accel is unusable on a shaking bike (R2.2) |
| GNSS/IMU time alignment | Speed is display-only, never fused | Nothing. Accepted, see R8.3. |
| Grade correction (`GradeBaseline`) | Riding uphill reads as nose-up | Nothing. The type is deleted; grade is not estimated |

---

## 2. Estimator identity — no mode flag

**R1.1** There is **one** estimator, `CalibrateOnceEstimator`. It is not selectable.
`Config.version` is **6**, and a log's version alone identifies which estimator
produced it.

> **What used to be here, and why it is gone.** The original R1 specified a
> `Config.estimatorMode: EstimatorMode` (`.gatedESKF` / `.calibrateOnce`) and a
> paired `Config.driftCompensation: DriftCompensation` (`.continuous` /
> `.disabled`), validated at `Pipeline` construction. Both enums were written and
> then deleted before shipping. The pairing precondition, the two enum types, and
> every "invalid pair is a programmer error" check are gone. `Config` has **no**
> enum-typed field at all — every member is a scalar, `TimeInterval`, `Int`,
> `[Double]`, or `Double`. Keeping a one-live-case switch would have re-created the
> exact orphan-subsystem defect this fork exists to burn down.

**R1.2** `Config` is written into every log header and every
`RunConfigurationSnapshot`, so a stored run is readable years later without
guessing which tuning produced it. This is unchanged, and it is the whole reason
the config is versioned: a log can never be ambiguous about the parameters behind
a number.

---

## 3. Sensor acquisition

**R2.1** The live estimator consumes **raw gyro only**, from
`CMMotionManager.startGyroUpdates`. It must not consume
`CMDeviceMotion.rotationRate`, `CMDeviceMotion.attitude`, or
`CMDeviceMotion.gravity` on the live path.

> **Rationale.** Apple's `rotationRate` is debiased using the accelerometer and
> `attitude`/`gravity` are fused from it. Every one of those re-imports the thrust
> confound the project exists to reject: a sustained wheelie needs thrust of about
> `g·tan(theta)`, so the accelerometer's error is *correlated with the signal*. Raw
> gyro carries no accelerometer correction, visible or hidden.
> (`CalibrateOnceEstimator` documents this at length.)

**R2.2** The accelerometer is used **only during a calibration session** (R4), to
measure `ĝ`. Outside calibration it is not read and **not recorded**. There is no
accelerometer on the live path (`Pipeline.processIMU` reads `imu.specificForce`
only to hold `lastSpecificForce` for a re-anchor, never to correct attitude) and
no accelerometer in the run log.

> **Rationale, and the decision that settled it.** The raw accelerometer on a
> motorcycle is unusable during an event: rpm surges and chassis vibration peg it,
> and the thrust confound reads "down" as wherever the bike is accelerating. That
> rules it out live. It was briefly brought back for *recording only*, to feed an
> offline RTS smoother — but the smoother needs about 2 s of level, low-vibration
> rolling immediately after the wheel drops to anchor on gravity, and a real rider
> is braking, tilting into a corner, or idling rough with the engine still shaking
> the phone. That clean post-event moment rarely exists, so the smoother's core
> assumption does not hold on a bike. With no offline consumer for it, recording
> the accelerometer buys nothing. It is out entirely, and `AttitudeSmoother` is
> **deleted**, not parked. The recorded number is cleaned by a jitter-only blur
> instead (R7).

**R2.3** There is no gyro/accel **pairing layer** on any shipped path. Nothing on
the live path or in the log needs a co-timed gyro+accel pair; the calibration gate
reads the accelerometer on demand during its window. (In the app target the
continuous pairing machinery is no longer needed by the core; that app-side cleanup
is not part of this core spec.)

**R2.4** `saturated` continues to be computed and carried per sample (≥99 % of
`gyroFullScale`/`accelFullScale`). A clipped rail rectifies AC into DC, which is
one of only two ways vibration can bias an estimate that averaging cannot undo — so
`ValidityGate` closes immediately on a saturated sample and never confirms it away.

---

## 4. Calibration — one session, three products

**R3.1** A calibration session produces exactly three values and stores them
against the bike profile:

| Symbol | Meaning | Source |
|---|---|---|
| `ĝ` | gravity direction in device frame | mean specific force over the clean window |
| `b` | gyro bias vector | mean raw rotation rate over the same window |
| `ψ` | mount yaw about `ĝ` | the swipe gesture (R5) |

**R3.2** `ĝ` and `b` come from the **same** window. The rider is already holding
still for one; the other is free.

**R3.3** `biasCalibrationDuration` is **2.0 s** (reduced from 8.0 s).

> **Arithmetic, so this is a decision and not a hope.** At `gyroNoiseDensity`
> ≈ 0.004 °/s/√Hz and 100 Hz, per-sample sigma is about 0.028 °/s; over 200 samples
> the standard error is about 0.002 °/s, comfortably inside `biasSigmaLimit`
> = 0.05 °/s. 2 s is sufficient against *white* noise. It is thinner against
> low-frequency wander, which is exactly what the 8 s default was guarding. The
> beta accepts that: `biasSigmaLimit` still gates the result, so a bad window fails
> rather than passing quietly.

**R3.4** Calibration runs **only** on explicit request — first run, or the rider
tapping re-calibrate. There is no automatic mid-ride re-calibration and no
re-anchoring at stops. A rider-requested re-calibration re-anchors the attitude
(`Pipeline.requestReanchor` / `anchor(with:)`), because tapping the pill is a
statement that "this pose is level."

**R3.5** A stale calibration must be *surfaced*, not silently used.
`CalibrateOnceEstimator.projectedPitchSigma(estimate:now:holdDuration:)` projects a
pitch sigma from the bias estimate's age and the hold duration. The beta UI must
show that projected error, because with no drift correction the bias goes stale by
roughly 0.1 °/s over 30 min of self-heating, and 0.5 °/s of stale bias is about 5°
over a 10 s hold. This projection is what `PipelineOutput.pitchSigma` carries — an
**open-loop error budget**, not a filter covariance, because there is no filter.

> **Reversed during implementation.** An earlier version tracked staleness through a
> `CalibrationTracker` that aged an estimate against `biasStaleAfter` and moved it to
> a `.stale` state. That whole machine was deleted with the calibrate-every-launch
> decision: the app cannot ride without a fresh calibration, so there is no persisted
> estimate to age. The age-based sigma projection survives directly on the estimator;
> only the staleness *state machine* is gone.

---

## 5. The calibration gate

**R4.1** While a calibration session is active, every incoming sample is evaluated
as it arrives. The rider must see *why* the countdown reset, on the sample that
reset it — not a verdict at the end of the window.

**R4.2** The conditions are the calibration-band gate: specific force within
`calibrationSpecificForceLow`/`High` (0.90–1.10 g), per-axis rotation rate below
`calibrationMaxRotationRate` (5 °/s), and `saturated == false` closing immediately
and never being confirmed away.

> **Why calibration's bands are wider than the estimator's, and why they must be
> split rather than shared.** The estimator keeps ±0.03 g and 3 °/s; calibration
> gets ±0.10 g and 5 °/s. Widening the *shared* value was tried and reverted:
> the same verdict once also gated the ESKF's gravity update, where 0.3 g of thrust
> gives |f| = 1.044 g — inside a ±0.10 g band — and admitting it converges the
> filter on the phantom 16.7° angle this project exists to prevent. For calibration
> the band is only an accelerometer *proxy* for stillness (it never enters the gyro
> mean), so a loose band costs under 0.001 °/s. The split is preserved in
> `Config` as `gateSpecificForceLow/High` + `gateMaxRotationRate` versus
> `calibrationSpecificForceLow/High` + `calibrationMaxRotationRate`. The estimator
> no longer runs a live gate, but the split is still load-bearing — `BiasEstimator`
> builds its own gate from the calibration bands.

**R4.3** A violation shorter than `gateCloseConfirm` (0.06 s) does **not** reset
the window, and a gate closure shorter than `biasGateGracePeriod` (0.25 s)
*pauses* accumulation rather than discarding it.

> **Correction to record.** The behaviour the rider liked — "calibration restarts,
> too much movement" — is real but is **not** a hard reset on any single corrupt
> sample. It is debounced, and that is better: one stray sample cannot defeat a
> window, while sustained engine shake still prevents completion. Duration, not
> amplitude, is the discriminator — engine excitation violates the band for at most
> half a cycle (~30 ms), while acceleration, braking and lean violate it for as
> long as they last, so a 60 ms confirmation window rejects buzz and catches
> anything real.

**R4.4** The gate has a **vibration condition**: it rejects a sample as `.vibrating`
when the **spread** of |specific force| exceeds `calibrationVibrationLimit`
(0.35 m/s²), even while the magnitude is in band.

> **This is load-bearing, and the mechanism corrects the original spec.** The
> specific-force magnitude test is AC-blind: engine buzz swings the force
> *direction* violently while `|f|` averages to almost exactly 1 g, so in-band
> vibration sails through the band test, and a vibration-corrupted `ĝ` becomes the
> permanent reference for every subsequent pitch reading in the session,
> undetectable afterwards.
>
> **Correction to design 4.3 as originally written.** The first design said the
> gate would *reuse* `HighFrequencyIndicator.magnitudeStdDev`. It does **not** —
> and must not. That indicator's window is **tumbling** (1 s): it zeroes its
> accumulator at each rollover, so its spread collapses to 0 once a second and a
> gate leaning on it would go blind on exactly the vibration it is meant to reject.
> `ValidityGate` therefore keeps its **own rolling (sliding) window** of |f|, sized
> to `gateDwell`, and judges from **2 samples up** (a standard deviation is
> undefined below two). A partial window under-reports variance, but under-reporting
> is better than not testing at all, and an idling engine swings |f| from sample to
> sample so even a few samples catch it. A saturated sample clears the window,
> because a clipped magnitude is meaningless and would poison the next half second.

**R4.5** Two vibration numbers exist and are deliberately distinct:
`calibrationVibrationThreshold` (0.1 m/s²) is **reporting-only** — it decides
whether an out-of-band rejection is *described* to the rider as vibration and can
no longer fail a zeroing; `calibrationVibrationLimit` (0.35 m/s²) is the one that
actually **closes the gate**. Naming them apart keeps the measure-versus-enforce
distinction visible.

> **Why reporting-only is not enough on its own, and why gating is still needed.**
> Averaging removes zero-mean vibration from the *gyro* mean — its uncertainty falls
> as `std/√n`, which `biasSigmaLimit` already bounds — so the old vibration *fail*
> was justly demoted to reporting-only. But calibration also produces the *gravity*
> anchor, and |f| is AC-blind, so the gating limit is what defends `ĝ`. Both
> statements are true because they defend different products of the same window.

**R4.6** The gate reports one of `open`, `specificForceOutOfBand`, `rotating`,
`dwellNotMet`, `saturated`, `noData`, or `vibrating`, and the UI maps each to
rider-facing copy.

---

## 6. Mount alignment — the swipe

**R5.1** After the still window completes, the rider swipes once along the chassis
on a blank screen. The swipe supplies the one degree of freedom gravity cannot:
rotation about `ĝ`.

**R5.2** The capture is `ψ = atan2(dy, dx)` in screen coordinates — a single
number, not a 3D vector. Gravity fixes two axes, `ψ` the third; three DOF, two
measurements, no redundancy.

**R5.3** The solve is: `x' = (cos ψ, sin ψ, 0)`; `p = x' − (x'·ĝ)ĝ`;
`forward = p / |p|`; `up = −ĝ`; `left = up × forward`. No trigonometry beyond the
one `atan2`, and no arccos anywhere.

**R5.4** `|p|` is the confidence metric. It equals the sine of the angle between
the swipe and gravity and is stored on the alignment as `swipeConfidence: Double?`
(Optional so that non-swipe capture paths read `nil` rather than a misleading 0,
and so previously-stored alignments still decode).

**R5.5** `|p|` is a **classifier, not a quality threshold**. When it falls near 0
the swipe ran along gravity — a vertical mount whose chassis axis points out through
the screen, not a noisy reading. So the solve does **not** refuse; it **routes** to
the screen-normal branch (R5.6), and the capture screen draws the resolved bike
orientation along the drawn line so a wrong swipe is visible and re-swipeable. The
one thing the arithmetic must not do is divide `p / |p|` at `|p| = 0` (0/0 → NaN,
which would poison every later pitch reading), which is why the branch is explicit.
`fromMeasuredGravity(screenYaw:)` therefore returns a plain `MountAlignment`, not a
`Result`. The only genuine failure is a zero-length tap, surfaced as
`SwipeFailure.noSwipeDirection` by `fromSwipe`.

> **Reversed during implementation.** This originally refused a low-`|p|` swipe with
> `AlignmentSolver.Failure.swipeDegenerate` and kept a two-gesture `AlignmentSolver`
> as a steep-mount fallback. Both were removed: `|p| = 0` is the *signal* for the
> vertical branch, not a failure, so there is no unresolvable mount and nothing for a
> second capture path to do.

**R5.6** Three factories exist on `MountAlignment`, all verified against source:

- `fromMeasuredGravity(specificForce:screenYaw:config:bikeProfileID:) -> MountAlignment`
  — the swipe solve. Returns a plain value, not a `Result`: `|p|` classifies the
  mount and a low `|p|` routes to `fromScreenNormal` rather than failing (R5.5).
- `fromSwipe(specificForce:screenDX:screenDY:config:bikeProfileID:) -> Result<MountAlignment, SwipeFailure>`
  — takes a raw gesture translation and performs the **UIKit/SwiftUI downward-dy
  flip internally, on purpose**: screen dy grows downward while device +Y points up
  the screen, so a bottom-to-top swipe arrives as a *negative* dy. Getting that sign
  wrong reverses forward and reports every wheelie as a stoppie — a silent 180°
  error that **no app-target unit test could catch, because the app target does not
  build off-device**. So the flip lives in core, where it is tested
  (`testRawGestureDeltasApplyTheDownwardYFlip`). It returns `Result` only because a
  zero-length tap has no direction: `SwipeFailure.noSwipeDirection`.
- `fromScreenNormal(specificForce:bikeProfileID:)` — the vertical-mount branch:
  forward points into the screen (device −Z), a disclosed assumption, far better
  than the lateral axis.

`SwipeFailure` has one case, `.noSwipeDirection`. `AlignmentSolver` and its `Failure`
type were deleted.

> **Note.** `releveled(againstMeasuredGravity:)` also remains, for a re-anchor that
> keeps heading and replaces only what gravity observes. It takes no yaw; the
> swipe overload is the beta's one-gesture path.

**R5.7** The result must **round-trip** through `BikeProfileStore`. This is an
**app-target task and is NOT done** — `RunRecorder` / `LiveWheelieViewModel` still
mint a throwaway `UUID()` and hard-code `.portraitMount`, so a measured alignment
would be captured and then discarded.

**R5.8** The bike must be **upright** for the still window. On a side stand the
bike leans 5–10°, and that lean is baked permanently into `ĝ` — a systematic error
in the single reference everything else is measured against. Paddock stand, or the
rider holding it level.

---

## 7. The live read

**R6.1** Per sample: `rate = rawGyro − b`, then `Q = Q * exp(rate·dt)`, with `Q`
initialised from the stored alignment (`CalibrateOnceEstimator.integrate`). A
non-positive or ≥1 s `dt` is skipped rather than integrated, so a replay gap or a
reordered sample cannot rotate the attitude by a fabricated amount.

**R6.2** Pitch is read as **axis elevation**: rotate the bike's forward axis into
the world frame and take `asin(forwardWorld.z)` via
`AxisElevation.pitch(attitude:forwardInBody:)`.

**R6.3** Pitch must **never** be read by decomposing `Q` into Euler angles.

> **Rationale.** Asking "how high is the nose pointing" is independent of how far
> the bike is banked, so roll cannot leak into pitch. An Euler decomposition is
> order-dependent and mixes the two.

**R6.4** The live path applies **no** smoothing filter. Its consumers are the live
display and the cue, and lag is poison to both.

**R6.5** The live pitch is truthful once anchored, and is **published only after
anchoring**: until gravity has tied the world frame down, integrated attitude is
relative to the initial *device* frame, which for a crooked mount differs from the
world by the whole mount rotation. `Pipeline.processIMU` returns `nil` while
`!estimator.isAnchored` rather than emitting a pre-anchor angle — a device log once
showed −89.7° reaching the pipeline 16 ms ahead of the anchor, and nothing
downstream could distinguish that from a real −89.7°.

---

## 8. Recorded runs — jitter blur

**R7.1** On event commit, the recorded pitch series is cleaned by a **zero-phase
(centred-window) blur** (`JitterBlur`) and the stored per-sample series comes from
its output. It is a filter over the pitch numbers only — **no accelerometer** — and
being centred it adds no net lag.

**R7.2** The window is a centred moving average of odd width `2·halfWidth + 1`,
derived from `blurWindowSamples` (9 → halfWidth 4, i.e. 90 ms at 100 Hz). The input
is the recorded live pitch series (already `rate − b` integrated), not raw sensor
data.

> **Edge behaviour, a real limitation to document.** Near the edges the window is
> **truncated symmetrically** rather than padded: at index 1 it averages 3 samples,
> not 9, and at the endpoints the window collapses to a single sample so the first
> and last values are returned **unchanged**. Padding would drag the ends toward a
> repeated value and clamping off-centre would shift them in time — both would show
> up as a fake ramp at the start of every wheelie, exactly where the entry peak
> lives. So the trade is deliberate: less noise reduction at the edges, but no time
> shift and no fabricated ramp. The endpoints are unfiltered on purpose
> (`testEndpointsAreDeliberatelyUnfiltered`).

**R7.3** The blur fixes **jitter only**. It attenuates the fast vibration wiggle so
a lone noise spike is pulled back toward its neighbours. It does **not** and cannot
correct **drift** — the slow lean the gyro accumulates from a stale `b`.

> **Why this is the right call, and what it gives up.** Jitter and drift are two
> different errors. Averaging neighbours removes jitter; it does nothing to drift,
> because every neighbour is drifted by nearly the same amount. Only an *absolute*
> "down" reference can undo drift, and the accelerometer is the only sensor that
> carries one — but it is unusable on a bike during and right after a wheelie
> (R2.2). So the beta removes the jitter the rider actually complained about (the
> flapping tone, the spiky peak) and accepts the drift, which is invisible and
> consistent. The post-beta drift model (§13) is how drift eventually gets
> corrected without ever touching the accelerometer.

**R7.4** Both series are stored: **raw** (the live-estimator pitch) and **blurred**
(the review pitch). The delta is visible in the UI, not hidden behind it. This is
an **app-target persistence task and is NOT done** (see B4.6).

> **Rationale.** The rider observed that saved runs "looked better" than the live
> reading. That was not a filter — it was LTTB decimation plus Catmull-Rom curve
> drawing over the *same* noisy samples: a cosmetic prettying read as a correctness
> improvement. Storing both series is what makes a real jitter reduction checkable
> instead of a matter of trust.

**R7.5** The blur runs off the main actor and must not block event commit; a run
appears immediately with raw values and is upgraded in place when the blur
finishes. The blur cannot "fail" the way the smoother could — with no anchor
precondition. A run with fewer than `blurMinSamples` (25) samples is returned
**unblurred** (`JitterBlur.Unavailable.tooFewSamples`) and stored raw with
`QualityFlags.smoothingUnavailable`, rather than blurred with a window wider than
the data. The core blur is done; the off-main app wiring is an app-target task and
is NOT done.

**R7.6** `AttitudeSmoother` (the RTS smoother) is **deleted**, not merely unused on
this path.

> **Why the smoother was dropped, and why it is gone rather than parked.** RTS
> corrects drift *and* jitter, but only with a post-event gravity anchor: about 2 s
> of level, low-vibration rolling immediately after the wheel drops. A real rider
> brakes, tilts into a corner, or idles rough with the engine shaking the phone, so
> that clean moment rarely exists, and a marginal one would anchor on a
> slightly-wrong "down" and bake that error into the stored number. Its core
> assumption does not hold on a bike. Because there is no longer a `.gatedESKF` mode
> to keep it alive, keeping the type would re-create the orphan-subsystem defect —
> so it was removed. It is recoverable from `main` / `staging/core-pipeline` if the
> ESKF path is ever resurrected.

---

## 9. Event segmentation

**R8.1** A wheelie is: pitch crosses **10°** upward, and the event is kept only if
it lasted at least **1.0 s**. Exit is at **7°** — a distinct, lower threshold.

> **Why the exit threshold differs.** With one shared 10° line, a wheelie hovering
> at the boundary chatters the detector and fragments one real hold into five
> entries. The 3° gap means that once up, you stay up until you clearly come down.
> It is the same defect as the flapping cue tone, one layer higher.

**R8.2** One config value changed: `eventMinDuration` 0.4 → 1.0 s.
`eventEntryPitch` (10°) and `eventExitPitch` (7°) already carry the chosen numbers,
and `EventSegmenter` already implements entry dwell, exit dwell, the
minimum-duration reject as `.discarded(duration:)`, and interpolated crossing
times. Raising the reject threshold rejects more borderline pop-ups at the cost of
discarding genuine-but-very-short lofts, which is the right trade for a leaderboard
that should only show real holds.

**R8.3** **Two clocks, and they are not the same clock.** The sample buffer fills
from the 10° **crossing**; the rider-facing wheelie duration reads 0 until the
1.0 s commit. `EventSegmenter` already reports the interpolated crossing time as the
onset, so the buffer boundary is correct in the code today.

> **Rationale.** If the internal clock started at the commit point instead, the
> first second of every wheelie would be discarded — and the entry ramp is precisely
> where a fast pitch-up can put the real peak. That would under-report every event,
> quietly and always in the same direction.

**R8.4** An event that ends before 1.0 s is discarded entirely, buffer included.

**R8.5** `IntervalDetector` must be **bridged**. `WheelieRun.angleIntervals` /
`speedIntervals` are `samples.compactMap { _ in nil }` — literal placeholders that
always return `[]`, which is why run details permanently read `0.0s`. The core
detector works and is tested; only the app bridge is missing. This is an
**app-target task and is NOT done**.

---

## 10. Scoring, and the ratcheting max

**R9.1** The beta metric is **max over the blurred series**. The percentile upgrade
is parked (§13).

**R9.2** Record the defect plainly, because it exists in **two** layers:

- `RunScorer.finalise` — `if s.pitch > maxAngle { maxAngle = s.pitch }`, surfaced
  as `EventMetrics.liveMaxAngle`.
- `WheelieRun.maxAngle` — `samples.map(\.angleDegrees).max() ?? 0`.

**What a ratcheting max does.** A plain `max()` finds the peak of *angle plus the
single luckiest upward noise spike in the whole hold*. A true 45° peak with one +4°
vibration spike records 49°. The error is **one-directional** — downward noise is
ignored, upward noise is locked in — so a personal best can only ever be
overstated, and longer holds inflate more.

**R9.3** The blur fixes most of it and not all of it, and the residual must be
recorded so it is not mistaken for solved. The blur pulls the spike back toward its
neighbours, so max-over-blurred is a genuine improvement — but it *attenuates*
rather than removes, `max()` still grabs the top of what remains, and it is still
one-directional. Separately, max answers the wrong question: a wheelie that touched
50° for a tenth of a second and held 40° reads 50 by max, ~40 by percentile. That
is a definition choice no filter can make.

**R9.4** Both numbers are stored — raw max and blurred max — and the leaderboard
uses the blurred one. (App-target persistence; NOT done.)

**R9.5** The hold-window machinery for the eventual percentile **already exists**:
`RunScorer.computeHoldWindow` locates the sustained portion via `holdRateEpsilon`
(1 °/s) crossings and reports `holdWindowResolved`. The upgrade is a p95 of
`holdSamples` inside `finalise` — a few lines, not new machinery.

---

## 11. The cue

**R10.1** The cue is **angle-only**: `RunRecorder` drives
`CueAudioRenderer.update(pitchDegrees:)` with the live pitch. Honest and slightly
late, rather than predictive and wrong.

**R10.2** The predictive `CueEngine` (time-to-threshold) stays dead-ended into the
UI badge and does not reach the speaker in the beta. Making it predictive means
conditioning `pitchRate`, the dirtiest signal in the system. Not in the beta.

**R10.3** The silence gate gains **enter/exit hysteresis**: beep on at
`cueEnterPitch` (10°), silence at `cueExitPitch` (7°), matching R8.1. The
thresholds now live in `Config` **in radians** (`cueEnterPitch`, `cueExitPitch`),
not as bare degree constants in the renderer. This is an **app-target latch task**
(`CueAudioRenderer` still holds a single `silenceThresholdDegrees` with no latched
state) and is **NOT done**; the `Config` fields that back it are shipped.

**R10.4** The tone gains a **deadband**: `cueDeadband` (0.5°, in radians in
`Config`), so the tone tracks the wheelie instead of the vibration. The existing
one-pole audio glides are render-thread smoothing and do **not** substitute for a
control-path deadband — they smooth the tone, not the decision. App-target wiring;
NOT done.

**R10.5** The `limitDegrees` continuous-tone boundary in the renderer is also a
single bare comparison and gets the same treatment. App-target; NOT done.

---

## 12. Speed

**R11.1** Speed is Doppler `CLLocation.speed`, rejected when `speedAccuracy < 0`,
lightly smoothed, with no map matching. On the pipeline it is an independent ~1 Hz
display channel: `Pipeline.process` updates `lastSpeed` on a valid GNSS fix and
fuses nothing.

**R11.2** Speed and IMU are **independent async streams**. No coupling, no pairing,
no fusion in the beta — and with the delayed-state buffer deleted there is nothing
to fuse into.

**R11.3** The `SpeedService.monotonicOffset` bug is **recorded and not fixed**. It
computes `arrivalTime − location.timestamp` once and never again; wall-clock can
step under NTP or DST while `systemUptime` marches on. It only bites when GNSS
timing must align with IMU timing — the ESKF's delayed-state correction, which is
deleted. Real bug, correctly ignorable here, must not be forgotten. (App target.)

**R11.4** The `mph` label bug: `RunRecorder` stores `* 3.6` (km/h) and the UI
labels it mph. App-target fix; NOT done.

---

## 13. Explicitly parked

Not oversights. Each is a decision to do it later.

| Parked | Why it is safe to park | What it costs to leave |
|---|---|---|
| **Measured drift model** (fit bias-vs-time/temperature from many logged rides, then predict and subtract `b(t)` live) | Needs a pile of real rides — which the beta is what generates; needs `thermalState` logged per sample | The live angle keeps drifting on long hot holds; this is the honest, pure-gyro correction (no accelerometer) that eventually closes that gap. It is the parked replacement for the deleted RTS path |
| **Percentile scoring** | Max-over-blurred removes most inflation | PBs still overstate slightly, one-directionally (R9.3) |
| **Live smoothing filter** | Lag hurts the cue more than noise does | Live display stays jittery |
| **Engine-on validation test** | Needs the filmed ride | Apple's confound handling stays unmeasured |
| **`monotonicOffset` fix** | Streams are uncoupled (R11.3) | Would block a future GNSS/IMU fusion, which the beta has no fuser for |
| **Vibration profile per bike** | Needs a rev sweep on the real bike | `highFreqCutoff` and the vibration limits stay guesses |
| **`motolog allan`** | Bench data, not a ride | `gyroNoiseDensity` etc. stay placeholder constants |
| **Predictive cue** | Needs `pitchRate` conditioning (R10.2) | The specced differentiator is not in the beta |
| **UI shell beyond calibration + live** | Not on the measurement path | Past-runs and details stay rough |

> **The RTS smoother is NOT in this table.** It is deleted, not parked — see R7.6.
> Its eventual replacement, the measured drift model, is what sits here instead.

### 13.1 Tuning numbers owed to real data

Set from logs, not chosen at a desk: `calibrationVibrationLimit` (R4.4),
`cueDeadband` (R10.4), `alignmentConfidenceMin` (R5.5), the `blurWindowSamples`
width (R7.2), and confirmation of the 10°/7° pair against a filmed ride.

---

## 14. Done when

The beta is done when, in one session on a real bike:

1. Calibration completes only with the engine off, and the reset reason is on
   screen at the moment it resets.
2. A swipe produces an alignment that survives an app restart.
3. The live angle reads about 0° standing still and rises with the front wheel.
4. A wheelie held for more than 1 s appears as exactly one run; a curb bump appears
   as none.
5. That run shows a raw and a blurred angle series, with the blurred number on the
   leaderboard and the delta visible.
6. The cue does not flap at the 10° boundary.
7. The log header states `Config.version = 6`.

**Core status (Linux, `swift test`): 154 tests, 0 failures.** The remaining "done
when" items are app-target and device work (R5.7, R7.4, R8.5, R10.3–R10.5, R11.4).
