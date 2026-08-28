# Live-log audit — fixes applied

Follows `2026-08-28-live-log-audit-HANDOFF.md`, which diagnosed but deliberately fixed
nothing. This is what was changed, and the three places the handoff's own conclusions
turned out to be wrong.

## Corrections to the handoff

**1. The specific-force band could NOT be widened globally.** The handoff (from report 04)
says the +/-0.03 g band is "free" to widen to +/-0.10 g because it is an accelerometer proxy
that never enters the gyro mean. That argument is correct *for calibration* and wrong for
the system, because the same gate verdict also gates the **ESKF gravity update**. At 0.3 g
of forward thrust `|f| = 1.044 g`, which sits inside a +/-0.10 g band — so widening it made
the filter accept sustained acceleration as rest and converge on the phantom angle
`atan(0.3) = 16.7 deg`. `AttitudeESKFTests.testSustainedThrustDoesNotDragTheEstimateToThePhantomAngle`
caught it immediately.

Resolved by splitting the threshold: `calibrationSpecificForceLow/High` (+/-0.10 g) is used
only by `BiasEstimator`'s own gate; `gateSpecificForceLow/High` stays at +/-0.03 g for the
estimator. `gateMaxRotationRate` 3 -> 5 deg/s is shared, since it bounds real rotation for
both consumers.

**2. The branch was NOT green.** The handoff states "129 fast core tests were green". On the
pristine branch `swift test` runs 233 tests with **5 assertion failures across 3 tests**:

| Test | Status |
| --- | --- |
| `GradeBaselinePipelineTests.testReanchorZeroesTheReportedAngleAtAnyTilt` | fixed here — it was reporting a real bug |
| `AttitudeSmootherTests.testHeavyVibrationRemovesTheAnchorAndSmoothingIsRefused` | still failing, diagnosed below |
| `AttitudeSmootherTests.testAccuracyMatrixAcrossPeakAndBias` | still failing, 0.569 deg against a 0.5 deg tolerance |

**3. A re-anchor did not zero the angle — bug 13, found via the failing test above.** Pitch
is the elevation of `forwardInBody`, and the re-anchor path deliberately did not re-derive
the alignment (to avoid re-guessing which tilt is a wheelie). But an old `forward` that is
not perpendicular to the *new* `up` leaves the pose reading its full tilt: a 35 deg pose
still reported 35.0 deg after the re-zero that was supposed to make it 0. The existing code
comment predicted "a small residual"; at 35 deg the residual is the whole angle.

Fixed with `MountAlignment.releveled(againstMeasuredGravity:)`: take `up` from the
measurement, Gram-Schmidt the existing `forward` against it. The heading is preserved (so a
re-anchor still cannot reassign which tilt is a wheelie) and the pose reads exactly 0.

## Fixes, against the handoff's §4 list

| # | Fix | Where |
| --- | --- | --- |
| 1 | Auto-start latch: `canAutoStart` now consults the calibrated state, so a SUCCESS is terminal. Releases on rider request, stale bias (`biasStaleAfter`), or sensor loss. The retry budget is cleared on success | `CalibrationService` |
| 2 | Both flood sources fixed at the caller: the `autostart status` key no longer embeds `estimator == nil` (a value that flipped every sample and defeated the emitter's own transition check); `gate reason` thrash collapsed to a 1 Hz summary carrying per-reason counts + a transition total. The OSLog mirror was also moved *below* the sink's coalescing check — it ran before it, which is why the console measured ~100/s against a coalescer that was working | `CalibrationService`, `DiagnosticLog` |
| 3 | Anchor now requires the gate to be OPEN and the pose to be near-level (`anchorLevelCosine`, ~20 deg). Magnitude alone is orientation-invariant at rest and structurally cannot reject a tilt. The pipeline also publishes **nothing** before an anchor exists — the log had `-89.7 deg` reaching it 16 ms early | `AttitudeESKF`, `Pipeline` |
| 4 | `stop()` clears `pendingGyro`/`pendingAccel`/`latestAttitude`, so a stashed half-sample cannot put the next session into a phase relation pairing never recovers from. Stale opposite-channel stashes are now evicted, so the live-lock cannot persist. `unpairedCount` is per-session | `MotionService` |
| 5 | Re-anchor requires a material bias change (`reanchorBiasDelta`, 0.01 deg/s) or an explicit rider request. Six of the log's seven re-anchors measured the same bias to three decimals and only yanked the angle back to 0 | `RunRecorder`, `CalibrationService` |
| 6 | Stream-discontinuity reset: a gap over 30 nominal intervals (300 ms) restarts accumulation rather than pooling across a dead stream. The `n >= 400` floor was already present | `Calibration` |
| 7 | Thresholds split — see correction 1 | `Config`, `Calibration` |
| 8 | `ServiceGraph` moved to `WheelieTrackerApp` and injected as a plain `let`. `@State private var services = ServiceGraph()` re-ran the initializer on every `RootTabView.init`, eagerly building throwaway graphs whose `SpeedService` GPS side effects had already fired. Also fixes a split-brain where the environment's services were different objects from the recorder's | `WheelieTrackerApp`, `RootTabView` |
| 9 | Watchdog distinguishes "hardware dead" from "our pairing drops everything" using a new raw-callback count. It told the rider to check permissions while 1,839 callbacks were arriving | `RunRecorder`, `MotionService` |
| 10 | Yaw-bias gain zeroed in both update paths. Unobservable from gravity, and the log had it at 5.05 deg/s against a measured 0.111 and still climbing | `AttitudeESKF` |
| 11 | Raw trace capped at 64 MB (~30 min) with a one-shot warning. It defaulted ON with no cap at ~129 MB/hour | `RawSampleRecorder` |
| 12 | Already done — `UIBackgroundModes` is set in both `Info.plist` and the build settings | — |

## Verification

- `swift test --disable-sandbox`: **242 tests, 4 assertion failures across the 2
  pre-existing tests above.** No new failures; the re-anchor test is fixed.
- `AccuracyMatrixTests.testAccuracyMatrix` passes (37 s) — the gate that catches phantom-angle
  regressions. `PurityTests` green.
- 9 regression tests added in `DeviceLogAuditRegressionTests.swift`, every fixture taken from
  numbers the device log actually recorded.
- **The app target is NOT compiled by SwiftPM and cannot be built on Linux.** Its 7 edited
  files were reviewed by reading, against the real core signatures, with locking checked on
  every path. Treat the first Xcode build as the real verification.

## Still open

**`testHeavyVibrationRemovesTheAnchorAndSmoothingIsRefused`** asserts that vibration of 0.5
"keeps the gate shut for the whole window". Measured: the gate is open for **1112**
post-event samples, against 200 required. The premise is false, and it is false *by design* —
v3 added `gateCloseConfirm` (60 ms) precisely so engine buzz cannot close the gate, and 83 Hz
sampled at 100 Hz aliases to 17 Hz (59 ms period), so each violation is ~30 ms and never
confirmed. This test contradicts a deliberate design decision rather than catching a bug.
Deciding whether the vibration path should be reachable at all is a design call, so it was
left alone.

**`testAccuracyMatrixAcrossPeakAndBias`** is 14% over tolerance at peak 70 deg (0.569 vs
0.5), identically before and after this work.

Neither is on the handoff's §4 list.

## Next

A fresh device log is what actually closes this out. Expect: calibration reaching
`calibrated` and **staying** there; no re-anchor without a material bias change; pitch ~0
when the phone is level; every session emitting samples; log volume down roughly an order of
magnitude with the heartbeats intact. The on-disk NDJSON should now be at ~20/s while the
console is at the raw emitter rate — that split was never verified from a real log.
