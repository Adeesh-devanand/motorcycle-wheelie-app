# Requirements — Motorcycle Wheelie Telemetry, v1.0

## 1. Introduction

This document specifies the complete v1.0 product: an iPhone application plus the
`MotoTelemetryCore` pipeline that measures motorcycle **wheelie pitch angle**,
coaches the rider through audio in real time, and reviews the ride afterwards.

**What already exists (M0, committed).** A Swift package with two products,
`MotoTelemetryCore` (library, zero platform imports) and `motolog` (macOS CLI).
The library holds:

| File | Provides |
|---|---|
| `Sources/MotoTelemetryCore/Measurement.swift` | `Measurement` enum (`.imu`/`.gnss`/`.baro`/`.wheelSpeed`) and `IMUSample`, `GNSSFix`, `BaroSample`, `WheelSpeedSample` |
| `Sources/MotoTelemetryCore/Math.swift` | `Vector3`, `Quaternion` (scalar-first, body→world, `exp(rotationVector:)`, `rotate(_:)`) |
| `Sources/MotoTelemetryCore/Config.swift` | `Config` — every tunable constant, `version: Int`, `Codable` |
| `Sources/MotoTelemetryCore/Stage.swift` | `Stage` protocol (`mutating func process(_:) -> Output?`) and `MeasurementSource` |
| `Sources/MotoTelemetryCore/ValidityGate.swift` | `ValidityGate: Stage`, `Verdict`, `Reason` |
| `Sources/MotoTelemetryCore/AxisElevation.swift` | `pitch(attitude:forwardInBody:)`, `roll(attitude:forwardInBody:upInBody:)`, `timeToThreshold(current:rate:target:)` |
| `Sources/MotoTelemetryCore/LogFile.swift` | `LogHeader`, `LogFile.encodeHeader/encode/read`, `ReplaySource` |
| `Sources/MotoTelemetryCore/SyntheticSource.swift` | `SyntheticSource`, `Scenario`, `truePitch(at:)`, `truePitchRate(at:)` |
| `Sources/motolog/main.swift` | `motolog synth`, `motolog replay <log.ndjson>` |

**What this spec creates.** The iOS app target, and the pipeline stages that do
not yet exist: bias calibration, mount alignment, the live ESKF estimator, the
post-ride RTS smoother, the event segmenter, the scorer, the in-range interval
detector, the cue engine, the run store, and the CLI analysis tools.

**Relationship to `docs/ui-spec.md`.** That document is the canonical source of
truth for visual design, interaction, state machines, accessibility, and UI
acceptance criteria. This document references it and never restates or
contradicts it. Its §16 acceptance criteria are included verbatim in §8 below and
are part of this spec's definition of done.

One **amendment** to that document is mandated by this spec and is specified
exactly in R6.10: the §7.4 calibrating-overlay instruction copy changes, because
the sentence it currently carries describes a moving bike and bias zeroing
requires a stationary one. That is a copy correction to the canonical document,
not a divergence from it — everything else in §7.4 stands unchanged.

## 2. Conventions

- **Angle** means the elevation of the bike's forward axis above the horizontal
  plane, computed by `AxisElevation.pitch(attitude:forwardInBody:)`. Euler pitch
  is never used anywhere in the product.
- **Core units are SI radians, m/s, m/s², seconds.** Degrees and km/h exist only
  at the display boundary and in this document's prose. `Config` stores radians.
- **Error budget is absolute degrees, never a percentage.** ±2° is the same
  requirement at 20° as at 70°.
- **Time** inside the pipeline is a monotonic clock in seconds
  (`systemUptime` domain on device). Wall clock appears once, in
  `LogHeader.startedAt`.
- **Live** means computed on the bike during the ride. **Smoothed** means
  recomputed after the run by the backward pass. Both numbers are retained.
- Requirement IDs are stable. Acceptance criteria are written to be checked by a
  number, a command, or a log field — not by judgement.

## 3. Fixed constraints (settled; not open for re-litigation)

These are conclusions from completed research. They constrain every requirement
below and must not be re-derived or softened by the design.

- **C1 — The accelerometer is systematically useless during an event**, not
  merely noisy. A sustained wheelie needs thrust ≈ g·tan θ, so the phantom pitch
  is almost perfectly correlated with the true pitch (0.5 g reads as 26.6°). The
  accelerometer may only be trusted when `ValidityGate` says so.
- **C2 — Gyro integration is the measurement.** Drift over a 5–30 s event is
  0.03–0.08°. The whole error budget is the two initial conditions: angle at
  onset and gyro bias at onset. ±0.5 °/s bias → 5° over a 10 s hold;
  ±0.05 °/s → 0.5°. Accuracy is decided during the run-up.
- **C3 — Aliasing is unfixable in software.** All iPhone sensors cap at 100 Hz;
  engine vibration at 30–200 Hz folds into the signal band (a twin at 6000 rpm
  folds to DC). Mechanical isolation is mandatory; the app's job is to *detect
  and disclose* corruption, never to filter it away.
- **C4 — GNSS is 1 Hz**, Doppler-derived speed ≈0.1 m/s, with no raw
  observables exposed by CoreLocation.
- **C5 — Self-heating walks gyro bias ≈0.1 °/s per 30 min**, i.e. ~1° over a
  10 s hold. Bias is a tracked filter state, not a boot-time constant.
- **C6 — Balance point is 45–55°**, geometry- and rider-dependent. No code may
  treat 90° as the balance point. The angle *scale* is still 0–90° per UI spec
  §7.3.
- **C7 — Roll does not corrupt pitch** provided pitch is axis elevation. Roll is
  a separate reported channel.
- **C8 — Dead ends, not to be specified:** camera/ARKit/VIO, magnetometer,
  Apple Watch as a live second IMU, `CMDeviceMotion.attitude` as the event-time
  estimate.

## 4. Requirements

### R1 — One sample stream, one pure pipeline

**Story.** As the developer, I want the identical estimation and scoring code to
run live on the bike, replayed on my Mac, and in a unit test with no device
present, so that tuning a filter constant does not cost me a ride in traffic.

1. `MotoTelemetryCore` contains **no** `import CoreMotion`, `CoreLocation`,
   `UIKit`, `SwiftUI`, `AVFoundation`, or `Accelerate`. Verified by a test that
   greps the target's sources and fails on any match.
2. The package declares **zero** third-party dependencies; `Package.swift`
   `dependencies` stays empty.
3. Every source of measurements conforms to `MeasurementSource`. The estimator,
   segmenter, scorer, and cue engine consume only that protocol and cannot
   distinguish live, replay, and synthetic sources.
4. The core `Measurement` enum is renamed to `Sample` to remove the collision
   with Foundation's `Measurement<Unit>`. Case names (`.imu`, `.gnss`, `.baro`,
   `.wheelSpeed`) and payload types (`IMUSample`, `GNSSFix`, `BaroSample`,
   `WheelSpeedSample`) are unchanged. The rename surface is exactly:
   `Sources/MotoTelemetryCore/Measurement.swift` → `Sample.swift`; the enum and
   its `var time: TimeInterval`; `MeasurementSource.next() -> Sample?`;
   `LogFile.encode(_:)`; `LogFile.read(contentsOf:)`'s return tuple;
   `ReplaySource.init(measurements:)` → `init(samples:)`; `SyntheticSource.next()`;
   and `Sources/motolog/main.swift`. The `MeasurementSource` protocol name is
   **kept** — it names a source of measurements, which does not collide.
5. The rename is source-level only and **must not change the NDJSON wire
   format**: the synthesized `Codable` conformance keys on case names, not on the
   type name. Acceptance: a log file written before the rename decodes without
   modification after it, and `LogHeader.formatVersion` stays 1. Checked by
   keeping a pre-rename fixture in `Fixtures/` and asserting
   `motolog replay` on it exits 0.
6. The ui-spec §5.1 `TelemetrySample` name stays bound to the UI-facing display
   record (`elapsed`, `angleDegrees`, `speedKPH`) and is never reused for the
   core stream type. The two live at different layers: `Sample` is a raw tagged
   sensor reading in SI units on a monotonic clock; `TelemetrySample` is a
   derived, display-unit, run-relative point produced by the decimation of
   R19.4.
7. Every pipeline stage conforms to `Stage` and is a value type whose entire
   state is reachable from its own properties. Given the same `Config` and the
   same ordered sample sequence, two runs of the pipeline produce byte-identical
   output. Enforced by a test that runs a fixture twice and compares encoded
   stage output.
8. No stage reads a numeric constant that does not live in `Config`. Verified by
   review plus a test asserting `Config` round-trips through
   `JSONEncoder`/`JSONDecoder` unchanged.
9. `Config.version` is incremented whenever a field is added, removed, or its
   default meaning changes. A log whose header carries an older `version` still
   decodes and replays.

### R2 — Raw ride logger

**Story.** As a rider, I want a recording of a session so complete that every
later question can be answered from the file, so that my first filmed ride is a
permanent asset rather than a one-off experiment.

1. The logger records, at the maximum rate iOS grants (nominal 100 Hz):
   raw gyro → `IMUSample.rotationRate`; raw accelerometer →
   `IMUSample.specificForce`; CoreMotion device motion with
   `xArbitraryZVertical` → `IMUSample.fusedAttitude` (recorded **alongside**,
   never substituted for raw); CoreLocation fixes → `GNSSFix`; barometer →
   `BaroSample`; and device thermal state.
2. The logger **never** filters, fuses, smooths, downsamples, or de-duplicates
   before writing. Checked by a test that feeds a known synthetic stream through
   the writer and asserts the decoded file equals the input sample-for-sample.
3. `IMUSample.saturated` is set true when any axis reaches the sensor's
   full-scale range in that sample.
4. All sample times are in one monotonic domain. `LogHeader.startedAt` is the
   single wall-clock anchor, written once at session start.
5. `GNSSFix` carries both `fixTime` and `arrivalTime`; the file must show a
   non-zero median difference between them for any real session, proving latency
   is measured rather than assumed.
6. Thermal state transitions are recorded as timestamped entries so the thermal
   timeline is reconstructable from the log alone.
7. Output per session is: one NDJSON stream matching the existing `LogFile`
   contract (one `LogHeader` line, then one `Sample` per line in monotonic
   order), one manifest listing the session's files, byte sizes, and checksums,
   and — in `vibration` mode only — one sidecar audio file (R3.4).
8. `LogHeader.config` contains the exact `Config` in force during the recording.
9. Over a 30-minute ride-mode session with the screen off: achieved gyro sample
   count ≥ 99% of nominal rate × duration, and the largest inter-sample gap
   < 50 ms.
10. Sustained write throughput must not block sensor delivery: the mean sensor
    callback-to-enqueue latency stays < 1 ms and the writer runs off the sensor
    callback context. Verified by an instrumented 30-minute run reporting max
    callback latency.
11. Every completed session is exportable through the share sheet and visible in
    the Files app.
12. `swift run motolog replay <session>` exits 0 for every session the app has
    recorded.
13. **Visual sync flash.** At the start of a `ride` session the app flashes the
    full screen white for a defined number of frames and logs the flash's
    monotonic timestamp. A camera filming the bike sees the flash, giving a
    frame-accurate alignment mark between video and telemetry with no microphone
    involved. Acceptance: the logged flash timestamp is within 20 ms of the frame
    in which the screen actually changes, measured once against a 120 fps
    reference recording.
14. **In-ride marker.** The rider can place a marker (a large on-screen target,
    or a hardware volume-button press) which appends a timestamped marker entry
    to the session. Markers are approximate labels for finding things later and
    are never used as event boundaries.
15. Ride-mode recording captures **no audio**. The microphone is not activated in
    `ride` or `bench` mode, and no audio sidecar is produced for them.

### R3 — Three recording modes

**Story.** As the developer, I want the same recorder to serve a ride, a
multi-hour bench soak, and a stationary rev sweep, so that noise
characterisation and vibration characterisation do not need separate tools.

1. Mode is chosen before recording starts and written into the session manifest
   as one of `ride`, `bench`, `vibration`.
2. **`ride`** enables IMU, GNSS, barometer, the visual sync flash, and markers as
   in R2. No microphone.
3. **`bench`** (Allan variance) records IMU only, targets 3–4 hours of static
   recording, disables GNSS, the microphone, the display, and every non-essential
   subsystem, and reports the thermal timeline. Acceptance: a 3-hour bench session
   completes without termination, with achieved rate ≥ 99% of nominal and peak
   thermal state no higher than `.fair`.
4. **`vibration`** records IMU **and audio** during a stationary idle-to-redline
   rev sweep and prompts the rider to hold each ~500 rpm band for ≥ 3 s. The app
   records only; the FFT analysis lives in the CLI (R20).
   The microphone is required here and cannot be substituted: per C3 the IMU is
   sampled at 100 Hz, so the engine's true excitation frequency (30–200 Hz) is
   already destroyed by aliasing in the IMU record and cannot be recovered from
   it. Audio at 44.1 kHz observes the firing frequency directly and unaliased,
   which is what lets the CLI label each RPM band with the frequency that
   produced the phantom tilt. This is a stationary, once-per-bike recording, so
   the microphone is never live while riding.
5. A `vibration` session is stored as a **bike vibration profile** keyed to a
   named bike profile (R18), containing per-RPM-band high-frequency RMS and the
   per-band phantom-tilt offset produced by the CLI analysis.
6. Switching modes never changes the log format: all three replay through
   `motolog replay`.

### R4 — Crash safety, integrity, and honest sessions

**Story.** As a rider, I want a session that survived a force-quit or a battery
scare to still open, and a session the app cannot vouch for to say so, so that I
never grade myself against data that is quietly wrong.

1. Writing is append-only. Data reaching the writer is durable within 1 s.
2. A force-quit, crash, or power loss during recording loses at most 1 s of data,
   and the resulting session still opens in the app and in `motolog replay`.
   Verified by a test that truncates a fixture mid-line and asserts recovery
   discards only the trailing partial line.
3. On next launch after an interrupted session, the app finds the partial session,
   repairs it (drop trailing partial line, synthesise the manifest), marks it
   `recovered`, and lists it normally.
4. Each session carries an **integrity report**: achieved vs nominal rate per
   channel, count and largest duration of gaps > 20 ms, saturated-sample count,
   thermal timeline, GNSS fix count and median `arrivalTime − fixTime`, and the
   visual sync flash timestamp.
5. A session whose achieved rate < 95% of nominal, or whose largest gap > 250 ms,
   or which contains any saturated sample inside a detected event, is flagged
   `lowConfidence` with the failing reason(s) named, and every run derived from it
   is labelled accordingly in the UI and excluded from personal bests (R18).
6. The integrity report is queryable from `motolog` and rendered in the app.

### R5 — Time alignment with external video — **WITHDRAWN**

Withdrawn by decision on 2026-08-26. The requirement ID is retired rather than
renumbered so every cross-reference in this document and in design.md stays
valid. Nothing in this section is to be implemented.

What it required, and where each piece went:

- Microphone audio for the whole ride session, and audio cross-correlation
  against an imported video's audio track — **removed entirely**. Video import
  and telemetry-over-video scrubbing are now non-goals (§6).
- The session-start chirp — **removed**. Replaced by a visual sync flash
  (R2.13), which serves the same alignment purpose without a microphone.
- The in-ride marker — **kept**, moved to R2.14, since markers never needed
  audio.
- Ride-mode audio is therefore not recorded. Microphone use survives in exactly
  one place: `vibration` mode (R3.4), where audio is the only phone sensor that
  can observe engine firing frequency without aliasing. See R3.4 for that
  argument.

Consequence to accept knowingly: video ground-truth alignment for the M1
validation ride is now visual (R2.13), accurate to about ±1 video frame instead
of sub-frame. At 60 °/s pitch rate one frame at 60 fps is ~1° of apparent angle
error, so the §7 definition-of-done tolerance absorbs it but the margin is
thinner than it was.

### R6 — Bias calibration

**Story.** As a rider, I want the app to know my gyro bias to a tenth of a degree
per second and tell me when that knowledge has gone stale, so that a 10-second
hold is accurate to under a degree instead of five.

1. Per-session bias zeroing runs with the bike stationary, rider seated, engine
   idling, gated on `ValidityGate` opening: specific-force magnitude within
   `[gateSpecificForceLow, gateSpecificForceHigh]` (0.97–1.03 g) **and** every
   gyro axis below `gateMaxRotationRate` (3 °/s) **and** held for
   `gateDwell` (0.5 s).
2. Zeroing collects for `Config.biasCalibrationDuration` (default 8 s, minimum
   8 s, target 10 s) of continuously gate-open samples. Any gate closure resets
   progress and the UI reports why using `ValidityGate.Reason`.
3. Output is a `BiasEstimate`: bias `Vector3` (rad/s), per-axis σ, sample count,
   the monotonic time and the wall-clock time of completion, and the ID of the
   bike profile in force.
4. After a 10 s zeroing on a stationary bike, per-axis σ < 0.01 °/s. A zeroing
   whose σ exceeds that threshold on any axis **fails** with the axis named
   rather than being accepted.
5. Bias **age** is tracked continuously and surfaced. Reported live angle
   uncertainty grows with age using `Config.gyroBiasInstability` and a thermal
   term, and the estimate is marked `stale` once age exceeds
   `Config.biasStaleAfter` (300 s).
6. When the gate re-opens for `gateDwell` while the rider is stopped, the app
   offers an opportunistic re-zero; accepting it takes no more taps than
   starting a recording, and declining it never blocks riding.
7. Bias is additionally estimated **continuously** as an explicit ESKF state
   (R8); the calibration of this requirement initialises that state and its
   covariance, it does not replace it.
8. The UI spec §5.3 `CalibrationState` enum maps onto this system as:
   `unavailable` (motion denied or gate never satisfiable), `calibrating`
   (progress = collected/required duration), `calibrated(referenceID:
   calibratedAt:)` carrying the `BiasEstimate` identity, `stale` (age >
   `biasStaleAfter`, or bike profile changed, or thermal jump beyond threshold),
   `failed(message:)` (σ threshold breached, gate never opened within the
   attempt window, or saturation during collection).
9. Saturated samples never enter a bias estimate.
10. **Manual recalibration.** Tapping the `CALIBRATED` status pill in the Live
    screen header forces an immediate transition to `calibrating` state,
    displaying the calibrating overlay with the "Hold the bike still with the
    engine idling" instruction. The validity gate resolves it normally. If
    tapped while moving (gate cannot open), the overlay remains until the rider
    stops — this blocks live data intentionally, preventing use of stale bias
    while the rider believes they have recalibrated.
11. **`docs/ui-spec.md` §7.4 is amended.** The calibrating-overlay instruction
    line changes from `Ride in a straight line at a constant speed` to
    `Hold the bike still with the engine idling`, and the same substitution is
    made in the §7.2 state matrix row for `Calibrating` and in the §7.7
    `CalibrationOverlay(message:)` sketch. Every other §7.4 rule is unchanged and
    binding: the same underlying dual-meter layout rendered inactive, em-dash
    values, unfilled tracks, whole-content dimming with `surfaceOverlay`,
    **exactly one** prominent centered indeterminate spinner, `CALIBRATING`
    beneath it, no second calibration icon or spinner in the header, no green
    status light until success, and a VoiceOver announcement plus optional
    haptic on completion. The ui-spec §16.1 criterion "Calibrating state
    contains exactly one spinner and the correct instruction" is therefore
    checked against the new sentence.
11. Because the overlay's instruction is now stationary-only, **mount alignment
    (R7) does not run in the Live screen's calibrating overlay.** It runs in the
    bike-profile setup flow (R18.1), which matches its once-per-bike-or-remount
    lifetime. The Live screen's `CalibrationState` therefore covers bias zeroing
    only; a missing or invalidated alignment surfaces as
    `unavailable`/`stale` with a link into bike-profile setup rather than as an
    in-overlay gesture prompt.

### R7 — Mount alignment

**Story.** As a rider, I want to mount my phone however it fits on my bike, so
that a crooked mount costs me nothing in accuracy.

1. Alignment solves the phone→bike rotation from two gestures: (a) at rest and
   level, the gate-open specific force defines **down**; (b) one hard
   straight-line acceleration defines **forward**, taken as the component of
   specific force orthogonal to down; the cross product gives the third axis.
   The result is orthonormalised into a `Quaternion`.
2. The solved `forwardInBody` and `upInBody` vectors are what get passed to
   `AxisElevation.pitch` and `AxisElevation.roll`; nothing downstream assumes a
   device-frame convention.
3. Alignment quality is reported: the residual non-orthogonality before
   orthonormalisation, and the peak longitudinal acceleration achieved during
   gesture (b). Acceptance: an alignment whose gesture (b) peak is below 0.25 g
   is rejected with a message asking for a harder pull.
4. Alignment is stored per bike profile and reused across sessions; it is
   invalidated when the rider says the phone was remounted, and the app prompts
   for it when no valid alignment exists for the active bike profile.
5. Given a synthetic stream generated with a known arbitrary mount rotation, the
   recovered alignment reproduces the true pitch to within 0.5° across the whole
   scenario.

### R8 — Live attitude estimator (ESKF)

**Story.** As a rider, I want a live angle I can trust to a couple of degrees
while the wheelie is happening, so that the coaching cue fires on reality.

1. The live estimator is an Error-State Kalman Filter whose state includes
   attitude error and gyro bias, propagated by raw gyro integration.
2. Accelerometer measurements are admitted according to `ValidityGate`. When the
   accelerometer's linear-acceleration content exceeds 0.1 g, its measurement
   noise is inflated by ~100× rather than the measurement being dropped
   discontinuously; the inflation factor lives in `Config`.
3. `GNSSFix.speed` is used as an aiding measurement when `isSpeedValid`, weighted
   by `speedAccuracy`, timestamped by `fixTime`, and applied with the known
   `arrivalTime − fixTime` latency accounted for rather than ignored.
4. Gyro bias process noise is thermal-aware: it increases with device thermal
   state and with time since the last successful zeroing.
5. `CMDeviceMotion.attitude` (`IMUSample.fusedAttitude`) is recorded and may be
   displayed for comparison but is never an input to the state estimate.
   Verified by a test asserting the estimator produces identical output when
   `fusedAttitude` is stripped from every sample.
6. Pitch and roll are read out via `AxisElevation`, never via Euler angles.
7. Live accuracy: on a synthetic 45° wheelie with an injected gyro bias of
   0.3 °/s and vibration at 83 Hz, the live estimate stays within **2°** of
   `SyntheticSource.truePitch(at:)` for the whole event.
8. Live accuracy under a constant road grade: with `Scenario.roadGrade` set to
   ±4°, the estimator's reported wheelie angle relative to the road remains
   within 2° of truth (grade absorbed by the baseline, per
   `Config.baselineTimeConstant`).
9. The estimator emits, per IMU sample: attitude quaternion, pitch, pitch rate,
   roll, bias estimate, and a scalar 1σ pitch uncertainty in radians.
10. Live pipeline cost, measured on an iPhone 16 at 100 Hz, leaves the main
    actor free: estimator wall time per sample < 200 µs and the app publishes
    state to the UI at ≤ 30 Hz (UI spec §12).

### R9 — Post-ride smoother (RTS)

**Story.** As a rider, I want the number I put on a leaderboard to be the best
number the data can support, so that my personal best is a measurement and not
an artefact of what the filter knew at the time.

1. A Rauch–Tung–Striebel smoother runs a forward pass and a backward pass over
   the recorded session, so that information available *after* the event — the
   accelerometer seeing pure gravity again on landing — propagates backwards and
   retroactively corrects the event.
2. The smoother runs from the log alone (no live state), inside
   `MotoTelemetryCore`, and produces the same result in the app and in `motolog`.
3. Smoothed accuracy: on the R8.7 synthetic scenario, the smoothed estimate stays
   within **0.5°** of truth across the event, and the peak-angle error is
   within 0.5°.
4. Every run stores **both** numbers: `liveMaxAngle` and `smoothedMaxAngle`, with
   their respective 1σ uncertainties. The smoothed value is the one used for
   personal bests, leaderboards, and sharing; the UI states which it is showing.
5. Smoothing a run is idempotent and re-runnable: re-smoothing an unchanged
   session with an unchanged `Config` reproduces byte-identical output.
6. Smoothing a 30-minute session completes in under 30 s on an iPhone 16 and
   runs off the main actor with progress reported.
7. If smoothing cannot complete (corrupt log, insufficient post-event gate-open
   samples), the run keeps its live numbers and is marked
   `smoothingUnavailable`; it is never silently presented as smoothed.

### R10 — Event segmentation

**Story.** As a rider, I want the app to find my wheelies for me and not count
speed bumps, so that my run list matches what actually happened.

1. Onset is declared when the calibrated angle remains above
   `Config.eventEntryPitch` (10°) for `Config.eventEntryDwell` (150 ms). 10° is
   also the floor for clocking duration: below it the reported angle is
   suspension travel and mount slop, not riding.
2. End is declared when the angle remains below `Config.eventExitPitch` for
   `Config.eventExitDwell` (250 ms). `eventExitPitch` is set to **7°**, keeping
   3° of hysteresis below entry (it was 5° against an 8° entry, and 4.0° before
   that); `eventEntryDwell` and `eventExitDwell` are new `Config` fields and
   that addition bumped `Config.version`. Later threshold *value* changes do not
   bump the version — a log header stores its own thresholds, so it replays
   under the ones that produced it either way.
3. Events shorter than `Config.eventMinDuration` (0.4 s) are discarded unless
   debug mode is enabled (UI spec §7.6).
4. Pitch rate crossing `Config.eventEntryPitchRate` (15 °/s) is the primary
   detection signal; a secondary confirmation compares GNSS-derived longitudinal
   acceleration against the IMU-derived value and raises confidence when they
   diverge as thrust-under-pitch predicts.
5. Boundaries are computed by linear interpolation between adjacent samples, not
   snapped to sample times.
6. Segmentation is deterministic and identical live and on replay: a fixture
   session segmented by the app and by `motolog` yields the same event count and
   boundaries to within 1 ms. This is a CI-checked equality, not a review item.
7. Current-attempt maxima reset only when a new attempt begins (UI spec §7.6).
8. A completed run is persisted atomically when it ends (UI spec §7.6): a crash
   during persistence leaves either no run or a complete run, never a half one.

### R11 — Run metrics and scoring

**Story.** As a rider, I want each wheelie scored on the things that actually
distinguish a good one, so that I can see whether I am improving at holding
rather than just at snapping the front up.

1. Per event, the app computes and stores: max angle (live and smoothed),
   duration, average held angle, angle standard deviation over the hold
   (consistency), distance travelled (GNSS-derived), speed at entry, and the
   roll envelope (min/max roll) during the hold.
2. Angle standard deviation is computed over the **hold** portion only, defined
   as the interval between the end of the rising ramp and the start of the
   descent, with the ramp boundaries derived from pitch rate crossing zero.
3. Session summary stores: event count, cumulative hold time, and the best event
   by each metric.
4. Every metric carries the uncertainty of its source: a max angle is stored with
   its 1σ, and a `lowConfidence` session (R4.5) propagates that flag to its runs.
5. Metrics map onto the UI spec §5.1 `WheelieRun` fields without a parallel
   model: `duration`, `maxAngle`, `maxSpeed`, `averageSpeed`, `angleIntervals`,
   `speedIntervals` are the UI-facing projection; the additional metrics of this
   requirement extend that record rather than replacing it.
6. `motolog` prints the same metric values for a fixture session as the app
   computes for it, to within 1e-9 on every numeric field. CI-checked.

### R12 — Target-band practice mode

**Story.** As a rider, I want to practise holding a specific angle band rather
than chasing a maximum, so that I train the skill that matters and can see how
much of each attempt I spent in the band.

1. The rider sets an angle target range and a speed target range using the UI
   spec §7.5 editor, stored as `MetricRange` in `RiderPreferences` and captured
   into `RunConfigurationSnapshot` when a run is recorded (UI spec §5.1).
2. In-range interval detection follows UI spec §9.6 exactly: in-range when
   `lower ≤ value ≤ upper`; boundary crossings linearly interpolated; fragments
   shorter than 0.15 s ignored; intervals separated by ≤ 0.10 s merged; **every**
   remaining interval preserved; total in-range duration = sum of durations after
   cleanup.
3. The 0.15 s and 0.10 s constants live in `Config` and are unit tested (UI spec
   §9.6).
4. Intervals are computed once, when the run is finalised, and stored on the run
   (UI spec §12); they are recomputed only after a schema upgrade or a
   re-smoothing.
5. Detection is run independently per metric and against the run's stored
   snapshot, never against the rider's current preferences (UI spec §5.1, §9.1).
6. Per-event score is time held within the angle band, reported alongside
   duration.
7. Test coverage includes the UI spec §17 fixtures 5, 6, and 7 (repeated
   intervals with partial overlap; a run that never enters either range;
   complete overlap).

### R13 — Predictive audio cue engine

**Story.** As a rider, I want the app to tell me through my ears that I am about
to pass my target, so that I never look at the screen while the front wheel is
up.

1. The primary coaching channel is audio. There is **no** live visual gauge that
   requires or rewards looking at the screen during an attempt; the UI spec's
   Live meters are glanceable only, and configuration is disabled while an
   attempt is active (UI spec §2, §7.5).
2. The cue fires on **time-to-threshold**, computed by
   `AxisElevation.timeToThreshold(current:rate:target:)`, not on crossing the
   threshold. `target` is the **upper** bound of the rider's angle target band.
3. A rising continuous tone begins when time-to-threshold falls below
   `Config.timeToThresholdWarn` (0.4 s) plus
   `Config.audioLatencyCompensation`, and its pitch rises as the remaining time
   shrinks. Creeping up slowly stays silent; snapping up fast warns early —
   verified by a test asserting no cue fires for a 3 °/s approach and a cue
   fires at least 0.35 s before threshold for a 60 °/s approach.
4. A **distinct, urgent** tone, unmistakable from the approach tone, fires on
   excessive pitch **rate** (approaching loop-out) as a separate channel with its
   own `Config` threshold. Both may be active; the urgent tone takes priority in
   the mixer.
5. The tone engine runs in a background audio session so the app keeps running
   with the screen off; the session category permits mixing with the rider's
   music and does not stop when the display sleeps.
6. Audio route latency is measured and compensated: the app detects the active
   route, prefers HFP/SCO (~50 ms) over A2DP (100–200 ms), warns the rider when
   the active route is A2DP, and folds the measured or assumed route latency into
   the lead constant. End-to-end latency from sample timestamp to audible tone
   onset is < 120 ms on a wired or HFP route, measured once on the bench with an
   external recorder — not by the app opening a microphone.
7. The cue decision is made in `MotoTelemetryCore` and returns a declarative cue
   state (tone identity, target frequency, amplitude); the app target only
   renders it. This is what makes the cue replayable: `motolog` can print the cue
   timeline for a recorded session.
8. The cue engine never blocks or is blocked by the disk writer.

### R14 — Vibration, aliasing, and data-quality disclosure

**Story.** As a rider, I want the app to tell me when my mount is ruining the
data, so that I fix the mount instead of trusting a corrupted number.

1. The app computes a running high-frequency indicator: RMS of the
   specific-force residual above 20 Hz, per one-second window, with the
   threshold in `Config`.
2. When the indicator exceeds its threshold during calibration, calibration
   fails with a vibration reason rather than producing a quietly-bad bias.
3. When it exceeds its threshold during a ride, the session's integrity report
   records the affected intervals and the app shows a mount-vibration warning
   naming mechanical isolation as the fix, not a software setting.
4. A bike's stored vibration profile (R3.5) marks RPM bands where the CLI's FFT
   analysis found a phantom-tilt offset exceeding 1°. Because a ride session
   records no audio, a ride cannot identify its own excitation frequency; instead
   a run is flagged `aliasingSuspect` when its high-frequency indicator (R14.1)
   or its gate-open baseline shift matches the signature the profile recorded for
   a marked band. The profile supplies the diagnosis; the ride supplies only the
   symptom. Acceptance: replaying a ride recorded at an RPM the profile marked
   flags the run, and replaying one recorded in an unmarked band does not.
5. Any run containing a saturated sample inside its event window is flagged and
   excluded from personal bests.
6. No requirement anywhere in this spec is satisfied by digitally filtering
   aliased content out; per C3 the information is destroyed at sampling.
7. Reported live uncertainty degrades monotonically with bias age, thermal state,
   and the vibration indicator. Acceptance: with bias age at
   `biasStaleAfter` and the vibration indicator above threshold, the displayed
   uncertainty is strictly greater than at age 0 with a quiet mount, and a run
   whose live 1σ exceeds 3° or smoothed 1σ exceeds 1.5° is marked
   `lowConfidence`.

### R15 — Live Wheelie screen

**Story.** As a rider, I want the live screen to show me angle, speed, and hold
time at a glance and nothing else, so that it never competes for attention I owe
the road.

1. The screen implements `docs/ui-spec.md` §7 in full: state matrix (§7.2),
   calibrated layout with dual vertical meters (§7.3), calibrating overlay
   (§7.4), target and scale editing (§7.5), and attempt lifecycle (§7.6).
2. `CalibrationState` is driven by R6.8 and covers **bias zeroing only**; the
   overlay instruction is the amended sentence of R6.10 and mount alignment is
   reached from bike-profile setup (R6.11), never from this overlay. The ui-spec
   single-spinner, no-duplicate-status, and no-green-dot-until-success rules hold
   unchanged.
3. Angle values displayed come from the live estimator (R8), speed from
   `GNSSFix.speed` converted at the display boundary; when location is
   unavailable, speed reads unavailable and is never fabricated as 0 (UI spec
   §15).
4. Display smoothing (UI spec §7.3, α ≈ 0.20–0.35 at 30 Hz) affects presentation
   only; the stored run uses estimator output, not animation-interpolated values.
5. Acceptance criteria are UI spec §16.1, reproduced verbatim in §8.1 below.

### R16 — Past Runs screen

**Story.** As a rider, I want to scan my session and see instantly which attempts
were my best, so that I can find the one worth reviewing.

1. The screen implements `docs/ui-spec.md` §8 in full: header and controls
   (§8.2), row design (§8.3), personal-range colour normalisation (§8.4), and
   empty/loading/error states (§8.6).
2. Colour anchors are per-field and scope-dependent exactly as §8.4 specifies;
   sorting and numeric filtering do not move the anchors.
3. Runs flagged `lowConfidence`, `aliasingSuspect`, `recovered`, or
   `smoothingUnavailable` are visibly marked and excluded from personal-best
   anchors.
4. Acceptance criteria are UI spec §16.2, reproduced verbatim in §8.2 below.

### R17 — Run Details and sharing

**Story.** As a rider, I want to see how one wheelie unfolded second by second
next to my own footage, so that I can tell why the good ones were good.

1. The screen implements `docs/ui-spec.md` §9 in full: hero summary (§9.3),
   synchronised angle and speed charts with a shared scrubber (§9.4), insight
   strip (§9.5), the one-line interactive interval timeline (§9.6), and
   share/export (§9.7).
2. Chart series are drawn from a downsampled projection (≤ 300 points per chart,
   ui-spec §9.4). Maxima come from the values computed at finalisation, and
   scrubber interpolation uses raw samples hydrated from the run's `SessionSpan`
   per R19.4, degrading to the decimated series with a reduced-fidelity label
   when the raw log is gone.
3. Video import and telemetry-over-video scrubbing are **not** in v1 (§6). Run
   Details shows telemetry only.
4. Sharing a run does not composite telemetry onto footage; the rider overlays
   the shared still on their own video in whatever editor they already use.
5. A scored event can be shared as a still image with overlay statistics (angle,
   duration, speed, date, and whether the number is smoothed), through the
   platform share sheet with explicit user confirmation (UI spec §9.7).
6. CSV export uses the UI spec §9.7 field list
   (`elapsed_seconds,angle_degrees,speed_kph`); full-fidelity export is the raw
   NDJSON session of R2.
7. Acceptance criteria are UI spec §16.3, reproduced verbatim in §8.3 below.

### R18 — Bike profiles, local leaderboard, progression

**Story.** As a rider with more than one bike, I want my bests kept per bike, so
that a 45° on the little bike is not compared against a 45° on the big one.

1. The rider can create, name, edit, and delete bike profiles. Each stores its
   mount alignment (R7), its vibration profile (R3.5), and its calibration
   history.
2. Exactly one bike profile is active at a time; changing it marks the current
   calibration `stale` (R6.8) and prompts for a re-zero.
3. Personal bests are computed **per bike profile** per metric (max smoothed
   angle, longest duration, longest time in band, best consistency), from runs
   not excluded by R4.5, R14.4, or R14.5.
4. Progression is shown as a per-metric history over time, scoped to the active
   bike profile.
5. All leaderboard and profile data is local. No network call is made by the app
   for any purpose in v1; verified by a test/inspection asserting no URL-session
   or network entitlement usage in the app target.

### R19 — Persistence, permissions, background, and power

**Story.** As a rider, I want to start a recording, put the phone in the mount,
lock the screen, and ride, so that the app is a tool and not a chore.

1. Recording continues with the screen off and the app backgrounded, using the
   audio and location background modes. The audio background mode is claimed for
   the **cue engine's output session** (R13.5), not for recording — it is what
   keeps the process alive with the display off; no microphone is opened.
   Acceptance: a 30-minute screen-off backgrounded session meets R2.9.
2. The app requests motion and location (when-in-use at minimum) permissions with
   usage strings that state why each is needed, and degrades explicitly when one
   is denied (ui-spec §15): no location → no speed, no distance, no GNSS aiding,
   and a stated consequence; no motion → no calibration and no recording.
   Microphone permission is requested **lazily, only when the rider starts a
   `vibration` recording** (R3.4), with a usage string naming engine-frequency
   measurement; denying it blocks only that mode and nothing else. Ride and bench
   recording, calibration, estimation, coaching, and review all work with the
   microphone permanently denied.
3. Runs, preferences, bike profiles, calibrations, and integrity reports persist
   across app launches and survive an app update without data loss; a schema
   version is stored and migrations are explicit.
4. Raw session logs are stored compactly and are never rewritten in place. A run
   record holds: its derived metrics (R11), its `angleIntervals` and
   `speedIntervals` (R12.4), its `RunConfigurationSnapshot`, its confidence and
   integrity flags, and a **~30 Hz decimated display series** — plus a
   `SessionSpan` reference (session ID, start time, end time) into the raw
   NDJSON. Raw samples are never duplicated into the run record.
   Consequences that are binding, not incidental:
   - The ui-spec §5.1 `WheelieRun.samples` array is the **decimated display
     series**, and its `maxAngle`/`maxSpeed`/`averageSpeed` are the values
     computed from raw at finalisation (R11.1), not recomputed from the decimated
     series. A max must never be a decimation artefact.
   - Raw samples for the ui-spec §9.4 scrubber interpolation are **hydrated on
     demand** from the `SessionSpan` when Run Details opens, not held resident.
     Hydrating one event's span from a 30-minute log completes in under 300 ms on
     an iPhone 16.
   - When the raw log has been deleted (R19.5) or fails to hydrate, Run Details
     falls back to the decimated series for scrubbing, labels the run's telemetry
     as reduced-fidelity, and keeps hero metrics and intervals — which is the
     ui-spec §15 "show summary metrics if valid, replace charts" rule applied to
     a deliberate deletion rather than corruption. Re-smoothing (R9.5) and
     re-scoring are unavailable for such a run and the UI says so.
   - Decimation is deterministic and its rate lives in `Config`, so two devices
     finalising the same session produce the same display series.
5. Storage cost is disclosed: the app shows per-session size and total usage, and
   lets the rider delete a session's raw log while keeping its derived run
   metrics.
6. Battery: a 30-minute ride-mode session consumes no more than 25% of an
   iPhone 16 battery at 100% start, screen off, and the app reports the measured
   figure in the integrity report so regressions are visible.
7. Thermal: when thermal state reaches `.serious`, the app warns the rider and
   names what it is shedding (display updates, smoothing, audio effects) and
   never silently reduces sensor rate. If iOS itself reduces the delivered rate,
   the integrity report records it.

### R20 — Replay CLI and offline analysis tooling

**Story.** As the developer, I want to re-run today's tuning idea against last
week's ride on my desk, so that iterating does not require a motorcycle.

1. `motolog replay <session>` runs the full pipeline — calibration, estimator,
   smoother, segmenter, scorer, interval detector, cue engine — and prints the
   session summary, per-event metrics, and the cue timeline.
2. `motolog replay` accepts a `Config` override so a recorded ride can be
   re-scored against new parameters, printing both the header's config version
   and the override in use.
3. Every stage's output is inspectable, not just the final angle: a flag dumps
   per-sample stage output as NDJSON so a wrong reading can be attributed to the
   stage that first went wrong.
4. `motolog fft <session>` computes the vibration spectrum for a `vibration`
   session using Accelerate on macOS (an analysis tool outside the pure core, in
   the CLI target only) and reports, per RPM band, the dominant frequencies,
   which of them alias at 100 Hz, and the phantom-tilt offset. Its output is the
   bike vibration profile of R3.5.
5. `motolog allan <session>` computes overlapping Allan deviation for a `bench`
   session and reports angle random walk read off the −1/2 slope at τ = 1 s and
   bias instability from the flat minimum divided by 0.664, formatted as the
   `Config` fields they replace (`gyroNoiseDensity`, `gyroBiasInstability`,
   `accelNoiseDensity`).
6. `motolog synth` keeps working and gains scenario parameter flags so a
   regression case can be reproduced from the command line.
7. App-and-CLI parity is CI-checked: for every fixture session, event count,
   boundaries, and every scalar metric match between the two paths (R10.6,
   R11.6).

### R21 — Test strategy and CI

**Story.** As the developer, I want a suite that fails loudly when the physics
breaks, so that I find out on my Mac rather than on the road.

1. `swift test` passes on macOS CI with no device attached and no network access.
2. `SyntheticSource` is the regression backbone. Required scenario matrix, each
   asserting live within 2° and smoothed within 0.5°: nominal 45°; peak 30° and
   70°; gyro bias 0.05, 0.3 and 0.5 °/s; road grade 0 and ±4°; vibration at 0,
   83 Hz, and 100 Hz (the aliases-to-DC case); GNSS present and absent.
3. The 100 Hz vibration case asserts the app **detects and discloses**
   corruption (R14) rather than asserting an accurate angle — a passing result
   there would be a false claim.
4. Recorded fixtures under `Fixtures/` cover integration: a real short session
   with one event, a truncated session for recovery (R4.2), a session with a
   saturated sample, and a low-rate session. Fixtures stay small (a few seconds
   around one event); full sessions live in the gitignored `Rides/`.
5. The UI spec §17 fixtures 1–10 exist as deterministic preview/test fixtures,
   including the 10,000-sample long run for downsampling and interaction
   performance.
6. Unit-tested by name: interval detection debounce and merge constants (UI spec
   §9.6), personal-range colour normalisation including the all-values-equal case
   (UI spec §8.4), `ValidityGate` reasons, axis-elevation roll invariance,
   `timeToThreshold`, log recovery, and `Config` round-trip.
7. Snapshot/visual tests cover live meter fill and cursor behaviour; UI tests
   cover both calibration states (UI spec §18).
8. CI runs `swift build`, `swift test`, and the parity check of R20.7 on every
   push and pull request.

## 5. Traceability

| Requirement | Existing code it builds on | UI spec sections |
|---|---|---|
| R1 | `Stage`, `MeasurementSource`, `Measurement`, `Config` | — |
| R2 | `LogFile`, `LogHeader`, `IMUSample`, `GNSSFix`, `BaroSample` | §12, §14 |
| R3 | `LogHeader.notes`, `Config` | — |
| R4 | `LogFile.read` | §15 |
| R5 | *withdrawn — not implemented* | — |
| R6 | `ValidityGate`, `Config.biasCalibrationDuration/biasStaleAfter` | §5.3, §7.2, §7.4, §14 |
| R7 | `Quaternion`, `AxisElevation` | — |
| R8 | `ValidityGate`, `AxisElevation`, `Config` noise fields | §7.3, §12, §14 |
| R9 | `ReplaySource`, `LogFile` | §5.1, §9.3 |
| R10 | `Config.event*` fields | §7.6 |
| R11 | `AxisElevation.roll`, `GNSSFix` | §5.1, §8.3, §9.3, §9.5 |
| R12 | `Config` | §5.1, §5.2, §7.5, §9.6 |
| R13 | `AxisElevation.timeToThreshold`, `Config.timeToThresholdWarn`, `audioLatencyCompensation` | §2, §7.5 |
| R14 | `IMUSample.saturated`, `Config.accelLowPassCutoff` | §15 |
| R15 | — | §7, §16.1, §17 |
| R16 | — | §8, §16.2 |
| R17 | — | §9, §16.3 |
| R18 | — | §11, §14 |
| R19 | `LogFile` | §11, §12, §14, §15 |
| R20 | `motolog`, `ReplaySource`, `SyntheticSource` | §9.7 |
| R21 | `SyntheticSource`, `Fixtures/`, `.github/workflows/ci.yml` | §17, §18 |

## 6. Non-goals for v1.0

Not specified, not built, not designed around:

- Anti-loop intervention (cutting ignition or applying brake).
- Cloud backend, user accounts, and any social or server-side leaderboard.
- BLE CSC wheel-speed sensor integration. The `WheelSpeedSample` case stays in
  the enum as a reserved slot; no code path produces or consumes it in v1.
- GoPro / GPMF parsing, and any video decoding, re-encoding, or composited
  video export.
- Video import, video-to-telemetry alignment, and telemetry-over-video scrubbing
  (withdrawn R5, R17.3).
- Audio recording during a ride, audio cross-correlation, and the session-start
  chirp (withdrawn R5). The microphone is opened only for a stationary
  once-per-bike `vibration` recording (R3.4).
- Camera, ARKit, VIO, magnetometer, Apple Watch as a live sensor.
- Custom hardware; v1 is phone-only.
- Any third-party dependency.
- Android, iPad-optimised layouts, and landscape (UI spec §3.2 makes landscape
  optional; v1 declines it).

## 7. Definition of done

v1.0 is done when: every acceptance criterion in §4 is met (excluding withdrawn
R5); the ui-spec §16 criteria in §8 all pass; the ui-spec §18 definition of done
is met; the R21 scenario matrix is green in CI; and one filmed ride's smoothed
peak angle agrees with side-on video ground truth to within 2°, where video and
telemetry are aligned by the R2.13 visual sync flash and the video's own frame
timestamps.

## 8. UI acceptance criteria (verbatim from `docs/ui-spec.md` §16)

These are reproduced without alteration and are binding.

### 8.1 Live Wheelie

- [ ] Angle scale is always 0°–90°.
- [ ] Speed scale uses the configured maximum.
- [ ] Each meter fills only from zero to the current cursor.
- [ ] Track above the cursor remains unfilled.
- [ ] Angle is left; speed is right and mirrored.
- [ ] Bottom order is Angle, Wheelie Time, Speed.
- [ ] Current-attempt maxima update without showing history statistics.
- [ ] Target ranges and speed maximum are editable while idle.
- [ ] Calibrating state dims the entire screen.
- [ ] Calibrating state contains exactly one spinner and the correct instruction.
- [ ] Calibrated state contains one green dot and `CALIBRATED`.

### 8.2 Past Runs

- [ ] No hash/attempt numbering appears.
- [ ] Rows are compact and fully tappable.
- [ ] Time, angle, and speed can each be selected for sorting/filtering.
- [ ] Metric colors normalize independently.
- [ ] Each field's personal best is bright green.
- [ ] No yellow appears in the scale.
- [ ] Selecting a row opens the correct Run Details record.
- [ ] Sort/filter state survives return from details.

### 8.3 Run Details

- [ ] Hero metrics show duration, max angle, and max speed.
- [ ] Angle and speed charts share one time selection.
- [ ] Both target bands remain visible on their main graphs.
- [ ] Angle and speed maxima use separate graph markers.
- [ ] No generic `Peak At` metric or timeline event appears.
- [ ] Insight strip shows angle in range, average speed, and speed in range.
- [ ] Bottom visualization contains exactly one baseline.
- [ ] Every valid in-range interval is rendered, not only the longest.
- [ ] Angle and speed intervals occupy the same line and blend where overlapping.
- [ ] Tapping one segment shows metric, ordinal, start, end, and duration.
- [ ] Tapping an overlap does not silently choose the wrong metric.
- [ ] Historical target bands come from the run snapshot.

## 9. Resolved decisions

All four decisions are resolved. They are recorded here for provenance; each is
specified normatively in the requirement named.

1. **Calibration instruction copy — RESOLVED.** ui-spec §7.4's sentence is
   amended to the stationary instruction, per R6.10. Consequence: mount
   alignment moves out of the calibrating overlay into bike-profile setup
   (R6.11). The `docs/ui-spec.md` edit itself is an early task in tasks.md so
   the two documents never sit in disagreement.
2. **Core enum rename — RESOLVED.** `Measurement` → `Sample`, with the full
   rename surface and the no-wire-format-change guarantee in R1.4–R1.6.
   `MeasurementSource` keeps its name; ui-spec `TelemetrySample` keeps its
   meaning as the display record.
3. **Run storage — RESOLVED.** Derived metrics + intervals + snapshot + a ~30 Hz
   decimated display series + a `SessionSpan` reference into the raw NDJSON,
   specified in full in R19.4 with the on-demand hydration path and the
   raw-deleted fallback. R17.2 is aligned to it.
4. **Event exit threshold — RESOLVED.** `eventEntryDwell = 0.15` and
   `eventExitDwell = 0.25` were added and `Config.version` bumped to 2 (R10.2).
   The threshold pair is now `Config.eventEntryPitch` = 10° and
   `Config.eventExitPitch` = 7°, giving 3° of hysteresis between onset and end
   (previously 8°/5°, and 4° exit in v1). Raising entry to 10° raises the floor
   for counting a wheelie at all and for clocking its duration.
   Per R1.9 the older `version: 1` header must still decode and replay, so the
   `Config` decoder supplies the new dwell fields as defaults for a v1 log —
   which means a pre-change recording re-scores under v1 thresholds only if the
   header's own config is used, and under v2 thresholds when replayed with an
   override. `motolog replay` prints both (R20.2), so which thresholds produced a
   number is never ambiguous.
