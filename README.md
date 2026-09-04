# moto-telemetry

Measures motorcycle pitch (wheelie angle), speed, and lean from an iPhone.

## The one architectural rule

**The pipeline is a pure function over a time-ordered stream of tagged
measurements.** No CoreMotion import, no UI, no clock of its own — time arrives
inside the sample. That is what lets the identical code run three ways: live on
the bike, replayed from a file on your desk, and in a unit test with no phone in
the room. Break this and every tuning change to the gate or the filter costs you
a ride, in traffic, on a bike you are trying to wheelie.

`MotoTelemetryCore` therefore has **zero platform dependencies**. The iOS app
target only shovels samples in and audio out.

## Why this is hard

An accelerometer measures specific force — gravity *plus* linear acceleration —
and cannot decompose them. At 0.5 g of forward acceleration that is 26.6 deg of
phantom pitch. Worse, a sustained wheelie needs thrust of roughly `g*tan(theta)`,
so the disturbance is almost perfectly correlated with the signal.

But gyro integration over a 5-30 s wheelie drifts only 0.03-0.08 deg.

**So this was never a drift problem.** The whole error budget is the pitch
estimate and the gyro bias at the instant the wheelie starts. Bias to
+/-0.5 deg/s gives 5 deg of error over a 10 s hold; +/-0.05 deg/s gives 0.5 deg.
Accuracy is decided during the boring straight-line run-up.

## Known platform limits

- Every CoreMotion path is capped at **100 Hz**. Raw does not beat fused.
  `CMBatchedSensorManager` (800 Hz) is watchOS only.
- CoreLocation is **~1 Hz**. iOS exposes no raw GNSS at all.
- A twin at 6000 rpm buzzes at exactly 100 Hz and **aliases to DC** — a phantom
  tilt that appears with throttle. Unfixable in software; attenuate at the mount.
- Do **not** trust `CMDeviceMotion.attitude` during an event: Apple's fusion
  assumes the long-run mean of the accelerometer is gravity, which is false for
  the whole duration of a wheelie.

## Milestones (ORIGINAL M0 scaffold roadmap)

> This is the roadmap as written at M0. It is kept for history; it is **not** what
> the current `beta/calibrate-once` branch does. See "What the beta actually built"
> below, and `docs/architecture.md` for the as-built picture.

- **M0** this scaffold — package, CI, synthetic source, validity gate, tests
- **M1** logger app; one filmed ride with side-on tripod ground truth
- **M2** replay CLI + FFT tool (Accelerate) to settle aliasing empirically
- **M3** mount alignment, ESKF attitude, bias estimation, grade baseline
- **M4** event segmentation and scoring, checked against video
- **M5** live cue engine (time-to-threshold tone) + background audio session

Instrument first, feature last.

### What the beta actually built (differs from M3/M5 above)

The gated **ESKF attitude filter, the RTS smoother, the delayed-state GNSS
correction, the grade baseline, and the standalone cue engine were removed.** The
live estimator is now `CalibrateOnceEstimator`: measure a constant gyro bias once at
launch, then integrate **raw gyro only** (`rate = rawGyro − b`; `Q = Q·exp(rate·dt)`;
`pitch = asin` of the rotated forward axis). The accelerometer is calibration-only —
it anchors gravity and detects rest, and is recorded to disk, but never feeds the
live angle. Post-run smoothing is a zero-phase display/scoring blur (`JitterBlur`),
not RTS. Mount alignment is a **one-gesture** swipe (M3 planned a two-gesture solve).
The cue's angle→tone transfer curve now lives in `Config` (v7) and is rendered by
`CueAudioRenderer` rather than a separate cue engine. `motolog` ships two subcommands,
`synth` and `replay` — the M2 FFT tool was not built as a subcommand.

## Next steps after running the scaffold (ORIGINAL bootstrap notes)

> Historical M0 bootstrap steps. The app target, logger, and replay CLI now exist;
> these are kept because the environment setup (Info.plist keys, background modes)
> is still accurate for a fresh clone.

1. `swift test` — should pass.
2. `swift run motolog synth` — runs the synthetic scenario end to end.
3. In Xcode: **File > New > Project > iOS App**, name it `MotoTelemetryApp`,
   put it in this repo, then **File > Add Package Dependencies > Add Local**
   and point at this directory. Add `MotoTelemetryCore` to the app target.
4. In the app's Info.plist add `UIBackgroundModes` = `audio`, `location`, plus
   usage strings for motion, location and microphone. CoreMotion stops in the
   background unless a location or audio session is live.
5. Build the logger (M1) before anything else. Raw, unfiltered, max rate,
   monotonic timestamps, mic recorded alongside for video cross-correlation.

## Calibration screens (two, not one)

- **Bias zero, every session.** Stationary, level, engine idling or off, 2 s
  (`Config.biasCalibrationDuration`; was 8 s in the scaffold). Wants the *least*
  vibration available — revving here hurts.
- **Vibration profile, once per bike.** Stationary, sweep idle to redline, to
  find where engine excitation aliases and the phantom tilt offset per RPM.

Bias goes stale as the phone self-heats (~0.1 deg/s over 30 min, which is a
whole degree over a 10 s hold), so surface bias age and degrade the reported
confidence with it. Every traffic light is a free re-zero.
