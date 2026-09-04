# Design — Beta "calibrate-once", v1.0 (as shipped)

Implements `requirements.md` in this directory. Cites the as-built source on branch
`beta/calibrate-once`. Every symbol named here was verified against the source and
against a green `swift test` (154 tests, 0 failures).

---

## 1. The shape

The beta **replaced** the ESKF. There is one live estimator and one offline
cleaner, over one sensor stream. The important property is that **the live number
and the recorded number come from the same estimator**; the recorded one is just
cleaned of jitter afterward. There is no accelerometer anywhere except the one
calibration read.

```
                      MotionService  (raw gyro, 100 Hz)
                                 |
             +-------------------+--------------------+
             |                   |                    |
        PATH A: LIVE        PATH B: RECORD       PATH C: CALIBRATE
        (causal, raw)       (write-only)         (on request only)
             |                   |                    |
     rate = gyro - b        every pitch sample   accel turned ON briefly:
     Q = Q * exp(w dt)      -> NDJSON on disk    ValidityGate (calibration bands)
     pitch = asin(fW.z)                          per-sample dwell + reset
             |                   |                -> g-hat, b, psi
     live display, cue,          |                    |
     EventSegmenter              |               BikeProfileStore
             |                   |
             +-------- event commit --------+
                                            |
                                    PATH D: POST-EVENT
                                    take the recorded pitch series
                                    JitterBlur: centred-window (zero-phase)
                                    jitter out, no net lag, no accel
                                            |
                                    raw series + blurred series
                                    -> WheelieRun -> RunRepository
```

Path A never sees an accelerometer. Path B records gyro-derived pitch only. Path C
turns the accelerometer on for one calibration window and off again. Path D is a
filter over numbers, not sensors.

> **The ESKF path is deleted, not selected against.** The earlier design ran a
> `.gatedESKF` mode alongside this one, chosen by `Config.estimatorMode`, and ran
> the recorded window through `AttitudeSmoother`. All of that — `AttitudeESKF`,
> `AttitudeSmoother`, `DelayedState.swift` (which also held
> `GroundAccelerationEstimator`), `GradeBaseline`, `AllanDeviation`, `RunStore`,
> `TelemetryExport`, the `EstimatorMode` / `DriftCompensation` enums, and five test
> files — was **removed before shipping**. The smoother rebuilds an ESKF internally
> and needs a post-event gravity anchor (≈2 s of level, low-vibration rolling) that
> a real bike rarely supplies, so it was the wrong tool here; and a second live
> estimator kept "just in case" is precisely the orphan-subsystem defect this fork
> exists to burn down. Git holds them on `main` / `staging/core-pipeline`. The beta
> cleans jitter with a plain centred-window blur and accepts drift; §13 records the
> pure-gyro drift model that eventually corrects it.

---

## 2. Path A — the live estimator (`CalibrateOnceEstimator`)

### 2.1 Per-sample

```
rate    = sample.rotationRate - b            // b from calibration, constant
Q       = Q * Quaternion.exp(rotationVector: rate * dt)
pitch   = AxisElevation.pitch(attitude: Q, forwardInBody: alignment.forwardInBody)
```

`dt` comes from consecutive sample times. `integrate(_:)` returns `false` (and
does not rotate) when unanchored, on the first sample (no `dt` yet), or when
`dt <= 0 || dt >= 1.0` — a stream jump from replay or reordering must not
integrate a fabricated angle. `pitchRate` is read straight off the debiased body
rate projected onto the bike's lateral axis, not by differencing successive pitch
values (differencing amplifies exactly the jitter the cue is most sensitive to).

### 2.2 Initialisation and anchoring

`Q` is initialised so that the stored alignment reads zero pitch at rest, from the
measured gravity vector: `Quaternion.rotation(from: f, to: Conventions.worldGravity)`.
It is **not** initialised from identity — device-frame integration from identity is
wrong for any crooked mount.

`isAnchored` is the gate on publishing. Before gravity has fixed the world frame,
integrated attitude is relative to the initial device frame; `CalibrateOnceEstimator`
starts `isAnchored = false` when constructed without a `gravityAnchor` and flips it
true in `anchor(with:)`. `Pipeline.processIMU` returns `nil` while `!isAnchored`
(`testEstimatorPublishesNothingBeforeAnchoring`).

### 2.3 What is absent, deliberately

No `ValidityGate` on the hot path. No gravity update. No covariance. No
delayed-state buffer. No grade baseline. `PipelineOutput.pitchSigma` is **not** a
filter covariance — there is no filter — it is
`CalibrateOnceEstimator.projectedPitchSigma(estimate:now:holdDuration:)`, an
*open-loop* error budget projected from bias age. It is reported in the same field
the ESKF once filled with a real covariance, so the distinction lives in the name
and in the doc comment, or a reader takes one for the other.

### 2.4 No grade, and `PipelineOutput` shrank to match

`GradeBaseline` is deleted, so there is no grade estimate; riding uphill reads as
pitch-up, accepted for the beta. `PipelineOutput` **lost** `rawPitch`, `grade`,
`gateOpen`, and `gateReason` — every field that only made sense with a live gate or
a grade baseline. Its current fields are: `time`, `attitude`, `pitch`, `pitchRate`,
`roll`, `gyroBias`, `pitchSigma`, `speed?`, `vibration`, `flags`. There is no
`rawPitch`/`pitch` distinction any more because there is no smoothing on the live
path — the live number *is* the raw number.

`Pipeline` correspondingly lost `gradeEstimate`, `isDegraded`, and
`lateFixesDiscarded`, and gained `isAnchored` (introspection) and `anchor(with:)` /
`requestReanchor()` (world-frame establishment on calibration complete).

---

## 3. Path B — the recorder

`RawSampleRecorder` writes the stream as motolog-compatible NDJSON. For the beta:

1. **Gyro-derived pitch only, no accelerometer.** Per R2.2 the accelerometer is not
   recorded. The recorded series Path D blurs is the live pitch, a pure-gyro
   quantity. (An earlier design brought accel recording back to feed the RTS
   smoother; with the smoother deleted, so is that recording.)
2. **`fsync` durability.** `RawSampleRecorder` fsyncs on `finish()`; the documented
   "a force-quit loses at most 1 s" guarantee (`Config.fsyncInterval`) is not
   honoured by it today. This is app-target work and is NOT done — either wire an
   interval fsync or correct the document.

---

## 4. Path C — calibration

### 4.1 State machine

```
idle --(user taps calibrate)--> collecting
collecting --(sample fails)--> collecting     [dwell reset, reason surfaced]
collecting --(2.0 s continuous clean)--> awaitingSwipe
awaitingSwipe --(swipe captured, |p| ok)--> complete
awaitingSwipe --(|p| below alignmentConfidenceMin)--> screenNormalFallback --> complete
collecting --(biasAttemptWindow 30 s elapsed)--> failed(.gateNeverOpened)
```

### 4.2 Reuse, not rewrite

`BiasEstimator` is this loop: Welford accumulation of rotation rate behind its own
`ValidityGate` built on the **calibration** bands (`calibrationSpecificForceLow`/
`High` = 0.90/1.10 g, `calibrationMaxRotationRate` = 5 °/s), with the grace-period
pause (`biasGateGracePeriod` 0.25 s), discontinuity reset, `restart()`, and a
`Progress` enum whose collecting payload is what a progress ring needs. It also
accumulates mean specific force to produce `ĝ`. Duration is `biasCalibrationDuration`
= 2.0 s.

The band split is load-bearing and survives even though there is no live gate: the
estimator's tight ±0.03 g / 3 °/s band is what a live ESKF gravity update *would*
need, and it is kept in `Config` (`gateSpecificForceLow/High`, `gateMaxRotationRate`)
distinct from calibration's wider band. See §4.3 of `requirements.md` for the
device evidence on why widening the shared value was tried and reverted.

### 4.3 The vibration wire — corrected from the original design

The original design said the gate would **reuse**
`HighFrequencyIndicator.magnitudeStdDev`. **It does not, and it must not.** That
indicator keeps a **tumbling** window (`windowDuration` ≈ 1 s): it zeroes its
running sums at each rollover, so its spread collapses to 0 once a second and a
gate leaning on it would go blind on exactly the vibration it is meant to reject.

Instead `ValidityGate` keeps its **own rolling (sliding) window** of |specific
force|, a ring buffer sized `max(2, round(gateDwell · nominalSampleRate))`. Its
`rollingMagnitudeStdDev` is `nil` below two samples (a standard deviation is
undefined there — not a claim of quiet) and computed from **2 samples up**. A
saturated sample clears the window, because a clipped magnitude is meaningless and
would poison the next half second.

`bandViolation(mag:r:limit:)` is the single definition of "quasi-static," shared by
the gate's own `evaluate` and by `sampleWithinBand(_:)`. It checks, in order:
magnitude band, per-axis rotation, then — **last, deliberately** — the rolling
spread against `calibrationVibrationLimit` (0.35 m/s²), returning `.vibrating`. The
spread test is last because when both the band and the spread fire, the band is the
bigger problem and the more useful thing to tell the rider.

```swift
if let spread = rollingMagnitudeStdDev, spread > config.calibrationVibrationLimit {
    return .vibrating
}
```

Two vibration numbers, distinct on purpose:

| Field | Value | Role |
|---|---|---|
| `calibrationVibrationThreshold` | 0.1 m/s² | **reporting-only** — whether an out-of-band rejection is *described* as vibration; can no longer fail a zeroing |
| `calibrationVibrationLimit` | 0.35 m/s² | **gating** — the spread ceiling in `bandViolation` that actually returns `.vibrating` |

The reporting-only demotion is right (averaging removes zero-mean vibration from the
*gyro* mean, bounded by `biasSigmaLimit`); the gating limit is also right because
calibration also produces the *gravity* anchor and |f| is AC-blind. They defend
different products of the same window.

### 4.4 The swipe solve

```
x'      = Vector3(cos(psi), sin(psi), 0)
p       = x' - (x' . gHat) * gHat
conf    = p.magnitude                  // == sin(angle between x' and gravity)
forward = p / conf                     // when conf >= alignmentConfidenceMin
up      = -gHat
left    = up.cross(forward)
```

| Mount | `ĝ` | `x'` | `p` | `conf` | Result |
|---|---|---|---|---|---|
| Flat on tank, swipe forward | `(0,0,−1)` | `(0,1,0)` | `(0,1,0)` | 1.0 | exact (`testSwipeFlatOnTankRecoversForwardExactly`) |
| Bars, portrait, swipe along gravity | `(0,−1,0)` | `(0,1,0)` | `(0,0,0)` | 0.0 | refuse → fallback (`testSwipeAlongGravityIsRefusedNotGuessed`) |

`conf` is stored on the alignment as `swipeConfidence: Double?` and is the norm of
a vector the solve already computed, not an extra step.

### 4.5 The alignment factories (as built)

`MountAlignment` carries `forwardInBody`, `upInBody`, `leftInBody`, `residual`,
`peakPullAcceleration`, `capturedAt`, `bikeProfileID`, and the beta's new
`swipeConfidence: Double?`. Four construction paths exist:

```swift
// swipe solve — the beta's one-gesture capture. NOT failable: |p| classifies the
// mount rather than scoring it, so a swipe along gravity ROUTES to the screen
// normal (vertical mount) instead of being refused.
static func fromMeasuredGravity(specificForce:screenYaw:config:bikeProfileID:)
    -> MountAlignment

// raw gesture translation; does the UIKit downward-dy flip INTERNALLY. The only
// genuine failure is a zero-length tap, so this one returns Result.
static func fromSwipe(specificForce:screenDX:screenDY:config:bikeProfileID:)
    -> Result<MountAlignment, SwipeFailure>   // SwipeFailure.noSwipeDirection only

// the vertical-mount branch: forward = into the screen (device -Z)
static func fromScreenNormal(specificForce:bikeProfileID:) -> MountAlignment

// pre-existing: re-level, keep heading, replace only what gravity observes
func releveled(againstMeasuredGravity:) -> MountAlignment
```

`fromSwipe` performs `atan2(-screenDY, screenDX)` internally on purpose: screen dy
grows downward while device +Y points up the screen, so a bottom-to-top swipe
arrives as a *negative* dy. Getting the sign wrong reverses forward and reports
every wheelie as a stoppie — a silent 180° error **no app-target test could catch,
because the app target does not build off-device**. The flip lives in core, where
`testRawGestureDeltasApplyTheDownwardYFlip` covers it.

`|p|` (stored as `swipeConfidence`) is a **classifier, not a quality score**. Near 1
means a flat-ish mount and the drawn line is the chassis axis directly; near 0 means
the swipe ran along gravity — a vertical mount whose chassis axis points out through
the screen — so `fromMeasuredGravity` routes to `fromScreenNormal` rather than
dividing `p / |p|` (which at `|p| = 0` is `0/0`, a NaN that would poison every later
pitch reading). That routing is why the swipe path is not failable: both geometries
resolve. `SwipeFailure` therefore has a single case, `.noSwipeDirection`, for the one
thing that genuinely has no answer — a tap, not a line.

> **Reversed during implementation.** An earlier version refused the degenerate
> swipe with `AlignmentSolver.Failure.swipeDegenerate` and kept the two-gesture
> `AlignmentSolver` (rest + pull) as a fallback for steep mounts. Both were removed:
> `|p| = 0` is not a failure but the exact signal that says "vertical mount, use the
> screen normal", so there is no mount the swipe cannot resolve and nothing for a
> second capture path to catch. `AlignmentSolver`, its `Failure` type, and the
> `alignmentMinPullAccel`/`alignmentMaxResidual` config both deleted.

---

## 5. Path D — the jitter blur (`JitterBlur`)

### 5.1 What it is

A **centred-window, zero-phase blur** over the recorded pitch series. Because the
window is centred, averaging each point against neighbours on both sides cancels the
phase shift one side would introduce, so the blurred curve lines up in time with the
raw one. That is only possible offline, because a centred window at time *t* needs
samples after *t* — which is exactly why the live path (Path A) stays raw.

As built, it is a **centred moving average** of full width `2·halfWidth + 1`
(`windowSamples`), always odd by construction. `halfWidth = max(1, blurWindowSamples/2)`
(so `blurWindowSamples` 9 → halfWidth 4 → 9-wide, 90 ms at 100 Hz). Input: the
recorded per-sample pitch (already `rate − b` integrated). Output: a same-length
`[Double]`. No sensors, no accelerometer, no covariance, no gate — arithmetic over
a list of numbers.

### 5.2 Edge behaviour is a real, documented limitation

Near the edges the window is **truncated symmetrically**, not padded:

```swift
let reach = min(i - lower, upper - i)   // shrink to whichever side is nearer the edge
```

At index 1 the window is 3 wide; at the endpoints `reach == 0`, so the first and
last samples are returned **unchanged** (`testEndpointsAreDeliberatelyUnfiltered`).
Padding with a repeated end value would drag the ends toward it; clamping the window
off-centre would shift them in time — both would show up as a fake ramp at the start
of every wheelie, exactly where the entry peak lives. The trade is deliberate: less
noise reduction at the edges, no time shift, no fabricated ramp. The odd-width
guarantee (`testBlurWindowIsAlwaysOdd`) and the timestamp invariance
(`testBlurDoesNotMoveTimestamps`) are both tested.

### 5.3 What it fixes, and what it cannot

Fixes **jitter** — the fast vibration wiggle — and nothing else. A lone +4° spike is
averaged back toward its neighbours (`testBlurPullsDownALoneSpike`,
`testMaxOverBlurredIsBelowMaxOverRaw`), which is what kills the worst of the
ratcheting-max inflation (§7).

Does **not** fix **drift** — the slow lean from a stale `b`; every neighbour is
drifted by nearly the same amount, so averaging leaves it. Only an absolute "down"
reference removes drift, and the accelerometer is unusable on a shaking bike (R2.2).
Drift is accepted for the beta; §13's pure-gyro drift model is the eventual fix. A
flat input stays flat (`testBlurLeavesAFlatSeriesFlat`); a ramp keeps its slope with
no time shift (`testBlurPreservesARampWithNoTimeShift`).

### 5.4 Failure and execution

The one way it can decline: fewer than `blurMinSamples` (25) samples returns
`.failure(.tooFewSamples(count:required:))` (`testBlurRefusesASeriesShorterThanTheMinimum`),
so a run below the minimum stores raw and sets `QualityFlags.smoothingUnavailable`.
There is no anchor precondition and no other failure mode — this is the "cannot fail
the way the smoother could" property.

The off-main-actor execution, in-place run upgrade, and the observed-state main-actor
hop are **app-target work and NOT done**; the pure core function is done and tested.

### 5.5 `AttitudeSmoother` is deleted

The RTS smoother is gone from this branch — not "not on this path," gone. It rebuilt
an `AttitudeESKF` internally, stored a per-step covariance, and its RTS gain needed
that covariance; its `Input` required `specificForce`, so using it would force
accelerometer recording back on. Its whole advantage was a post-event gravity anchor
that a bike does not reliably supply. With no `.gatedESKF` mode left to keep it
alive, keeping it would re-create the orphan defect, so it was removed.

> **Note on the test baseline.** The 0.569°-vs-0.5° smoother accuracy miss that the
> earlier design tracked (in `AttitudeSmootherTests`) is **gone** — because the
> **smoother is gone**, not because a tolerance was loosened. The whole
> `AttitudeSmootherTests` file was deleted with it. `swift test` is now 154 tests,
> 0 failures. The obsolete tasks that existed only to chase that failure (old B4.0,
> B7.2) are removed from `tasks.md`.

---

## 6. Segmentation

`EventSegmenter` needs no code change beyond config. As built:

- `idle → arming` on `pitch > eventEntryPitch`, recording the **interpolated
  crossing time** immediately.
- `arming → active` after `eventEntryDwell` (0.15 s); emits `.onset` carrying the
  *crossing* time, not the promotion time — so the two-clock split of R8.3 is
  already correct in code, the buffer boundary is the crossing.
- `active → disarming` on `pitch < eventExitPitch`, capturing the interpolated exit
  crossing; `disarming → active` if pitch recovers (jitter guard); confirmed after
  `eventExitDwell` (0.25 s).
- On confirmed exit, `duration < eventMinDuration` emits `.discarded(duration:)`.

One config change: `eventMinDuration` 0.4 → 1.0.

### 6.1 The interval bridge — app-target, NOT done

`IntervalDetector` is complete and tested and has no app caller.
`WheelieRun.angleIntervals` / `speedIntervals` are `samples.compactMap { _ in nil }`,
so they always return `[]` and `RunDetailsView` reads `0.0s`. The bridge is: build a
`[(time, value)]` from the stored series, construct `IntervalDetector` from the run's
`TargetSnapshot` (never current preferences), call `intervals(over:)`. Order inside
the detector is load-bearing and already correct: detect with interpolated crossings,
**merge** within `mergeGap`, *then* filter by `minDuration`.

---

## 7. Scoring

Beta: `max()` over the **blurred** series, with the raw max stored beside it. Both
ratcheting maxes stay in place and both get an explicit comment pointing at R9.2:

- `RunScorer.finalise` → `EventMetrics.liveMaxAngle`
- `WheelieRun.maxAngle` → `samples.map(\.angleDegrees).max() ?? 0`

The percentile upgrade is a p95 over `holdSamples` inside `finalise`. The hold window
already exists (`computeHoldWindow`, `holdRateEpsilon` 1 °/s crossings,
`holdWindowResolved`). Parked, cheap, recorded here so it stays cheap. (The scoring
wiring and both persisted maxes are app-target; NOT done.)

---

## 8. Persistence — a schema change (app-target, NOT done)

The current format cannot store two series. One JSON file per run, an encoded
`WheelieRun` with a single `samples: [TelemetrySample]` (`id`, `elapsed`,
`angleDegrees`, `speedKPH`) and a `RunConfigurationSnapshot`. There is no
raw-versus-blurred distinction.

Minimal change:

```swift
struct TelemetrySample {
    let id: UUID
    let elapsed: TimeInterval
    let angleDegrees: Double            // raw, live estimator
    var blurredAngleDegrees: Double?    // nil until the blur completes or on failure
    let speedKPH: Double
}
```

Optional, so old runs decode unchanged and `nil` means "not blurred" — the same
signal `smoothingUnavailable` carries at the run level. `WheelieRun` gains
`blurredMaxAngle: Double?` and `QualityFlags`. No sigma field: the blur produces no
covariance. A parallel `blurredSamples` array is rejected — two arrays that must stay
index-aligned is a bug waiting to be written.

---

## 9. The cue (app-target latch, NOT done)

Local to `CueAudioRenderer`. Today `silenceThresholdDegrees` is compared once with no
second threshold and no latched state; `limitDegrees` is likewise a bare comparison.
The fix is one latched bool plus two guards:

```swift
private var gateOpen = false            // latched state — the missing piece

func update(pitchDegrees: Double) {
    let clamped = max(0, min(pitchDegrees, pitchCapDegrees))
    gateOpen = gateOpen ? (clamped >= cueExitDegrees)     // 7
                        : (clamped >= cueEnterDegrees)    // 10
    guard gateOpen else { /* silence */ return }
    if abs(clamped - lastToneInput) < cueDeadbandDegrees { return }
    lastToneInput = clamped
    ...
}
```

The three numbers now live in **`Config`, in radians**: `cueEnterPitch` (10°),
`cueExitPitch` (7°), `cueDeadband` (0.5°). The renderer reads degrees, so the bridge
converts; the shipped `Config` fields are the source of truth and appear in the log
header. The renderer's one-pole glides smooth the *tone*, not the *decision*, so they
do not substitute for the deadband. The `Config` fields are done; the renderer latch
and deadband wiring are NOT.

---

## 10. Threading (app-target)

`RunRecorder` is `@Observable ... @unchecked Sendable` and mutates observed state
from consuming Tasks under an `NSLock`. A lock serialises writers; it does not make
an `@Observable` write main-actor-safe for SwiftUI. The beta must not make this
worse: Path D's completion writes into a run *and* into observed state, so that write
must hop to the main actor explicitly. Verification needs Xcode; NOT done.

---

## 11. Config, as it now stands

`Config.version` is **6**. There is **no** enum-typed field — every member is a
scalar, `TimeInterval`, `Int`, `[Double]`, or `Double`. **50 stored properties**
total.

**Removed** since the ESKF design (14 zero-consumer fields, all deleted with their
consumers): `anchorLevelCosine`, `baselineTimeConstant`, `accelLowPassCutoff`,
`gyroNoiseDensity`, `accelNoiseDensity`, `accelNoiseInflation`,
`accelNoiseInflationDynamic`, `accelDynamicThreshold`, `delayedStateWindow`,
`gnssAidingEventMargin`, `gnssMaxSpeedAccuracy`, `smootherWindowMargin`,
`smootherMinAnchorSamples`, `smoothedSigmaLimit`. (`anchorLevelCosine` survives only
as prose in the versioning doc comment describing the v4 history — it is not a stored
property.)

**Added for the beta:**

```swift
var cueEnterPitch:  Double = 10.0 * .pi / 180   // RADIANS
var cueExitPitch:   Double =  7.0 * .pi / 180   // RADIANS
var cueDeadband:    Double =  0.5 * .pi / 180   // RADIANS
var calibrationVibrationLimit: Double = 0.35    // m/s^2, GATING spread ceiling
var alignmentConfidenceMin:    Double = 0.35    // |p| floor before fallback
var blurWindowSamples: Int = 9                  // odd full width, 90 ms @ 100 Hz
var blurMinSamples:    Int = 25                 // below this, store raw
```

> **Correction to the original design's §11.** The first design named the cue
> fields `cueEnterDegrees` / `cueExitDegrees` / `cueDeadbandDegrees` and gave
> `calibrationVibrationLimit` a default of 0.1. Both are wrong against the shipped
> code: the fields are `cueEnterPitch` / `cueExitPitch` / `cueDeadband` and hold
> **radians**, and `calibrationVibrationLimit` is **0.35 m/s²** (0.1 m/s² is the
> separate reporting-only `calibrationVibrationThreshold`). The `EstimatorMode` /
> `DriftCompensation` enums the original §11 added were removed before shipping.

**Changed defaults:** `biasCalibrationDuration` 8.0 → 2.0, `eventMinDuration`
0.4 → 1.0.

Each addition joins the tolerant `decodeIfPresent` chain in `init(from:)`, per the
struct's versioning contract, so an older header still decodes with the new fields at
their defaults (`testVersionFiveHeaderStillDecodes`).

---

## 12. Testing

Everything on the core path is Linux-testable with no phone. Current status:
**154 tests, 0 failures** (`swift test`). The beta-specific coverage lives in
`BetaCalibrateOnceTests`, `CalibrationTests`, and `MountAlignmentTests`:

| Target | Test(s) |
|---|---|
| Version + changed defaults | `testVersionSixAndTheChangedDefaults` |
| Tolerant decode | `testVersionFiveHeaderStillDecodes` |
| New fields round-trip | `testConfigRoundTripsTheNewFields` |
| Live integrator, right sign | `testEstimatorIntegratesNoseUpWithTheRightSign` |
| Bias once, not twice | `testBiasIsSubtractedAndNotSubtractedTwice` |
| Pitch ⟂ roll | `testPitchIsIndependentOfRollInTheBetaEstimator` |
| Anchor gating | `testEstimatorReadsZeroAtRestAndIsAnchored`, `testEstimatorPublishesNothingBeforeAnchoring` |
| Impossible `dt` skipped | `testEstimatorSkipsImpossibleTimeSteps` |
| Pipeline: pitch, no grade | `testPipelineIntegratesPitchAndReportsNoGrade` |
| GNSS speed-only | `testGNSSOnlyUpdatesSpeed` |
| Thrust does not move pitch | `testThrustDoesNotMoveThePitchReading` |
| Blur: flat / ramp / spike | `testBlurLeavesAFlatSeriesFlat`, `testBlurPreservesARampWithNoTimeShift`, `testBlurPullsDownALoneSpike` |
| Blur: odd width, no shift, edges | `testBlurWindowIsAlwaysOdd`, `testBlurDoesNotMoveTimestamps`, `testEndpointsAreDeliberatelyUnfiltered` |
| Blur too short | `testBlurRefusesASeriesShorterThanTheMinimum` |
| Max over blurred < raw | `testMaxOverBlurredIsBelowMaxOverRaw` |
| Swipe solve + refusal + tilt + flip | `testSwipeFlatOnTankRecoversForwardExactly`, `testSwipeAlongGravityIsRefusedNotGuessed`, `testSwipeConfidenceFallsWithMountTilt`, `testRawGestureDeltasApplyTheDownwardYFlip`, `testZeroLengthSwipeIsRefused`, `testScreenNormalFallbackPointsThroughTheScreen` |
| Calibration gate: shake / in-band vibration / sigma | `testViolentShakeNeverCompletesAZeroing`, `testMildInBandVibrationCalibratesAndTheBiasIsStillAccurate`, `testQuietMountCalibratesDespiteTheVibrationCheck`, `testNoisyGyroFailsOnSigmaAndNamesTheAxis` |
| Gate `.vibrating` reason | `ValidityGateTests` (sliding-window spread) |

The durable guard — every public core type has a non-test caller — is the sibling to
`PurityTests` (B7.1, still to add): eight orphaned-but-tested subsystems is the
failure mode that produced this whole fork.

---

## 13. Relationship to the deleted ESKF path

Nothing is *selected against* — the ESKF path is **deleted**. `AttitudeESKF`,
`AttitudeSmoother`, `DelayedState.swift` (incl. `GroundAccelerationEstimator`),
`GradeBaseline`, `AllanDeviation`, `RunStore`, `TelemetryExport`, and five test files
are removed from `beta/calibrate-once`. They remain on `main` /
`staging/core-pipeline` and can be recovered if the ESKF is ever resurrected.

The shipped estimator is the ESKF path with the live correction removed, the
accelerometer demoted to a one-shot calibration instrument, and the offline pass
swapped from drift-correcting RTS to jitter-only blur. The eventual restoration of
drift correction is the pure-gyro measured drift model (§13 of `requirements.md`),
which the beta's logged rides are what make fittable — not the RTS smoother, whose
gravity anchor a bike cannot supply.
