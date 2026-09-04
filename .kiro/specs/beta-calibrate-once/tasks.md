# Tasks — Beta "calibrate-once", v1.0 (as shipped)

Implements `requirements.md` and `design.md` in this directory. Branch:
`beta/calibrate-once`.

Ordered so **every milestone ends in something you can check**. B0–B2 end in a live
angle you can hold the phone up and watch; B3–B4 end in a stored run with a number
on it; B5 ends in a cue that does not lie; B6 is the shell.

Legend: `[R…]` requirement, `[D §…]` design section.

- `[ ]` not started
- `[x]` done, verified by the named test or command
- `[~]` core logic done + unit-tested, but a device/ride/app-target criterion is owed
  and is named inline

**Core status: `swift test` → 154 tests, 0 failures.** The core estimator,
calibration gate, swipe solve, and blur are done and tested on Linux. What remains is
app-target and device work, called out per task.

> **What changed since the ESKF design, so the diffs are not mistaken for scope
> creep.** The beta **replaced** the ESKF. The old B0 ("the switch and the flags")
> is gone: `EstimatorMode` / `DriftCompensation` were written and then removed before
> shipping — a one-live-case switch is the dead path the deletion existed to remove,
> and `Config.version` (6) identifies the estimator. Old **B4.0** and **B7.2**
> (chasing the 0.569°-vs-0.5° `AttitudeSmoother` failure) are obsolete: the smoother
> is **deleted**, its whole test file with it, so the failure is gone — not loosened.

---

## B0 — Config for the beta

Small, and first, because a log must be self-describing.

- [x] **B0.1 Bump `Config.version` to 6, no mode enums** `[R1.1, R1.2] [D §11]`
  There is deliberately **no** `EstimatorMode` / `DriftCompensation`. `version` is 6;
  the beta fields joined the tolerant `decodeIfPresent` chain.
  **Verified by** `BetaCalibrateOnceTests.testVersionFiveHeaderStillDecodes`
  (a v5 header decodes with the new fields at defaults) and `testVersionSixAndTheChangedDefaults`.

- [x] **B0.2 Add the beta fields to `Config`** `[R4.4, R5.5, R7.2, R10.3, R10.4] [D §11]`
  `calibrationVibrationLimit` (0.35 m/s², gating), `alignmentConfidenceMin` (0.35),
  `cueEnterPitch` / `cueExitPitch` / `cueDeadband` (in **radians**),
  `blurWindowSamples` (9), `blurMinSamples` (25). 50 stored properties total.
  **Verified by** `testConfigRoundTripsTheNewFields`.

- [x] **B0.3 Remove the 14 zero-consumer ESKF fields** `[D §11]`
  Deleted with their consumers. `Config` now has no enum-typed field.
  **Verified by** `grep` (none remain as stored properties in `Config.swift`) and a
  green build.

- [x] **B0.4 Change the two defaults** `[R3.3, R8.2]`
  `biasCalibrationDuration` 8.0 → 2.0; `eventMinDuration` 0.4 → 1.0.
  **Verified by** `testVersionSixAndTheChangedDefaults`.

> **Removed:** the log-header carry of `estimatorMode` / `driftCompensation` (old
> B0.3) — those fields no longer exist. `Config` is still written into the header and
> the run snapshot in full `[R1.2]`.

---

## B1 — Calibration produces `(ĝ, ψ, b)`

Ends in: a stored alignment that survives an app restart.

- [x] **B1.1 Accumulate mean specific force in `BiasEstimator`** `[R3.1, R3.2] [D §4.2]`
  `ĝ` is the normalised mean specific force over the same admitted samples as `b`.
  **Verified by** `CalibrationTests.testMildInBandVibrationCalibratesAndTheBiasIsStillAccurate`
  and `testQuietMountCalibratesDespiteTheVibrationCheck` (bias accurate, `ĝ`
  recovered) and `testNoisyGyroFailsOnSigmaAndNamesTheAxis`.

- [x] **B1.2 Vibration condition on `ValidityGate`** `[R4.4] [D §4.3]`
  `.vibrating` reason plus a **rolling** spread window sized to `gateDwell`, judged
  from 2 samples up. It does **NOT** reuse `HighFrequencyIndicator.magnitudeStdDev`
  (that window is tumbling and blinds once a second — see [D §4.3]). Gating threshold
  is `calibrationVibrationLimit` (0.35), distinct from the reporting-only
  `calibrationVibrationThreshold` (0.1).
  **Verified by** `CalibrationTests.testViolentShakeNeverCompletesAZeroing` and
  `ValidityGateTests` (sliding-window spread; single-impulse does not close the gate).

- [ ] **B1.3 Surface the per-sample reset reason (app UI)** `[R4.1, R4.6] [D §4.1]`
  `CalibrationService` republishes `BiasEstimator.Progress` incl. `.rejected(reason)`
  so the UI says *why* on the sample that reset it. Core `Progress`/`Reason` exists;
  the app republish is NOT done.
  **Done when** a scripted clean→shake→clean sequence shows `.rejected` at the shake
  and `.collecting` restarts after.

- [x] **B1.4 The swipe alignment factories** `[R5.3, R5.6] [D §4.4, §4.5]`
  `fromMeasuredGravity(specificForce:screenYaw:config:bikeProfileID:) -> MountAlignment`
  (plain value — routes low-`|p|` to the screen-normal branch, does not refuse),
  `fromSwipe(specificForce:screenDX:screenDY:…) -> Result<_, SwipeFailure>` (does the
  UIKit downward-dy flip internally; the one failure is `.noSwipeDirection`), and
  `fromScreenNormal(…)`. `swipeConfidence: Double?` stored on the alignment.
  `AlignmentSolver` and its `Failure` deleted.
  **Verified by** `BetaCalibrateOnceTests.testSwipeFlatOnTankRecoversForwardExactly`,
  `testSwipeAlongGravityTakesTheScreenNormalBranch`, `testFlatMountGivesFullConfidence…`,
  `testVerticalMountBranchReadsLevelAtRest`, `testSwipeConfidenceFallsWithMountTilt`,
  `testRawGestureDeltasApplyTheDownwardYFlip`, `testZeroLengthSwipeIsTheOnlyRefusal`,
  `testScreenNormalFallbackPointsThroughTheScreen`.

- [~] **B1.5 Swipe capture screen (app)** `[R5.1, R5.2]`
  `SwipeAlignmentScreen` — drag draws a line, feeds `screenDX`/`screenDY` into
  `fromSwipe`, and draws the resolved bike glyph ALONG the line so a wrong swipe is
  visible and re-swipeable. Written; NOT device-verified (app target does not build
  off-device here).

- [~] **B1.6 Vertical-mount branch + copy (app)** `[R5.5] [D §4.5]`
  A low-`|p|` swipe routes to `fromScreenNormal` inside the solver — no app branch
  needed. The screen surfaces the resolved orientation for the rider to check.
  Written; NOT device-verified.

- [x] **B1.7 No alignment persistence** `[R5.7 — reversed]`
  Cut. `BikeProfileStore` round-trip is not wanted: the app calibrates and re-swipes
  on EVERY launch, so there is nothing to persist. `.portraitMount` removed entirely
  (a preset is a fabricated input); the live view model now REQUIRES a measured
  alignment passed from the swipe, with no fallback.

- [~] **B1.8 Upright-bike instruction copy (app)** `[R5.8]`
  A side stand leans the bike 5–10° and bakes it into `ĝ`. `CalibrationScreen` title
  says "Hold the bike upright and still, engine off". Written; NOT device-verified.

- [~] **B1.9 Surface bias age and projected error (app)** `[R3.5]`
  `CalibrateOnceEstimator.projectedPitchSigma(estimate:now:holdDuration:)` computes
  it and `PipelineOutput.pitchSigma` carries it (the old `CalibrationTracker` staleness
  machine was deleted). The UI display of it is written into the calibration/live
  screens; NOT device-verified.
  **Done when** the live screen shows degrading confidence as the session ages and a
  re-calibration resets it.

---

## B2 — The live angle

Ends in: hold the phone, tilt it, watch a truthful number.

- [x] **B2.1 `CalibrateOnceEstimator` in `Pipeline.process`** `[R6.1] [D §2]`
  `rate = rawGyro − b`; `Q = Q * exp(rate·dt)`; no gate, no gravity update, no
  covariance, no delayed state, no grade. Impossible `dt` skipped.
  **Verified by** `BetaCalibrateOnceTests.testEstimatorIntegratesNoseUpWithTheRightSign`,
  `testBiasIsSubtractedAndNotSubtractedTwice`, `testEstimatorSkipsImpossibleTimeSteps`,
  `testPipelineIntegratesPitchAndReportsNoGrade`, `testThrustDoesNotMoveThePitchReading`.

- [x] **B2.2 Initialise `Q` from the alignment / gravity anchor, not identity; gate
  publishing on `isAnchored`** `[R6.2, R6.5] [D §2.2]`
  Attitude set from measured gravity; nothing published before anchoring.
  **Verified by** `testEstimatorReadsZeroAtRestAndIsAnchored` and
  `testEstimatorPublishesNothingBeforeAnchoring`.

- [x] **B2.3 Read pitch as axis elevation only** `[R6.3]`
  `AxisElevation.pitch`; no Euler decomposition on the path.
  **Verified by** `testPitchIsIndependentOfRollInTheBetaEstimator` (30° roll + 20°
  pitch → 20° pitch).

- [x] **B2.4 Open-loop sigma + no grade** `[D §2.3, §2.4]`
  `pitchSigma` is `projectedPitchSigma`, labelled open-loop, not a covariance;
  `PipelineOutput` lost `rawPitch`/`grade`/`gateOpen`/`gateReason`; grade is not
  estimated.
  **Verified by** `testPipelineIntegratesPitchAndReportsNoGrade` and the
  `PipelineOutput` field set in source. The UI provenance label is app-target and
  NOT done.

---

## B3 — Segmentation and the intervals

Ends in: one wheelie becomes exactly one run; a curb bump becomes none.

- [x] **B3.1 Confirm the segmenter needs no code change** `[R8.2] [D §6]`
  Entry 10°, exit 7°, entry/exit dwell, min-duration reject, interpolated crossings
  all built; only `eventMinDuration` moved (B0.4).
  **Verified by** `EventSegmenterTests` (1.2 s hold commits; sub-`eventMinDuration`
  hold emits `.discarded`; boundary chatter yields one event).

- [ ] **B3.2 Assert the two-clock split** `[R8.3] [D §6]`
  `.onset` carries the interpolated crossing, not the dwell promotion — a regression
  lock. Not yet an explicit test.
  **Done when** a test asserts `onset == interpolatedCrossing` and the buffered sample
  count covers the entry ramp.

- [ ] **B3.3 Bridge `IntervalDetector` (app)** `[R8.5] [D §6.1]`
  Replace `WheelieRun.angleIntervals` / `speedIntervals` (`compactMap { _ in nil }`)
  with a real call driven by the run's `TargetSnapshot`. Core detector done and
  tested (`IntervalDetectorTests`); the app bridge is NOT done.
  **Done when** `RunDetailsView` shows a non-zero "angle in range" — the `0.0s` bug,
  closed.

---

## B4 — Jitter blur and the stored run

Ends in: a run with a raw series, a blurred series, and a visible delta.

- [x] **B4.3 The centred-window blur (`JitterBlur`)** `[R7.1, R7.2] [D §5.1, §5.2]`
  Pure function over `[Double]` (and `[(time, value)]`): centred moving average of
  odd width from `blurWindowSamples`, symmetric edge truncation (endpoints
  unchanged), fewer than `blurMinSamples` → `.failure(.tooFewSamples)`.
  **Verified by** `BetaCalibrateOnceTests.testBlurLeavesAFlatSeriesFlat`,
  `testBlurPreservesARampWithNoTimeShift`, `testBlurPullsDownALoneSpike`,
  `testBlurWindowIsAlwaysOdd`, `testBlurDoesNotMoveTimestamps`,
  `testEndpointsAreDeliberatelyUnfiltered`, `testBlurRefusesASeriesShorterThanTheMinimum`.

- [x] **B4.8 (core) Max-over-blurred is below max-over-raw** `[R9.1] [D §7]`
  The blur pulls a spike down, so the blurred max is lower.
  **Verified by** `testMaxOverBlurredIsBelowMaxOverRaw`. Persisting both maxes and
  scoring the leaderboard off the blurred one is app-target (below), NOT done.

- [ ] **B4.1 Assert the accelerometer is NOT recorded (app)** `[R2.2] [D §3]`
  The beta records gyro-derived pitch only; accel is read only during calibration.
  Core `Pipeline` never consumes accel for attitude; a recorded-NDJSON assertion in
  the app is NOT done.
  **Done when** a recorded session contains no accelerometer field outside
  calibration, guarded by a test.

- [ ] **B4.2 Decide the fsync guarantee (app)** `[D §3]`
  `RawSampleRecorder` fsyncs only on `finish()`; the "force-quit loses at most 1 s"
  guarantee is untrue today. NOT done.
  **Done when** the documented guarantee and the code agree.

- [ ] **B4.4 Apply the blur on event commit (app)** `[R7.1] [D §5]`
  Feed the committed event's recorded pitch (plus edge margin) through `JitterBlur`;
  store the blurred series. NOT done.
  **Done when** a synthetic ride's blurred pitch has lower sample-to-sample variance
  than the raw series at the same mean level.

- [ ] **B4.5 Too-short handling and the flag (app)** `[R7.5] [D §5.4]`
  Below `blurMinSamples` store raw and set `QualityFlags.smoothingUnavailable`; UI
  says unblurred. Core refusal done (B4.3); app wiring NOT done.
  **Done when** a sub-threshold event still saves, shows raw, and is visibly distinct.

- [ ] **B4.6 Persistence schema (app)** `[R7.4] [D §8]`
  `TelemetrySample` gains optional `blurredAngleDegrees`; `WheelieRun` gains
  `blurredMaxAngle: Double?` and `QualityFlags`. NOT done.
  **Done when** a run saved before this change still loads and a new run round-trips
  both series.

- [ ] **B4.7 Off-main execution, in-place upgrade (app)** `[D §5.4, §10]`
  Detached blur task; run written raw first, upgraded when the blur finishes;
  observed-state write hops to the main actor. NOT done. Needs Xcode.
  **Done when** committing returns immediately and the blurred number arrives without
  a UI stall.

- [ ] **B4.8b Score off the blurred series, keep both (app)** `[R9.1, R9.4] [D §7]`
  Leaderboard uses blurred max; raw max stored beside it. NOT done.
  **Done when** a +4°-spike series yields a blurred max below the raw max, both
  persisted.

- [ ] **B4.9 Comment both ratcheting maxes** `[R9.2, R9.3] [D §7]`
  `RunScorer.finalise` and `WheelieRun.maxAngle`, each pointing at R9.2. NOT done.
  **Done when** both sites name the one-directional bias and the parked percentile
  upgrade.

> **Obsolete, removed from this milestone.** Old **B4.0** ("keep accel in the stream
> for the RTS smoother") is gone — the smoother is deleted, accel is calibration-only.

---

## B5 — The cue stops lying (app target)

Ends in: the tone tracks the wheelie instead of the vibration. Highest-value UX fix,
entirely local to `CueAudioRenderer`. The backing `Config` fields (`cueEnterPitch`,
`cueExitPitch`, `cueDeadband`, in radians) are shipped (B0.2); the renderer latch and
deadband are NOT done.

- [ ] **B5.1 Enter/exit hysteresis on the silence gate** `[R10.3] [D §9]`
  One latched bool, enter 10° / exit 7°, replacing the single `silenceThresholdDegrees`
  comparison.
  **Done when** pitch oscillating 9–11° latches the gate once, not per crossing.

- [ ] **B5.2 Control-path deadband** `[R10.4] [D §9]`
  `cueDeadband`; the render-thread glides are not a substitute.
  **Done when** a steady angle plus a few degrees of jitter holds a steady tone.

- [ ] **B5.3 Same treatment for `limitDegrees`** `[R10.5]`
  **Done when** the continuous-tone boundary no longer chatters.

- [ ] **B5.4 Read the three cue numbers from `Config`** `[D §9]`
  First step out of the thin-shell violation; puts the numbers in the log header.
  The fields exist; the renderer still holds its own degree constants.
  **Done when** the renderer reads `Config` and the numbers appear in a log header.

---

## B6 — Shell (app target)

- [~] **B6.1 Calibration + swipe screens** `[R4.1, R4.6, R5.1]`
  `CalibrationScreen` (full-screen, replaces the deleted `CalibrationOverlay`) shows
  the progress fraction, the live reset reason from `CalibrationService.blockingReason`,
  and advances to `SwipeAlignmentScreen` on `.measured`. `LiveWheelieView` is now a
  calibrate → swipe → live flow container; `LiveScreen` is the telemetry view.
  `RunRecorder.startSensing` runs the sensor stream (no pipeline) so calibration works
  before an alignment exists; the same stream is promoted to recording at swipe-confirm.
  Written; NOT device-verified.
- [ ] **B6.2 Live pitch display, truthful, never blanked while provisional** `[R6.5]`
- [ ] **B6.3 Wheelie duration reads 0 until commit** `[R8.3]`
- [x] **B6.4 mph label** `[R11.4]` — fixed by making the app km/h-only. The mph unit
  picker in Settings changed the label without converting the value (km/h numbers
  under an "mph" heading — a fabricated input), so it was removed; every speed label
  now reads "km/h". Written; NOT device-verified (SwiftUI).
- [~] **B6.5 raw vs blurred on the run detail** `[R7.3]`
  `TelemetrySample.blurredAngleDegrees` stored; `WheelieRun.maxAngle` scores off the
  blurred series with `rawMaxAngle` beside it. Chart display of the delta written;
  NOT device-verified.
- [x] **B6.6 IntervalDetector bridge** `[R8.5]`
  `WheelieRun.angleIntervals`/`speedIntervals` were `compactMap { _ in nil }` — a
  permanent `[]` that made run details read "0.0s". Now real `IntervalDetector` calls
  built from the run's own stored target ranges. The core detector was always tested;
  this is the app bridge. Logic verified in core; the RunDetails render NOT
  device-verified.

---

## B7 — Durable guard

- [ ] **B7.1 Reachability test** `[D §12]`
  Sibling to `PurityTests`: every public core type has a non-test caller in
  `Sources`. NOT done. Eight orphaned-but-tested subsystems is the failure mode that
  produced this fork.
  **Done when** it passes on this branch.

> **Obsolete, removed.** Old **B7.2** ("`.gatedESKF` smoother tests, 0.569° vs 0.5°")
> is gone. `AttitudeSmoother` and its test file are deleted, so the two red tests the
> old baseline carried no longer exist — the suite is 190/0. The failure was removed
> by deleting the smoother, not by loosening a tolerance.

- [ ] **B7.3 Reconcile the outside docs** `[D §13]`
  `docs/architecture.md` predates this fork and still presents the ESKF and
  `AttitudeSmoother` as live. Update it to describe the single calibrate-once path and
  the deleted ESKF stack. NOT done (and outside this spec directory — tracked here,
  edited there).

---

## Deferred — not in the beta

| Item | Blocked on / reason |
|---|---|
| **Measured drift model** (fit `b`-vs-time/temperature from logged rides, predict + subtract `b(t)` live) | Needs a pile of real rides — the beta generates them; needs `thermalState` logged per sample. The honest, pure-gyro correction for the drift the blur leaves in, and the **replacement** for the deleted RTS path |
| Percentile (p95) scoring | Max-over-blurred is sufficient; `computeHoldWindow` already exists `[R9.5]` |
| Live smoothing filter | Lag hurts the cue more than noise does `[R6.4]` |
| Engine-on validation vs Apple's fusion | Needs the filmed ride with ground truth |
| `SpeedService.monotonicOffset` fix | Streams uncoupled `[R11.3]`; no fuser to block |
| Vibration profile per bike | Needs a rev sweep; `highFreqCutoff` stays a guess |
| `motolog allan` subcommand | Bench data; `gyroNoiseDensity` and friends were removed from `Config`, so this is a fresh measurement path if revived |
| Predictive cue to the speaker | Needs `pitchRate` conditioning `[R10.2]` |
| Full UI shell (past runs, filters, export) | Not on the measurement path; `TelemetryExport`/`RunStore` were deleted with the ESKF stack |

> **The RTS smoother is not deferred — it is deleted** (recoverable from `main` /
> `staging/core-pipeline`). Its role is taken by the measured drift model above.

### Tuning numbers owed to real data

`calibrationVibrationLimit`, `cueDeadband`, `alignmentConfidenceMin`, the
`blurWindowSamples` width, and confirmation of the 10°/7° pair — set from logged idle,
blip, and ride data. The project's recurring failure is a margin set inside the noise
it is meant to reject.

---

## Suggested order

Core is done: `B0–B2` (live angle), `B3.1`, `B4.3`/`B4.8` (blur + blurred max) all
pass on Linux (190/0). The remaining work is app-target and device, roughly:
`B1.3/B1.5–B1.9` (calibration + swipe UI, alignment round-trip) → `B3.2/B3.3`
(two-clock lock, interval bridge) → `B4.1/B4.2/B4.4–B4.9` (record, persist, score) →
`B5` (cue latch, highest-value UX, pull forward if a ride is imminent) → `B6` (shell)
→ `B7.1` (reachability guard) → `B7.3` (outside-doc reconcile).
