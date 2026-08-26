# Tasks — Motorcycle Wheelie Telemetry, v1.0

Ordered so that **every milestone ends in something you can use**: M1 is a logger
you ride with, M3 is a live angle you can check against video, M5 gives you
scored runs, M6 is the coaching product, M7–M8 are the visual layer over an
already-working pipeline. Nothing here is a refactor milestone.

Implements `requirements.md` and `design.md` in this directory. `docs/ui-spec.md`
governs the view layer; UI tasks cite its sections rather than restating them.

Legend: `[R…]` = requirement, `[D §…]` = design section, `[UI §…]` = ui-spec
section. Every task's **Done when** is a command to run or a number to read.

Checkbox states:
- `[ ]` not started
- `[x]` done, every acceptance criterion met
- `[~]` **staged** — logic implemented and unit-tested, but at least one
  acceptance criterion is owed and is named inline. Used on branch
  `staging/core-pipeline`, where the estimation pipeline is being built ahead of
  the iOS app: criteria needing an iPhone (microsecond budgets, on-device
  sigma), a recorded ride (video agreement), or measured bench noise cannot be
  met yet. A `[~]` task is NOT done and must not be read as device-verified.

---

## M0 — Scaffold ✅ COMPLETE

Committed: package, CI, `Sample`-stream types, `Config`, `Stage`,
`ValidityGate`, `AxisElevation`, `LogFile`, `SyntheticSource`, `motolog`
skeleton, 8 passing tests.

---

## M1 — Raw logger, recording modes, and the first filmed ride

The milestone that turns opinion into data. Ships a phone you can strap to the
bike and a file you can argue with.

### 1A — Groundwork (blocks everything after it)

- [x] **T1.1 Rename `Measurement` → `Sample`.** `[R1.4–R1.6] [D §3.1]`
  Rename the file to `Sample.swift`; update the enum, `MeasurementSource.next()`,
  `LogFile.encode(_:)`, `LogFile.read(contentsOf:)`, `SyntheticSource`,
  `ReplaySource.init(measurements:)` → `init(samples:)`, and
  `Sources/motolog/main.swift`. Keep the `MeasurementSource` protocol name.
  Do this before any app code exists, so nothing ever imports both `Sample` and
  Foundation's `Measurement<Unit>`.
  **Done when** `swift build && swift test` pass and
  `grep -rn "enum Measurement" Sources/` returns nothing.

- [x] **T1.2 Freeze the wire format against the rename.** `[R1.5]`
  Commit a pre-rename log as `Fixtures/pre-rename-session.ndjson` (generate it
  before landing T1.1), then add a test decoding it after the rename.
  **Done when** the fixture decodes with `formatVersion == 1` and
  `swift run motolog replay Fixtures/pre-rename-session.ndjson` exits 0.

- [x] **T1.3 Write `Conventions.swift`.** `[R…C7] [D §2.1]`
  The canonical frame/sign statement as a doc comment plus executable constants
  (`worldUp`, `bikeForward`, `bikeLeft`, `restSpecificForce`). Every later sign
  question is settled by reading this file.
  **Done when** it compiles and `AxisElevationTests` still pass unchanged.

- [x] **T1.4 Correct `SyntheticSource`'s frame.** `[D §2.2]` ⚠️ blocks M3
  Two sign changes: `rotationRate: Vector3(0, -rate, 0)`, and
  `fx = -(longitudinal * cos(pitch) + g * sin(pitch))`,
  `fz = -g * cos(pitch) + longitudinal * sin(pitch)`.
  **Done when** the guard test T1.5 passes and
  `testAccelerometerAloneIsBadlyWrongDuringTheEvent` still passes (it is
  sign-symmetric, so it must be unaffected — if it breaks, the fix is wrong).

- [x] **T1.5 Convention-guard test.** `[D §2.2, §20]` ⚠️ blocks M3
  Integrate the generator's own gyro stream from identity through
  `Quaternion.exp`, read pitch with `AxisElevation.pitch`, compare against
  `truePitch(at:)` on a bias-free, vibration-free scenario. This is the test
  whose absence let the defect exist.
  **Done when** max error < 0.1° over the whole scenario, and the test **fails**
  if either sign in T1.4 is reverted (verify by reverting once).

- [x] **T1.6 `Config` version 2.** `[R1.9] [D §17]`
  All 32 rows of the design's field table, `version = 2`, `eventExitPitch` → 5°,
  plus `eventEntryDwell`/`eventExitDwell`. Decoding a `version: 1` header
  supplies v2 defaults for absent fields.
  **Done when** a round-trip test passes, T1.2's v1 fixture still decodes, and
  `Config()` encodes with every new key present.

- [x] **T1.7 Numeric primitives.** `[D §5]`
  `Matrix3` (multiply, transpose, adjugate inverse, `skew`), `Matrix6`,
  `Symmetric6` (symmetrise, Cholesky, `solve`). No Accelerate.
  **Done when** tests cover: `skew(v) * w == v.cross(w)`;
  `M * M.inverted()! ≈ I` to 1e-12; Cholesky of a known SPD matrix reproduces it
  under `LLᵀ`; `solve` matches an explicitly-inverted small case to 1e-10;
  `cholesky()` returns nil for a non-PD matrix.

- [x] **T1.8 Purity test.** `[R1.1] [D §20]`
  Grep test over `Sources/MotoTelemetryCore/` only, failing on any of
  CoreMotion / CoreLocation / UIKit / SwiftUI / AVFoundation / Accelerate.
  **Done when** it passes, and fails if you temporarily add `import UIKit`.

- [x] **T1.9 Streaming log reader.** `[R4.2] [D §15.3]`
  Add `LogFile.stream(url:)` (line-by-line, bounded memory) alongside the
  existing whole-file `read(contentsOf:)`, which stays for CLI and tests.
  **Done when** streaming a 180 000-line generated log peaks under 20 MB RSS and
  yields the same samples as `read(contentsOf:)`.

- [x] **T1.10 `Package.swift` platforms.** `[D §1]`
  `platforms: [.macOS(.v14), .iOS(.v18)]`.
  **Done when** `swift build` passes on the Mac.

### 1B — The iOS app target

- [ ] **T1.11 Create the app in Xcode.** `[R…engineering constraints]`
  File ▸ New ▸ Project ▸ iOS App named `MotoTelemetryApp` inside this repo;
  File ▸ Add Package Dependencies ▸ Add Local pointing at the repo root; add
  `MotoTelemetryCore` to the app target. Adopt the `[UI §13]` file tree plus the
  additions in `[D §3.2]`.
  **Done when** the app builds and launches on an iPhone 16 and a `#if canImport`
  check confirms `MotoTelemetryCore` is linked.

- [ ] **T1.12 Info.plist and permissions.** `[R19.1, R19.2]`
  `UIBackgroundModes = [audio, location]`; usage strings for motion and location
  stating why. **No** microphone usage string requested at launch — it is
  requested lazily by T1.20.
  **Done when** a cold launch prompts for motion and location only, and the app
  keeps running with the screen off for 5 minutes.

- [ ] **T1.13 `MotionService`.** `[R2.1, R2.3] [D §16.2]`
  Raw gyro + raw accelerometer at `1/100`, and `deviceMotion(using:
  .xArbitraryZVertical)` alongside. Pair raw channels by nearest timestamp within
  half a sample period; emit an unpaired sample zero-filled **and** counted, never
  dropped or interpolated. Set `saturated` from `Config.gyroFullScale` /
  `accelFullScale` with a 1% margin.
  **Done when** a 60 s capture reports ≥99% pairing and the unpaired counter
  matches the integrity report.

- [ ] **T1.14 `SpeedService`.** `[R2.5] [D §16.2]`
  `CLLocationManager` → `Sample.gnss`, recording both `fixTime` and
  `arrivalTime`.
  **Done when** a 5-minute outdoor capture shows a non-zero median
  `arrivalTime − fixTime` (expect 100–400 ms) — if it is zero you are stamping
  both from the same clock read, which is the bug this task exists to prevent.

- [ ] **T1.15 Barometer + thermal channels.** `[R2.1, R2.6]`
  `CMAltimeter` → `Sample.baro`; `ProcessInfo.thermalStateDidChangeNotification`
  → timestamped log records.
  **Done when** a session's thermal timeline is reconstructable from the log
  alone, verified by `motolog verify`.

- [ ] **T1.16 `SessionWriter`.** `[R2.2, R2.10, R4.1, R4.2] [D §15.2]`
  SPSC ring buffer (`writerRingCapacity` 8192, **overwrite forbidden**, drop
  counter), batched `O_APPEND` writes, `fsync` every 1.0 s, atomic manifest via
  temp + `rename(2)`.
  **Done when** a 30-minute session reports mean sensor-callback-to-enqueue
  latency < 1 ms, max < 5 ms, and drop count 0.

- [ ] **T1.17 No-filter guarantee test.** `[R2.2]`
  Feed a known synthetic stream through the real writer, decode the file, assert
  equality sample-for-sample.
  **Done when** the test passes and would fail if any smoothing were introduced.

- [ ] **T1.18 `SessionRecovery`.** `[R4.2, R4.3] [D §15.3]`
  On launch, repair any session whose manifest lacks `complete: true`: drop a
  trailing newline-less line, recompute sizes/checksums, mark `recovered`.
  **Done when** force-quitting mid-recording loses ≤1 s, the session opens in the
  app, `motolog replay` exits 0 on it, and a unit test truncating a fixture
  mid-line loses only the partial line.

- [ ] **T1.19 `IntegrityReport` + `motolog verify`.** `[R4.4, R4.5, R4.6] [D §15.4]`
  Per-channel achieved vs nominal rate, gap count and max gap, saturation count,
  thermal timeline, GNSS fix count and median latency, late-fix discards, writer
  drops, sync-flash timestamp, battery delta. Flag `lowConfidence` per R4.5.
  **Done when** `motolog verify <session>` prints the report and exits non-zero
  for a deliberately-degraded fixture.

- [ ] **T1.20 Recording modes.** `[R3.1–R3.6] [D §16.4]`
  `RecordingModeView` selecting ride / bench / vibration, written into the
  manifest. `ride` and `bench` never instantiate `VibrationRecorder`;
  `vibration` requests microphone permission lazily and records `audio.caf` plus
  the ≥3 s-per-500-rpm-band prompts.
  **Done when** all three modes produce sessions that `motolog replay` accepts,
  and no microphone prompt ever appears in ride or bench mode.

- [ ] **T1.21 Visual sync flash.** `[R2.13]`
  Full-screen white for `Config.syncFlashFrames` at ride start, timestamp logged.
  **Done when** the logged timestamp is within 20 ms of the actual screen change,
  measured once against a 120 fps reference recording.

- [ ] **T1.22 In-ride marker.** `[R2.14]`
  Large on-screen target and hardware volume-button press → timestamped marker
  record. Markers are labels only, never boundaries.
  **Done when** markers appear in the log and `motolog replay` lists them.

- [ ] **T1.23 Export.** `[R2.11]`
  Share sheet + Files visibility for a whole session directory.
  **Done when** a session lands on the Mac intact and replays there.

- [ ] **T1.24 Rate and background acceptance run.** `[R2.9, R19.1]`
  **Done when** a 30-minute screen-off backgrounded ride session shows achieved
  gyro count ≥99% of nominal and largest gap < 50 ms.

- [ ] **T1.25 Battery + thermal measurement.** `[R19.6, R19.7]`
  **Done when** the 30-minute session reports ≤25% battery consumption and the
  figure appears in the integrity report.

- [ ] **T1.26 THE FIRST FILMED RIDE.** `[R…§7 definition of done]`
  Side-on tripod, full frame, sync flash visible at start, ride mode, mount as
  isolated as you can make it. Then a bench session (3–4 h static, T1.27) and one
  vibration sweep per bike.
  **Done when** you hold three sessions — ride, bench, vibration — that all pass
  `motolog verify`, plus video with a visible flash. Trim a few seconds around one
  event into `Fixtures/`; full sessions go in the gitignored `Rides/`.

- [ ] **T1.27 Bench-mode soak.** `[R3.3]`
  **Done when** a 3-hour static session completes with achieved rate ≥99% and
  peak thermal state no worse than `.fair`.

**M1 is done when** you own a real ride log you can replay on your desk, and the
app can honestly say what is wrong with any session it recorded.

---

## M2 — Offline analysis: replay, FFT, Allan

Turns M1's files into the numbers that parameterise M3. No device needed.

- [ ] **T2.1 Full `motolog replay`.** `[R20.1, R20.2, R20.3] [D §18]`
  Run the whole pipeline; print session summary, per-event metrics, cue timeline.
  `--config <file>` override printing both header version and override;
  `--stages out.ndjson` dumping per-sample stage output; `--cues`; `--json`.
  **Done when** replaying the M1 ride prints a summary and `--stages` output lets
  you attribute a wrong reading to the first stage that went wrong.

- [ ] **T2.2 `motolog fft`.** `[R3.5, R20.4, R14.4] [D §18]`
  Accelerate-based. Per held RPM band: dominant audio firing frequency (the
  unaliased truth), the IMU's aliased image
  `|f_true − round(f_true/f_s)·f_s|`, and the gate-open baseline shift as the
  phantom-tilt offset. Emit the `VibrationProfile`.
  **Done when** the vibration sweep produces a profile that names at least one
  RPM band and its aliased image, and marks bands whose tilt offset exceeds 1°.

- [~] **T2.3 `motolog allan`.** STAGED — the overlapping-ADEV maths is implemented
  and tested: ARW recovered within 10%, log-log slope -0.5 +/-0.05 over 7 octaves,
  bias instability to order of magnitude (wide by nature from synthetic data).
  OWED: the `motolog allan` subcommand wiring, and real bench data for precision. `[R20.5]`
  Overlapping Allan deviation from the bench session: ARW off the −1/2 slope at
  τ = 1 s, bias instability off the flat minimum ÷ 0.664, formatted as the
  `Config` fields they replace.
  **Done when** it prints `gyroNoiseDensity`, `gyroBiasInstability`,
  `accelNoiseDensity` ready to paste, and the τ-domain curve shows the expected
  −1/2 slope over at least a decade.

- [ ] **T2.4 Replace the placeholder noise constants.** `[R…C2] [D §17]`
  Paste T2.3's measured values into `Config`.
  **Done when** the committed defaults are measured, not assumed, and the commit
  message records which bench session produced them.

- [ ] **T2.5 `motolog synth` flags + `motolog parity`.** `[R20.6, R20.7]`
  Scenario flags for reproducing a regression from the shell; one fixture runner
  shared by XCTest and the CLI.
  **Done when** `motolog parity Fixtures/` exits 0 and CI runs it.

**M2 is done when** the filter's parameters come from your bike and your phone,
and you can re-score any past ride against new tuning without riding.

---

## M3 — Live estimator (ESKF)

First milestone that produces an angle. Blocked on T1.4/T1.5.

- [~] **T3.1 `BiasEstimator` + `CalibrationStatus`.** STAGED — synthetic-noise
  tests pass (bias recovered to 1e-4 rad/s, sigma ~2e-5 rad/s, all failure paths
  covered). OWED: the sigma < 0.01 deg/s number and the revving-capture failure
  must be measured on the real phone. `[R6.1–R6.9] [D §6]`
  Welford over gate-open samples, restart on closure reporting
  `ValidityGate.Reason`, σ = sample σ/√n, fail on `biasSigmaLimit` naming the
  axis, exclude saturated samples, age → σ_b projection with `thermalBiasNoiseScale`.
  **Done when** a 10 s stationary zeroing yields per-axis σ < 0.01 °/s on the real
  phone, and a deliberately-revving capture **fails** with a vibration reason.

- [x] **T3.2 `AlignmentSolver` + `MountAlignment`.** `[R7.1–R7.5] [D §7]`
  Two-gesture closed form; reject below 0.25 g pull or above 5° residual.
  **Done when** `Scenario.mountRotation` is added to the generator and the solver
  recovers axes reproducing `truePitch` within 0.5° for an arbitrary mount
  rotation.

- [x] **T3.3 `AttitudeESKF` propagation.** `[R8.1] [D §8.1, §8.2]`
  6-state error filter, body-frame attitude error, Joseph-form updates,
  symmetrise every step, renormalise the quaternion every sample, `dt` clamped
  with dropouts recorded not hidden.
  **Done when** with zero measurement updates and a known constant bias the
  filter's drift matches analytic gyro integration to 1e-9, and `P` stays
  symmetric positive-definite over 180 000 steps.

- [x] **T3.4 Gravity measurement with graded inflation.** DESIGN CORRECTED —
  inflation cannot reject a systematic error, so out-of-band/rotating now SKIP
  rather than inflate. See AttitudeESKF.updateWithGravity. `[R8.2] [D §8.3]`
  `H = [skew(f̂_B) 0]`; κ ∈ {1, 100, 10 000}; skip entirely on saturation.
  **Done when** a synthetic run shows no covariance step at gate transitions
  (compare against a hard on/off branch to see the difference you avoided).

- [x] **T3.5 GNSS-aided pitch measurement.** `[R8.3] [D §8.4]`
  `z = −f_x − a_gnss·cosθ̂`, `h = g·sinθ`,
  `H = [−g·ê_zᵀ·R(q̂)·skew(x̂_B) 0]`. Suppress during events and within
  `gnssAidingEventMargin`, and when `speedAccuracy > 0.5 m/s`.
  **Done when** on a synthetic run-up with 0.5 °/s injected bias, enabling this
  measurement reduces bias error at event onset by ≥5× versus gravity-only, and
  disabling it does not change in-event behaviour.

- [x] **T3.6 Delayed-state GNSS application.** `[R8.3] [D §8.5]`
  2.0 s ring of `(time, q̂, b̂, P, ω̂)`; apply at the bracketing state, re-propagate
  forward; discard and count fixes older than the window.
  **Done when** injecting a synthetic 250 ms fix latency changes the estimate by
  <0.1° versus a zero-latency run, and the naive apply-at-present path is
  measurably worse (record the number).

- [x] **T3.7 `GradeBaseline`.** `[R8.8] [D §8.6]`
  τ = 25 s low-pass over gate-open pitch, **frozen while the gate is closed**.
  **Done when** `Scenario.roadGrade = ±4°` yields reported wheelie angle within
  2° of truth, and a 10 s hold is not absorbed into its own reference.

- [~] **T3.8 `Pipeline` composition + `PipelineOutput`.** STAGED — composed and
  building; the byte-identical determinism test lands with T3.9. `[R1.3] [D §4]`
  Stage order per design; output only on `.imu`.
  **Done when** a determinism test running one fixture twice produces
  byte-identical encoded output.

- [ ] **T3.9 Accuracy matrix, live half.** `[R8.7, R21.2]`
  peak {30,45,70}° × bias {0.05,0.3,0.5} °/s × grade {0,±4}° × vibration
  {0, 83 Hz} × GNSS {on,off}.
  **Done when** every cell holds live error ≤2° for the whole event.

- [ ] **T3.10 Aliasing disclosure, not accuracy.** `[R14.1–R14.3, R21.3] [D §14]`
  `QualityMonitor` one-pole high-pass RMS vs `highFreqRMSThreshold`; the 100 Hz
  vibration cell asserts the run is **flagged**, never that the angle is right.
  **Done when** the 100 Hz scenario sets `highVibration` and the test would fail
  if the flag were dropped — and there is no test anywhere asserting accuracy
  through an aliased channel.

- [ ] **T3.11 On-device budget.** `[R8.10]`
  **Done when** measured estimator wall time per sample < 200 µs on an iPhone 16
  at 100 Hz. If not, apply the planned fallback (propagate `P` at 50 Hz,
  integrate `q̂` at 100 Hz) and record the measured before/after.

- [ ] **T3.12 Validate against the M1 video.** `[R…§7]`
  Replay the filmed ride, align by the sync flash, compare peak angle against
  frame-by-frame protractor measurement.
  **Done when** live peak agrees within 3° and the disagreement is explained
  (bias age, vibration flag, or genuine filter error) rather than shrugged at.

**M3 is done when** you can read a live angle on the phone during a wheelie and
defend it against your own video.

---

## M4 — Post-ride smoother (RTS)

The leaderboard number.

- [ ] **T4.1 Forward-pass storage.** `[D §9.1, §9.2]`
  Store `q̂ₖ|ₖ`, `b̂ₖ|ₖ`, `Pₖ|ₖ`, `Pₖ₊₁|ₖ`, `ω̂ₖ` — 52 doubles/sample.
  **Done when** measured footprint is within 10% of 416 B/sample.

- [ ] **T4.2 Windowed backward pass.** `[R9.1, R9.2] [D §9.1, §9.2]`
  Per event over `[onset − 10 s, end + 10 s]`; `Cₖ` via `Symmetric6.solve`, never
  an explicit inverse; smoothed correction applied to the stored nominal by
  quaternion composition. Require `smootherMinAnchorSamples` gate-open samples
  after the event or mark `smoothingUnavailable`.
  **Done when** peak memory for a 30 s window is ≤1.5 MB and a session with no
  post-event gate-open samples is marked rather than smoothed against nothing.

- [ ] **T4.3 Accuracy matrix, smoothed half.** `[R9.3, R21.2]`
  **Done when** every cell of T3.9's matrix holds smoothed error ≤0.5° and peak
  error ≤0.5°.

- [ ] **T4.4 Idempotence and dual numbers.** `[R9.4, R9.5]`
  Store `liveMaxAngle` and `smoothedMaxAngle` with σ; re-smoothing an unchanged
  session with unchanged `Config` is byte-identical.
  **Done when** both tests pass and the run record carries both values.

- [ ] **T4.5 Off-main execution and budget.** `[R9.6]`
  **Done when** smoothing a 30-minute session completes in <30 s on an iPhone 16
  with progress reported and the main actor never blocked.

- [ ] **T4.6 Degradation paths.** `[R9.7] [D §5, §19]`
  Cholesky failure → `estimatorDegraded`, gyro-only with inflated σ, never a
  silent fallback.
  **Done when** a deliberately ill-conditioned fixture produces the flag and a
  usable, honestly-labelled result.

**M4 is done when** the number you would put on a leaderboard is sub-degree on
synthetic truth and labelled with its own uncertainty.

---

## M5 — Segmentation and scoring

- [x] **T5.1 `EventSegmenter`.** `[R10.1–R10.3, R10.5, R10.7] [D §10]`
  4-state machine (idle/arming/active/disarming), interpolated boundaries,
  `eventMinDuration` discard with a debug bypass.
  **Done when** unit tests cover: dwell not met → no onset; jitter across the
  exit threshold does not end an event; a 0.3 s blip is discarded; boundaries land
  between samples.

- [x] **T5.2 Confidence signals.** `[R10.4] [D §10]`
  `eventEntryPitchRate` as confidence, not a gate; GNSS/IMU longitudinal
  divergence upgrades confidence and never vetoes.
  **Done when** a slow deliberate lift still registers as an event, marked
  `.weak`.

- [x] **T5.3 `RunScorer`.** Review addition: `holdWindowResolved` reports when the
  hold window could not be located and a middle-of-event heuristic was substituted,
  so an unmeasurable consistency number cannot compete for a personal best. `[R11.1–R11.4] [D §11.1]`
  All metrics, hold window from pitch-rate zero crossings with
  `holdRateEpsilon`, `distance` nil below `distanceMinFixes`, uncertainty carried
  per metric.
  **Done when** `angleStdDev` on a synthetic perfect hold is <0.1° and on a
  deliberately wobbly hold is >2° — i.e. it measures steadiness, not the ramp.

- [~] **T5.4 Session summary.** STAGED — SessionSummary implemented and tested.
  OWED: `motolog replay` printing it for the M1 ride (needs the CLI task + a ride). `[R11.3]`
  Event count, cumulative hold time, best per metric.
  **Done when** `motolog replay` prints it for the M1 ride.

- [ ] **T5.5 Atomic run persistence + run store.** `[R10.8, R19.3, R19.4] [D §15.1]`
  `RunRecord` with `SessionSpan`, 30 Hz decimated display series, intervals,
  snapshot, flags. Atomic temp + rename.
  **Done when** a crash injected during persistence leaves either no run or a
  complete run, never a partial one.

- [ ] **T5.6 On-demand raw hydration.** `[R19.4] [D §15.3]`
  Hydrate an event's raw span from the session log via `LogFile.stream`.
  **Done when** hydrating one event out of a 30-minute log completes in <300 ms
  on an iPhone 16.

- [ ] **T5.7 App/CLI parity.** `[R10.6, R11.6, R20.7]`
  **Done when** `motolog parity` shows identical event counts, boundaries within
  1 ms, and every scalar metric within 1e-9 — in CI.

**M5 is done when** a ride produces a list of scored runs you did not have to
find by hand.

---

## M6 — Target band and predictive audio cue

The coaching product. This is the first milestone a rider would pay for.

- [x] **T6.1 `IntervalDetector`.** `[R12.2, R12.3] [UI §9.6] [D §11.2]`
  Interpolated boundaries → **merge** ≤0.10 s gaps → **then** drop <0.15 s
  fragments. Order matters.
  **Done when** ui-spec §17 fixtures 5, 6, 7 pass, and a filter-then-merge
  implementation demonstrably fails the jitter case (record it once).

- [x] **T6.2 Targets and snapshots.** `[R12.1, R12.4, R12.5] [UI §5.1, §5.2]`
  `RiderPreferences` in display units, `TargetSnapshot` in SI captured per run;
  intervals computed once at finalisation against the snapshot.
  **Done when** changing current preferences does not alter any stored run's
  bands or intervals.

- [~] **T6.3 `CueEngine`.** STAGED — decision logic complete and tested with no
  audio hardware. OWED: `motolog replay --cues` printing the timeline (CLI task). `[R13.2–R13.4, R13.7] [D §12]`
  `timeToThreshold` on the band's upper bound, lead = `timeToThresholdWarn` +
  latency, `urgency = 1 − ttt/L`, `.loopOut` preempts `.approach`,
  `cueReleaseTime` hysteresis.
  **Done when** no cue fires for a 3 °/s approach; a cue fires ≥0.35 s before
  threshold for a 60 °/s approach; and `motolog replay --cues` prints the
  timeline with no audio hardware present.

- [ ] **T6.4 `CueAudioRenderer`.** `[R13.5, R13.8] [D §16.3]`
  `AVAudioSourceNode` generating tones procedurally, `.playback` +
  `.mixWithOthers`, lock-free atomic `CueState` read on the render thread, no
  allocation. Distinct timbre and envelope for `.loopOut`.
  **Done when** the tone keeps sounding with the screen off and the app
  backgrounded, over the rider's own music, with no audio glitches during disk
  writes.

- [ ] **T6.5 Route latency.** `[R13.6] [D §16.3]`
  Classify wired / HFP / A2DP from the route, read `outputLatency` +
  `ioBufferDuration`, feed back into the lead constant, warn on A2DP.
  **Done when** measured end-to-end sample-timestamp-to-tone latency is <120 ms
  on wired or HFP, measured on the bench with an external recorder.

- [~] **T6.6 Per-event band score.** STAGED — computed and tested. OWED: appearing
  in `motolog replay` output (CLI task). `[R12.6]`
  **Done when** time-in-band appears per event in `motolog replay` and in the run
  record.

- [ ] **T6.7 Ride it.** `[R13.1]`
  **Done when** you can practise a target band with the screen off, phone in the
  mount, and never look at it — and the post-ride run list matches what your ears
  told you during the ride.

**M6 is done when** the product coaches you without a screen.

---

## M7 — Live Wheelie screen

Visual layer over a pipeline that already works. `docs/ui-spec.md` §7 is the
specification; do not simplify it.

- [ ] **T7.1 Design system.** `[UI §4]`
  `AppColors`, `AppTypography`, `AppSpacing` — all 4.1 semantic tokens, 4.2
  translucent tokens, 4.3 type roles with tabular numerals. No yellow/orange/red.
  **Done when** a token audit shows no raw hex outside `AppColors`.

- [ ] **T7.2 `VerticalTelemetryMeter`.** `[UI §7.3]`
  Fill from zero to cursor only, unfilled track above, gradient clipped to the
  filled portion, target band, crisp cursor line + marker, ease-out with no
  overshoot. Angle fixed 0–90°; speed mirrored with external labels right.
  **Done when** ui-spec §16.1's meter criteria all check, verified by snapshot
  tests at 0%, 42%, and 100%.

- [ ] **T7.3 `LiveWheelieViewModel`.** `[R15.3, R15.4] [UI §7.2, §12]`
  `@MainActor`, fed at ≤30 Hz, display smoothing α 0.20–0.35 that never reaches
  the stored run, speed unavailable rather than 0 when location is denied.
  **Done when** a location-denied run shows unavailable and the stored run's
  values match estimator output exactly, not the smoothed display values.

- [ ] **T7.4 `CalibrationOverlay`.** `[R6.10, R15.2] [UI §7.4]`
  Whole-screen dim with `surfaceOverlay`, em-dash values, unfilled tracks,
  **exactly one** spinner, `CALIBRATING`, and the amended instruction
  `Hold the bike still with the engine idling`. No header spinner, no green dot
  until success, VoiceOver announcement on begin and complete.
  **Done when** ui-spec §16.1's two calibration criteria check against the new
  sentence, in a UI test.

- [ ] **T7.5 Amend `docs/ui-spec.md`.** `[R6.10]`
  Replace the old sentence in §7.2's state-matrix row, §7.4's instruction, and
  §7.7's `CalibrationOverlay(message:)` sketch. Change nothing else.
  **Done when** `grep -n "straight line at a constant speed" docs/ui-spec.md`
  returns nothing.

- [ ] **T7.6 Bottom live metrics.** `[UI §7.3]`
  Exactly ANGLE / WHEELIE TIME / SPEED, left-to-right, with current-attempt
  maxima and no history statistics.
  **Done when** the order and the absence of lifetime stats both check.

- [ ] **T7.7 `TargetRangeEditor` + scale selector.** `[R12.1] [UI §7.5]`
  Dual-handle slider, numeric fields, units, Reset/Apply, inline validation per
  ui-spec §5.2, disabled during an active attempt with the non-blocking
  `Finish the current run to change targets.`
  **Done when** invalid ranges disable Apply and the controls are inert mid-attempt.

- [ ] **T7.8 Mount-alignment setup screen.** `[R6.11] [D §3.2]`
  `Features/Setup/BikeProfileSetupView` hosting the two gestures — explicitly
  **not** in the Live overlay.
  **Done when** alignment can be captured and re-captured from bike-profile
  setup, and the Live overlay never asks for a hard pull.

**M7 is done when** the Live screen meets every ui-spec §16.1 checkbox.

---

## M8 — Past Runs and Run Details

- [ ] **T8.1 `RunMapper`.** `[R11.5] [D §13]`
  The field-by-field bridge: SI/radians/monotonic → ui-spec `WheelieRun` in
  degrees/km-h/wall-clock, `RunExtras` sidecar for the extended metrics,
  `maxAngle` from smoothed when present with the UI stating which.
  **Done when** a round-trip test maps a `RunRecord` to a `WheelieRun` and back
  within display precision, and the ui-spec types are unmodified.

- [ ] **T8.2 `PastRunsView` + row.** `[R16.1] [UI §8.2, §8.3]`
  76–84 pt fully-tappable compact rows, timestamp primary + relative time,
  shared TIME/ANGLE/SPEED column headings, optional LATEST/LONGEST badges, no
  `#12` numbering.
  **Done when** ui-spec §16.2's row criteria check.

- [x] **T8.3 `RelativeMetricColorScale`.** OKLCH implemented from scratch (sRGB ->
  linear -> OKLab -> OKLCh) since the core may not import a platform colour library. `[R16.2] [UI §8.4]`
  Per-field independent normalisation; anchors from the date scope **before**
  row-level metric filters; anchors unmoved by sorting or filtering; all-equal ⇒
  t = 1; the four stops, OKLCH-interpolated with linear-RGB fallback; no yellow.
  **Done when** unit tests cover the all-equal case and prove anchors do not move
  under sort or filter, and ui-spec §8.5's worked example reproduces exactly.

- [ ] **T8.4 Sort/filter behaviour and persistence.** `[UI §8.2, §16.2]`
  **Done when** first tap sorts descending, repeat toggles, one primary key, and
  state survives return from Run Details.

- [ ] **T8.5 Flagged-run presentation.** `[R16.3]`
  `lowConfidence` / `aliasingSuspect` / `recovered` / `smoothingUnavailable`
  visibly marked and excluded from personal-best anchors.
  **Done when** a flagged run cannot be the bright-green personal best.

- [ ] **T8.6 Empty / loading / error states.** `[UI §8.6]`
  **Done when** skeleton rows carry no fake values and filtered-empty offers
  Clear filters.

- [~] **T8.7 `RunDetailsView` hero + charts.** PARTIAL — the LTTB downsampler is
  done and tested (10k -> <=300, first/last preserved, beats naive decimation on
  extrema). The SwiftUI charts themselves are blocked on Xcode. `[R17.1, R17.2] [UI §9.3, §9.4]`
  Three-region hero; two stacked charts on one x-domain; recorded target bands
  behind traces with right-edge labels; separate bright-green maximum markers for
  angle and speed; ≤300 rendered points via LTTB or min/max buckets.
  **Done when** ui-spec §16.3's chart criteria check and the 10 000-sample
  fixture (ui-spec §17 case 9) renders and scrubs smoothly.

- [ ] **T8.8 `SharedChartScrubber`.** `[R17.2] [UI §9.4]`
  One `selectedTime` across both charts, time bubble, interpolated values,
  clamped domain, selection persists until cleared. Interpolate from hydrated raw
  (T5.6), degrading to the decimated series with a reduced-fidelity label when the
  raw log is gone.
  **Done when** both behaviours are exercised by tests, including the
  raw-deleted path.

- [ ] **T8.9 Insight strip.** `[UI §9.5]`
  Exactly ANGLE IN RANGE / AVG SPEED / SPEED IN RANGE. No `Peak At`.
  **Done when** the criterion checks.

- [ ] **T8.10 `RangeIntervalTimeline`.** `[R17.1] [UI §9.6]`
  Exactly one baseline; `LIFT 0.0s` and `DOWN {duration}s`; every interval drawn;
  angle and speed on the same line with screen/additive blending; rounded caps;
  tap hit-testing with expanded radius; an overlap offers a chooser and never
  silently picks; selected bubble `METRIC · RANGE n OF N` with start → end and
  duration; tap-again dismiss; tap-empty clear; popup kept above the tab bar.
  **Done when** every ui-spec §16.3 timeline criterion checks, including the
  overlap case, using ui-spec §17 fixtures 5 and 7.

- [ ] **T8.11 Navigation and state ownership.** `[UI §6, §14]`
  **Done when** returning from details preserves scroll, filters, and sort.

**M8 is done when** the Run Details screen explains a wheelie you rode without
you having to remember it.

---

## M9 — Bike profiles, local leaderboard, progression

- [ ] **T9.1 `BikeProfileStore`.** `[R18.1, R18.2]`
  Create/name/edit/delete; each profile owns alignment, vibration profile, and
  calibration history; exactly one active; switching marks calibration `stale`
  and prompts a re-zero.
  **Done when** switching bikes forces a re-zero and the previous bike's
  alignment survives untouched.

- [ ] **T9.2 Personal bests per profile.** `[R18.3]`
  Max smoothed angle, longest duration, longest time in band, best consistency —
  excluding runs flagged by R4.5, R14.4, R14.5.
  **Done when** a `lowConfidence` run never becomes a personal best, verified by
  a test.

- [ ] **T9.3 Progression graphs.** `[R18.4]`
  Per-metric history scoped to the active profile.
  **Done when** the graph reads from the same filtered set as T9.2.

- [ ] **T9.4 No-network assertion.** `[R18.5]`
  **Done when** a test/inspection confirms no URLSession use and no network
  entitlement in the app target.

**M9 is done when** your bests are per-bike and trustworthy.

---

## M10 — Sharing, disclosure, accessibility, polish

- [ ] **T10.1 Share a scored event.** `[R17.5] [UI §9.7]`
  Still image with overlay stats including whether the number is smoothed;
  platform share sheet with explicit confirmation; nothing auto-rendered or
  auto-shared.
  **Done when** a share requires a deliberate confirm and the image states
  live-vs-smoothed.

- [~] **T10.2 CSV / raw export.** STAGED — exact ui-spec 9.7 header, SI->display
  conversion, locale-independent formatting, missing speed renders empty rather than
  a fabricated 0. OWED: opening it in a spreadsheet, and the iOS share sheet. `[R17.6] [UI §9.7]`
  `elapsed_seconds,angle_degrees,speed_kph`; raw NDJSON as the full-fidelity path.
  **Done when** the CSV opens in a spreadsheet and the NDJSON replays.

- [ ] **T10.3 Storage disclosure and raw deletion.** `[R19.5]`
  Per-session size, total usage, delete-raw-keep-metrics.
  **Done when** deleting raw leaves the run listed, its hero metrics intact, its
  charts labelled reduced-fidelity, and re-smoothing disabled with a reason.

- [ ] **T10.4 Schema versioning and migration.** `[R19.3]`
  `schema.json`, explicit migrations, legacy-snapshot fallback clearly marked.
  **Done when** a synthetic v1 store migrates without data loss and a
  missing-snapshot run is disclosed as legacy rather than silently using current
  targets.

- [ ] **T10.5 Thermal behaviour.** `[R19.7]`
  At `.serious`, warn and name what is being shed; never silently reduce sensor
  rate; record any iOS-imposed rate reduction.
  **Done when** a thermally-stressed session shows the warning and the integrity
  report attributes the rate loss.

- [ ] **T10.6 Accessibility.** `[UI §10, §16]`
  VoiceOver phrasing per ui-spec §10.1 for meters, overlay, rows, scrubber, and
  timeline segments; ranking never conveyed by colour alone; Dynamic Type to
  Accessibility Large with rows expanding and Live values preserved; Reduce
  Motion disabling springs and pulsing; WCAG AA contrast at every interpolation
  stop.
  **Done when** VoiceOver alone conveys every essential telemetry value, and a
  contrast audit passes at all four colour stops.

- [ ] **T10.7 Fixtures and test completeness.** `[R21.4–R21.7] [UI §17]`
  All ten ui-spec §17 fixtures; recorded fixtures for one-event, truncated,
  saturated, and low-rate sessions; snapshot tests for meter fill and cursor; UI
  tests for both calibration states.
  **Done when** `swift test` is green with no device and the fixture list is
  complete.

- [ ] **T10.8 CI completeness.** `[R21.1, R21.8]`
  **Done when** `.github/workflows/ci.yml` runs build, test, and
  `motolog parity` on every push and pull request, with no network access needed.

- [ ] **T10.9 Definition of done sweep.** `[R…§7]`
  Walk requirements §7: all §4 criteria (excluding withdrawn R5), all ui-spec §16
  boxes, ui-spec §18, the R21 matrix green, and the filmed-ride agreement within
  2° using the T1.21 sync flash.
  **Done when** each line is checked off with the command or measurement that
  proved it.

**M10 is done when** v1.0 is shippable and every claim it makes about its own
accuracy is one you have measured.

---

## Cross-milestone rules

- **Never filter before writing.** Any change touching `SessionWriter` re-runs
  T1.17. `[R2.2]`
- **Never add a magic number.** New constants go in `Config` and bump
  `version`. `[R1.8, R1.9]`
- **Never import a platform framework into the core.** T1.8 is the guard. `[R1.1]`
- **Never assert accuracy through an aliased channel.** Disclosure is the
  correct assertion. `[R21.3]`
- **No third-party dependencies.** `[R1.2]`
- **Every accuracy claim cites the command that produced it.** A number without a
  reproduction is a guess.
