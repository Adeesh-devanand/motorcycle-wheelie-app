# Live-device log audit — session handoff

**Written:** 2026-08-28 ~01:20 EDT, on branch `audit/live-log-2026-08-28`.
**Purpose:** this file is the complete prompt + context for a NEW KiroCrew session to
continue. It assumes you have the repo and nothing else. Everything referenced here is
committed in this repo — no `/tmp`, no `~/.kiro`, no prior chat needed.

---

## 0. Read this first — the one-paragraph state of the world

We got the first full diagnostic log off Adeesh's iPhone (3m17s run, 2026-08-28 00:49:47).
The logging subsystem built in the previous session **works and is on the device**. Reading
it overturned several things earlier sessions recorded as "fixed": the app is in an
**infinite re-calibration loop**, it reported a **phantom constant −27.87° while sitting
still**, **3 of 6 sensor sessions emitted zero samples**, and **89% of the log is one
repeated line**. Adeesh has confirmed two of these by eye ("I still see the flickering
calibration screen", "too many logs flooding in"). Nothing has been fixed yet in this
audit — **this branch contains diagnosis and evidence only, plus all the previously
uncommitted work from three earlier sessions**. Your job is to fix the bug list in §4.

**Highest-value single insight:** the infinite calibration loop was *masking* the phantom
angle. Every spurious re-calibration fired a re-anchor that reset the bad angle back to
~0. If you fix the loop first and ship that alone, the phantom angle stops being
self-correcting and the app gets **worse** on device. Fix the anchor validity (§4, bug 3)
in the same change set as the loop (bug 1).

**Update — root causes are CONFIRMED, not hypothesised.** Five parallel code
investigations ran before this handoff was written. Their full reports are committed under
`docs/audit/investigations/` (758 lines). Read those before writing any code: they carry
exact line numbers and proposed diffs for bugs 1, 3, 4, 6, 7, 8 and 11. Two of the five
were cut off mid-write, so §8 lists precisely which questions remain open. The confirmed
mechanisms are summarised in §3.10.

---

## 1. The evidence, and how to regenerate it

Committed under `docs/device-logs/`:

| File | Lines | What it is |
| --- | --- | --- |
| `2026-08-28T0049-run-console-full.txt` | 31,907 | Complete raw console archive, incl. OS noise |
| `2026-08-28T0049-signal-only.txt` | 1,763 | **Read this one.** App lines with the two spam sources stripped |
| `2026-08-28T0049-calibration-sequence.txt` | 58 | The calibration state machine, start to finish |
| `2026-08-28T0049-session-lifecycle.txt` | 195 | Session/stream start-stop, events, saves |
| `extract-xcresult-log.sh` | — | Regenerates all of the above from any `.xcresult` |

The signal-only file is 1,763 lines out of 15,952 app lines. That ratio **is** bug 6.

To capture a fresh log after a device run:

```bash
# Xcode writes run logs here:
ls ~/Library/Developer/Xcode/DerivedData/MotoTelemetryApp-*/Logs/Launch/
./docs/device-logs/extract-xcresult-log.sh <path-to-.xcresult> /tmp/newlog
```

Verified on Xcode 15.2 (15C500b). Newer `xcresulttool` deprecates `get --format json` in
favour of `get log`; the script has a comment marking where to adapt.

---

## 2. Assumed fixed vs. actual live behaviour

This is what Adeesh asked for. Left column is what earlier sessions recorded as done.

| Earlier claim | Actual device behaviour | Verdict |
| --- | --- | --- |
| Calibration fix complete — vibration block removed, duration-confirmation gate, sigma limit raised to 0.05, retry throttled | Calibration **succeeds** (sigma 0.0018 °/s, 28× margin) then **re-arms 9 ms later, forever**. `attempt` reached 4 and 5 against `maxAttempts=3` | ❌ **Worse than before.** The throttle turned a terminating failure into a non-terminating success loop |
| Dead-stream / frozen-angle fixed in `f51722b` via per-session `AsyncStream` recreation | Streams are recreated correctly, but **3 of 6 sessions emitted 0 samples** — every sample discarded as "unpaired" upstream | ❌ Fixed the wrong layer. Stream lifecycle is fine; accel/gyro pairing is the fault |
| Gravity-derived mount alignment + ESKF self-anchor replaces guessed constants | Anchor is taken with **no validity test**. One anchor captured at a 29° tilt → constant **−27.87°** reported for 12 s | ❌ Replaced a guessed constant with an unvalidated measurement |
| Paused-time exclusion — "8 s means 8 s of real samples" | Covers explicit *pause* only. A **19 s dead-stream gap** let the sample clock jump and the estimator "finished" on **25 samples** | ⚠️ Incomplete — right idea, wrong set of causes |
| Logging obeys transition + 1 Hz heartbeat, sink coalesces above 20/s | Heartbeats are **perfect** (109 lines / 197 s each). Two lines bypass it entirely: 10,480 at 100/s and 3,698 at ~25/s | ⚠️ Rule works where applied; two callers skip it |
| Watchdog hardened with `hasSeenSample` guard | Fired twice and told the user **"motion sensors unavailable"** while CoreMotion was delivering ~100 samples/s | ❌ Correct trigger, wrong conclusion |
| `CalibrationService` race fixed with `NSLock` + generation | No race observed in the log. Generation tracking works (`estimatorGen` mismatch handled cleanly) | ✅ Holding up |
| Chart time-origin fix (window samples to `[onset,end]`, re-base elapsed) | Confirmed working: `windowed=846 collected=3153`, `windowed=637 collected=871`, `windowed=922 collected=2120` | ✅ Confirmed on device |
| Event segmenter, 10°/7° thresholds, audio cue driven by angle alone | 3 events detected and saved cleanly (65.7°/8.5 s, 48.5°/6.4 s, 50.4°/9.2 s). Audio tracked angle monotonically with no rate dependence | ✅ Confirmed on device |

**The recurring pattern, third session running:** a component works correctly against a
premise that stopped being true. Here the premise was *"a successful measurement is
terminal"* (it re-arms), *"the sample clock advances only when samples arrive"* (a dead
stream breaks it), and *"any gravity reading defines level"* (only a quiescent one does).

---

## 3. Verbatim evidence for each finding

Keep these. Every claim below is a direct quote from the committed log, so you can
re-derive it without trusting this document.

### 3.1 Infinite calibration loop → the flicker Adeesh sees

```
00:50:20.758597 [cal] state calibrating -> calibrating [auto-start attempt 1] attempt=1 maxAttempts=3
00:50:29.251230 [cal] state calibrating -> calibrated  [estimator done] sigmaDeg=0.00187
00:50:29.260749 [cal] state calibrated  -> calibrating [auto-start attempt 2] attempt=2 maxAttempts=3   ← 9 ms after success
00:50:37.763223 [cal] state calibrated  -> calibrated  [estimator done] sigmaDeg=0.00180
00:50:37.773222 [cal] state calibrated  -> calibrating [auto-start attempt 3] attempt=3 maxAttempts=3
00:50:46.276701 [cal] state calibrated  -> calibrated  [estimator done] sigmaDeg=0.00184
00:50:47.775932 [cal] state calibrated  -> calibrating [auto-start attempt 4] attempt=4 maxAttempts=3   ← exceeds the cap
00:50:56.278476 [cal] state calibrated  -> calibrated  [estimator done] sigmaDeg=0.00185
00:50:57.778899 [cal] state calibrated  -> calibrating [auto-start attempt 5] attempt=5 maxAttempts=3
```

First two `autostart status` lines — note `hasEstimator=0 → canAutoStart=1`:

```
attempts=0 recalRequested=0 hasEstimator=0 canAutoStart=1 cooldownRemaining=0
attempts=1 recalRequested=0 hasEstimator=1 canAutoStart=0 cooldownRemaining=1.98999
```

**CONFIRMED root cause** (investigation 02): in `CalibrationService.feedIMU`, after the
estimator reports `.done` the service sets `estimator = nil`, and `canAutoStart` is
**purely a cooldown check that never consults the calibrated state**. So "no estimator
exists" becomes true again the instant a calibration succeeds, the cooldown expires a
moment later, and auto-start re-fires. The `attempts < maxAttempts` cap guards only the
*failure* path, which is why `attempt` sails past 3 to 4 and 5. This also explains why
Adeesh's **manual recalibrate button works fine** — it goes through the explicit
recalibration path, which resets generation and attempts properly.

Note: report 02 was cut off just after stating the root cause, so its *proposed patch* is
missing. The fix direction is unambiguous though: make `canAutoStart` false when the
current state is `.calibrated` and the bias is fresh, and latch until user request, stale
bias (`biasStaleAfter=300`), or genuine sensor loss.

The bias measured essentially identically every single time
(`meanBiasX≈−0.097`, `meanBiasY≈0.013`, `meanBiasZ≈0.111`), so 6 of the 7 re-anchors it
triggered changed nothing but visibly reset the rider's angle.

### 3.2 Zero-sample sessions

`unpaired` = MotionService's cumulative count at stop; `emitted` = samples reaching the stream.

```
gen1  00:49:58→00:50:07   unpaired=1839   emitted=0      BROKEN
gen2  00:50:08→00:50:20   unpaired=4105   emitted=0      BROKEN
gen3  00:50:20→00:51:04   unpaired=4107   emitted=4352   ok (~99 Hz)
gen4  00:51:06→00:51:16   unpaired=6012   emitted=0      BROKEN
gen5  00:51:16→00:51:58   unpaired=6014   emitted=4133   ok
gen6  00:52:17→00:52:40   unpaired=6014   emitted=2291   ok
```

All six logged `MotionService started at 100.000000 Hz` with
`deviceMotionAvail=1 accelAvail=1 gyroAvail=1`. `[sensor] first sample` appeared **only**
for gen 3/5/6, each time 6–7 ms after stream creation — so pairing either works instantly
or never recovers for the whole session. `unpaired` is cumulative and never reset per
session, which makes the diagnostic itself misleading.

### 3.3 Phantom angle — the anchor was captured mid-tilt

Every healthy anchor (phone flat, gravity almost entirely on −Z):

```
gravityX=0.128  gravityY=-0.313  gravityZ=-9.825  gravityMag=9.831
upZ=0.9994  upY=0.032  forwardY=0.9995  forwardZ=-0.032
```

The one bad anchor, 27 ms after a stream restart at `00:51:16.838`:

```
gravityX=0.952  gravityY=-4.805  gravityZ=-8.507  gravityMag=9.817
upX=-0.097  upY=0.4895  upZ=0.8666  forwardY=0.8707  forwardZ=-0.4918
```

`asin(4.805 / 9.817) = 29.3°`. That tilted pose became the definition of level:

```
00:51:26.816 [rec] rec heartbeat pitchDeg=-27.8656
00:51:27.813 [rec] rec heartbeat pitchDeg=-27.8737
00:51:28.814 [rec] rec heartbeat pitchDeg=-27.8636
00:51:28.843 [eskf] requestReanchor pitchDeg=-27.8706   ← rescued only by the bug-1 loop
00:51:29.813 [rec] rec heartbeat pitchDeg=-0.0252
```

Also, attitude is published **before** an anchor exists:

```
00:51:16.811 [sensor] first sample generation=5
00:51:16.822 [eskf] heartbeat pitchDeg=-89.7183   ← published to the pipeline
00:51:16.838 [eskf] anchor acquired               ← 16 ms LATER
```

### 3.4 Unobservable yaw-bias runaway

Phone motionless on a desk; the ESKF's Z (yaw) gyro-bias state climbed monotonically:

```
00:50:49 biasZ=4.2349   00:50:51 4.4747   00:50:55 4.7032
00:50:58 4.9495         00:51:00 4.9679   00:51:03 5.0547   (°/s)
```

Measured truth was `meanBiasZ = 0.111 °/s` — the filter is ~45× off and still climbing.
X and Y stayed sane (−0.149, +0.167) because gravity observes them; yaw is structurally
unobservable from an accelerometer alone. **Before spending effort here, prove from the
code whether a runaway bias-Z can leak into reported pitch through quaternion coupling.**
If it cannot, this is cosmetic and low priority. That determination decides its rank.

### 3.5 Bias estimator finished on 25 samples

Healthy finishes were all `n=801` (8 s at 100 Hz), `sem ≈ 0.0018`. This one wasn't:

```
00:51:58.138 [rec] consuming Tasks cancelled — sensor streams die here   (left the Live tab)
             ... 19 seconds, no samples at all ...
00:52:17.309 [sensor] first sample generation=6
00:52:17.356 [bias] bias finish n=25.0 sqrtN=5.0 semY=0.08001 rawStdY=0.4000
00:52:17.356 [bias] bias failed sigmaTooHigh sigmaDegPerSec=0.08001 limitDegPerSec=0.05 axis=1
00:52:17.357 [CalibrationService] Calibration failed: Gyro Y axis too noisy: 0.0800 deg/s. Hold the bike still.
```

The sample timestamp jumped 19 s, instantly satisfying the 8-second duration requirement
on 25 real samples. The user got a false "Hold the bike still."

### 3.6 Log volume

15,952 app lines in 197 s. By category:

```
[cal] 14,217   ← 10,480 are ONE line ('autostart status'), 3,698 are 'gate reason X -> Y'
[gate] 557  [sensor] 270  [rec] 157  [live] 157  [eskf] 126  [grade] 119  [pipe] 109  [bias] 82
```

`autostart status` rate per wall-clock second: `26, 100, 100, 100, 100, 99, 100, 100, …`
— once per IMU sample, sustained. The heartbeat categories are all exactly right at
109 lines / 197 s, which proves the 1 Hz rule works where it is applied.

**Do not gut the instrument.** The heartbeats and lifecycle lines are what made this entire
audit possible. Cut the two offenders; keep the rest.

### 3.7 Three ServiceGraphs, three GPS sessions

```
00:49:58.450 [app] ServiceGraph constructed      (launch)
00:51:48.389 [app] ServiceGraph constructed      ← at the exact moment a run was SAVED
00:51:48.439 [app] ServiceGraph constructed      ← again, 50 ms later
```

`[SpeedService] SpeedService started` appears **9** times vs `[sensor] speed stream created`
**6** times, and `Location authorized — starting updates` **3** times (once per graph) —
so three `SpeedService` instances were running `bestForNavigation` GPS simultaneously.
A new graph logged `first GNSS fix generation=0.0` at `00:51:48.445` while the original was
still on generation 5. `RunRepository` also loads twice at launch and twice on save.

### 3.8 False "motion sensors unavailable"

```
00:49:58.884 [rec] watchdog armed (2×2.5s)
00:50:03.995 [rec] watchdog FIRED — reporting sensors unavailable sampleCount=0.0
00:50:03.996 [CalibrationService] Motion sensors unavailable: no IMU samples 5 s after starting motion updates
```

Fired again at `00:50:14.010`. The sensors were fine — 1,839 samples arrived in that window
and were all discarded as unpaired (bug 2). The watchdog measures *emitted* samples and
concludes *hardware failure*; it cannot tell "CoreMotion is dead" from "our pipeline drops
everything".

### 3.9 Threshold thrash — Adeesh's explicit directive

Live values from the log:

```
gateSpecificForceLow=9.5124505   gateSpecificForceHigh=10.1008495    (9.8066 ± 0.294 = ±0.03 g)
gateMaxRotationRate=3.0          gateDwell=0.5   gateCloseConfirm=0.06
```

3,698 gate-reason transitions in 197 s (~25/s): `rotating` 1429, `dwellNotMet` 1336,
`specificForceOutOfBand` 933 — **on a desk**. A ±0.03 g band will essentially never be
satisfied with an engine running. Meanwhile accuracy has 28× margin (`sem 0.0018` vs a
`0.05` limit).

Adeesh's instruction, verbatim: *"A lot of thresholds like the rotating threshold don't
really affect the angle too much, they can be increased to a much higher threshold."*

He is right, but be precise rather than uniform: a gyro-bias estimate is an 8-second
**mean**, so widening an accel-based stillness *proxy* barely moves it, whereas the
rotation-rate limit bounds real rotation during that mean and matters more directly.
**First confirm the units of `gateMaxRotationRate=3.0` from the code** (°/s or rad/s) — with
a still phone the log shows `rotX=-0.070 rotY=-0.031 rotZ=0.213`, which should settle it.
Getting this wrong makes every recommendation meaningless. Produce an old-vs-new table with
the angle impact of each threshold quantified in numbers, not adjectives.

---

## 3.10 Confirmed root causes — read the full reports before coding

Five parallel read-only investigations produced these. **Full text, with exact line numbers
and proposed diffs, is committed under `docs/audit/investigations/`.** Do not re-derive
them; read them.

| Report | Bug | Confirmed mechanism |
| --- | --- | --- |
| `01-motionservice-pairing-and-servicegraph.md` (223 ln) | 4 | `stop()` never clears `pendingGyro` / `pendingAccel` / `latestAttitude` / `unpairedCount`. A half-sample left stashed puts the next `start()` into an overwrite phase relation that timestamp-pairing **never self-heals from**, so the whole session emits zero. Patch: clear the stash in `stop()` under the existing lock, **and** evict an opposite-channel stash older than `pairTolerance` so a bad phase relation cannot live-lock. Risk: low |
| `01-…` (same report) | 8 | `RootTabView.swift:21` is `@State private var services = ServiceGraph()`. The `@State` **default-value autoclosure re-runs `ServiceGraph()` on every `RootTabView.init`**. SwiftUI keeps only the first instance but the throwaways are *fully constructed first*, and `ServiceGraph.init` eagerly starts `SpeedService` location authorization — so the side effects fire before the object is discarded. Twice at launch (identity pass + first body pass); twice more on save, because saving mutates the observable `RunRepository` that `RootTabView.body` depends on, invalidating the view and re-running `init`. Patch: move ownership to `WheelieTrackerApp` (instantiated once) and inject as a **plain `let`** — wrapping it in `@State` again reintroduces the trap. **Bonus:** this also fixes a latent split-brain where the environment's `CalibrationService` / `RunRepository` were *different objects* from the ones inside `ServiceGraph` |
| `02-calibrationservice-autostart-loop.md` (4 ln, **truncated**) | 1 | `estimator = nil` after `.done`, and `canAutoStart` is a pure cooldown check that ignores the calibrated state. See §3.1. Patch missing — report was cut off |
| `03-eskf-anchor-and-yaw-bias.md` (212 ln) | 3 | `AttitudeESKF.propagate` lines 168–198 accept the anchor on **specific-force magnitude alone**. Magnitude is **orientation-invariant at rest** — it is `g` at *every* orientation — so a magnitude test is structurally incapable of rejecting a tilt. The 29.3° pose had `gravityMag=9.817`, squarely in band, so it passed. The real `ValidityGate` (which does test rotation rate and dwell) is **never consulted on this path**; the estimator reimplements a weaker magnitude-only check. Patch: thread the gate `Verdict` (already computed upstream) into `propagate`, anchor only when the gate is `.open` **and** the pose is near-level — `f_z/|f| ≥ cos(20°) ≈ 0.94`, which rejects the 29° pose (`8.507/9.817 = 0.867`) while tolerating a generous cradle angle. Adds one deliberately loose predicate; tightens nothing |
| `04-calibration-sample-count-and-gate-thresholds.md` (272 ln) | 6, 7 | The 19 s-gap short finish, plus a **quantified** old-vs-new threshold table (see §3.9 update below). Confirms `gateMaxRotationRate` is stored in **rad/s** (`3.0 * .pi/180`) and displayed as deg/s. Also answers whether `resetAccumulation()` can still wipe 8 s on one out-of-band sample |
| `05-log-volume-and-watchdog.md` (47 ln, **truncated**) | 2 | The sink's coalescer *is* per-key on `category+"|"+message` with a 0.05 s (20/s) window at `DiagnosticLog.swift:128–134`. The **caller** defeats the emitter's own transition check: `CalibrationService.feedIMU:~264` passes a discriminator key embedding `estimator == nil`, which flips constantly during the auto-start churn. Confirms there is **no separate `*logging-contract*` file** — the contract is inline in `Diagnostics.swift`. The report stalled unresolved on why 53/s got past a 20/s coalescer; **answered in §3.12** |

### §3.12 The 53/s-vs-20/s puzzle, resolved — bug 2 is THREE layers

Report 05 stopped while circling this. Resolved by reading `DiagnosticLog.emit()`:

```swift
116  func emit(_ event: DiagnosticEvent) {
117      let line = encode(event)
120      if event.level.osLogEligible {
121          mirror(event)          // ← OSLog mirror, BEFORE any coalescing
122      }
125      bufferLock.lock()
127      let key = event.category + "|" + event.message
128      if let last = lastEmitByKey[key], event.time - last < coalesceWindow, … {
130          droppedCount += 1
132          return                 // ← only the ON-DISK buffer is protected
```

**The OSLog mirror at line 121 runs before the coalescing return at line 132.** The on-disk
NDJSON is correctly coalesced to 20/s; every `.info`-and-above event reaches the Xcode
console unthrottled. **The log committed under `docs/device-logs/` is the OSLog stream**,
which is why it measures ~100/s against a coalescer that is working. The two numbers were
never in conflict — they are two different sinks.

So the flood has three layers:

1. **Caller** — the oscillating `estimator == nil` discriminator key defeats the emitter's
   transition check, so it fires on most samples.
2. **OSLog mirror** — unguarded by the coalescer, so console volume equals raw emitter rate.
3. **The churn itself** — bug 1 is what makes that key flip.

**Fix bug 1 first; all three collapse together.** Then take a fresh log and decide whether
layers 1 and 2 still need work. Moving `mirror(event)` below the coalescing check is a
one-line candidate for layer 2, but not blind: `.warn`/`.error` are deliberately exempt from
coalescing and the mirror must keep receiving them.

**Not verified:** the ordering is unambiguous in source, but nobody has re-run the app to
confirm the on-disk NDJSON is at 20/s while the console is at 100/s. Prove it from a fresh
log before declaring the disk sink healthy.

### §3.9 update — the quantified threshold answer

Report 04 delivers what was asked, and it **partly disagrees with a blanket "raise
everything"**, with a reason worth respecting:

| Threshold | Old | Proposed | Why |
| --- | --- | --- | --- |
| `gateSpecificForceLow` | 0.97 g (−0.03 g) | **0.90 g (−0.10 g)** | ~0 effect on the bias mean — it is an accel-based stillness *proxy* and never enters the gyro mean. Degradation < 0.001 °/s |
| `gateSpecificForceHigh` | 1.03 g (+0.03 g) | **1.10 g (+0.10 g)** | Same. +0.10 g ⇒ ~24° lean edge before the accel test fires; the rotation limit fires first for anything genuinely rotating |
| `gateMaxRotationRate` | 3.0 °/s | **5.0 °/s only** | **This one genuinely matters** — a DC rotation admitted here enters the 8-second mean *directly*. 3→5 widens the admit window ~1.7× and cuts `rotating` flaps, with the sigma gate (0.05 °/s) still backstopping. Report is explicit: **do not raise this to double digits** |
| `gateDwell` | 0.5 s | unchanged | Lowering admits sooner with no accuracy benefit |
| `gateCloseConfirm` | 0.06 s | unchanged, or 0.08 s | Already does the engine-buzz rejection; 80 ms would cut more flaps with no mean impact. Optional |

So: the specific-force band can open up **3.3×** exactly as Adeesh expected, but the
rotation-rate ceiling is the one threshold where "much higher" would cost real accuracy.
Flag that trade-off to him rather than silently capping it at 5.

---

## 3.11 CRITICAL — the log is older than the source for two files

**Read this before acting on any log evidence.** The device run was **00:49:47**. Two source
files were edited *after* it, so the logged binary does not contain their current code:

| File | mtime | In the logged build? |
| --- | --- | --- |
| `Core/Calibration.swift` | 00:59:21 | ❌ **stale — log predates it** |
| `Core/AttitudeESKF.swift` | 00:59:56 | ❌ **stale — log predates it** |
| `Core/Config.swift` | 00:27:45 | ✅ |
| `Core/ValidityGate.swift` | 00:29:45 | ✅ |
| `Core/MountAlignment.swift` | 08-26 13:45 | ✅ |
| `Services/CalibrationService.swift` | 00:38:01 | ✅ |
| `Services/MotionService.swift` | 08-27 23:39 | ✅ |
| `Services/RunRecorder.swift` | 08-27 23:38 | ✅ |
| `App/RootTabView.swift` | 08-27 23:29 | ✅ |
| `App/WheelieTrackerApp.swift` | 08-27 23:30 | ✅ |
| `Services/Diagnostics/DiagnosticLog.swift` | 08-27 23:46 | ✅ |

The `.app` bundle was rebuilt at 01:06:36, also after the run — so **the phone may already
be running code newer than this log describes.** Get a fresh log before trusting any
symptom to still be present.

### Consequence 1 — bug 6 (25-sample finish) is ALREADY FIXED. Do not re-fix it.

`Calibration.swift:335–337` now carries a sample-count floor:

```swift
let requiredSamples = Int(config.biasCalibrationDuration
                          * config.nominalSampleRate * 0.5)     // 8 * 100 * 0.5 = 400
guard elapsed >= config.biasCalibrationDuration, n >= requiredSamples else { … }
```

`finish(at:)` has exactly **one** call site (line 354) and it sits behind that guard, so
`n=25` can no longer reach it — `25 < 400`. Report 04 flagged the contradiction; the
mtimes resolve it. **Verified separately:** the paused-time exclusion was never the hole.
It caps each credited interval at `nominalInterval * 3` (30 ms) and nils
`lastAccumulateTime` on every non-accumulating path, so the 19 s gap was credited as ~0 ms
all along. The duration axis was always sound; the missing guard was the *count* axis.

What remains from report 04 is smaller: a stream-discontinuity reset, so an accumulator
already sitting near 8 s cannot pool pre-gap samples with post-restart ones across a dead
stream. Report 04 proposes a 300 ms gap threshold. That is a real but narrow hardening,
not the bug the log showed.

**Also verified against current code:** `resetAccumulation()` can *not* be triggered by a
single out-of-band sample. Three independent mechanisms prevent it — `gateCloseConfirm`
(60 ms) keeps the gate open through a one-sample violation; the reset needs
`n > 0 && sample.time - violatedSince >= biasGateGracePeriod` (250 ms); and an
out-of-band-but-gate-open sample takes the `sampleWithinBand` path, which is a one-sample
*pause*, not a reset. The prior session's claim holds. The only immediate reset is
`.saturated`, which is intentional and correct.

### Consequence 2 — bug 3 and bug 10 ARE still live, despite the stale file

`AttitudeESKF.swift` is stale relative to the log, but investigation 03 read the **current**
source and found the magnitude-only anchor test still present at lines 168–198, and the
unbounded bias-Z still there. So both survive the 00:59 edit and remain real. Where an
agent reading current source agrees with the log, the bug is live; where it disagrees
(bug 6), the log is history.

### Consequence 3 — bug 10 is NOT cosmetic. It was going to be dropped; it should not be.

Investigation 03 answered the question that decided its rank, and the answer is worse than
expected. Bias-Z corrupts `corrected = sample.rotationRate - bias` (line 227), which
integrates into attitude (line 231). At *exactly* level, a bias-Z error is pure yaw and
rotates `forward` **within** the horizontal plane, so pitch — the elevation of `forward`
above horizontal — is untouched, and the leak is zero. **But once the phone tilts, body-Z
is no longer world-vertical**, so rotation about body-Z acquires a component that does move
`forward`'s elevation. The leak is proportional to `sin(tilt)`: negligible near level and
**growing precisely in the wheelie regime**. Between anchors an unbounded, monotonically
climbing bias-Z is an unbounded pitch-error source during the exact event being measured.

Fix is still one line: yaw bias is unobservable from gravity, so stop estimating it and
hold the calibrated value by zeroing the Z row of the bias-error Kalman gain in both update
paths. **Verify `Matrix3.setRow` actually exists before writing it** — report 03 flags this
as unconfirmed against the linear-algebra API; in `applyScalarUpdate` `k2` is a `Vector3`,
so `k2.z = 0` is exact and trivial there.

---

---

## 4. The task list, in the order to do it

Ordered by user-visible value ÷ risk. Bugs 1 and 3 **ship together** (see §0).
"Patch ready" = a concrete diff exists in `docs/audit/investigations/`.

| # | Bug | Where | Priority |
| --- | --- | --- | --- |
| 1 | Infinite calibration auto-start loop → flickering screen. Latch `.calibrated` on success; only re-arm on user request, stale bias (`biasStaleAfter=300`), or genuine sensor loss. Make the cap bound the success path too | `Services/CalibrationService.swift` | **P0** — user-confirmed |
| 2 | Log flood: 10,480 lines from one caller. Fix at the **caller** (transition + ≤1 Hz); leave the sink's coalescer as a backstop. Collapse `gate reason` thrash to a 1 Hz summary carrying the transition count + dominant reason | `Services/CalibrationService.swift`, `Services/Diagnostics/DiagnosticLog.swift`, `Core/Diagnostics.swift` | **P0** — user-confirmed |
| 3 | Anchor accepted while tilted 29° → phantom −27.87°. Require quiescent **and** near-level before accepting. Reuse the existing `ValidityGate` rather than inventing a second test. Publish **nothing** before a valid anchor exists | `Core/AttitudeESKF.swift`, `Core/MountAlignment.swift` | **P0** — ship with #1 |
| 4 | 3 of 6 sessions emit zero samples (accel/gyro pairing dies across restart). Also reset the `unpaired` counter per session | `Services/MotionService.swift` | **P1** |
| 5 | Re-anchor fires on every adopted calibration even when the bias is unchanged, resetting the rider's angle. Gate on a material-change threshold | `Services/CalibrationService.swift`, `Services/RunRecorder.swift` | **P1** — falls out of #1 |
| 6 | ~~Bias estimator finishes on 25 samples~~ — **ALREADY FIXED in source**, see §3.11. The `n >= 400` floor exists; the log predates it. Remaining: a 300 ms stream-discontinuity reset so an accumulator near 8 s can't pool across a dead stream | `Core/Calibration.swift` | ~~P1~~ **done**; narrow hardening left |
| 7 | Loosen gate thresholds per §3.9. Specific-force band 3.3× wider is free; rotation rate 3→5 °/s only — **put that trade-off to Adeesh** | `Core/Config.swift`, `Core/ValidityGate.swift` | **P1** — patch ready |
| 8 | ServiceGraph constructed 3× — saving a run rebuilds every service, leaving 3 GPS sessions live | `App/WheelieTrackerApp.swift`, `App/RootTabView.swift` | **P1** — battery |
| 9 | Watchdog reports "sensors unavailable" when the real fault is "samples arrive but none emitted". Give it a raw-callback count alongside the emitted count; reconsider a hard error at 5 s | `Services/RunRecorder.swift` (watchdog only) | **P2** |
| 10 | Yaw-bias runaway to 5 °/s vs a measured 0.111. **Promoted from "maybe drop" — the pitch leak is PROVEN** (§3.11, consequence 3): zero at exactly level, but grows as `sin(tilt)`, i.e. worst during the wheelie being measured. One-line fix: stop estimating the unobservable Z bias, hold the calibrated value | `Core/AttitudeESKF.swift` | **P1** — patch ready |
| 11 | `RawSampleRecorder` has no size cap and defaults ON: `rawLogBytes=1,579,503` in a 44 s session ≈ 129 MB/hour. `DiagnosticLog` reportedly prunes to 5 files — verify both claims | `Services/Diagnostics/RawSampleRecorder.swift` | **P2** |
| 12 | `UIBackgroundModes=audio` still unset in `Info.plist`. Without it the audio cue dies when the screen locks, which is most of a ride — one line, and it makes the existing audio work usable | `MotoTelemetryApp/.../Info.plist` | **P2**, trivial |

Carried over, not from this log: empty Run Details timeline (`angleIntervals`/`speedIntervals`
are `compactMap { _ in nil }`, the `IntervalDetector` bridge was never built); personal
bests ignore `QualityFlags.isTrustworthy`; old saved runs have wrong chart timestamps;
`precondition` in `LinearAlgebra.swift` traps in release.

---

## 5. Standing directives from Adeesh — follow these

- **Minimal fixes. No redesigns, no new abstractions.** Verbatim: *"Optimize and minimalize it."*
- **Raise thresholds** where they don't materially affect the angle (§3.9).
- **Don't ask permission for work already sequenced.** He has pushed back on this
  specifically. If he has said "do X then Y", do both. Reserve options menus for genuine
  forks. If a dependency blocks you, say so and resume when it clears.
- **Read real signatures before writing code.** A prior session burned time fixing one
  compile error at a time by guessing APIs from names.
- **Read a test's fixture before trusting its assertion.** A previous vibration test
  asserted a failure its own fixture could not produce (vibration was added only to
  `specificForce`, never to the gyro whose mean is the bias). Reverting against that test
  propagated a false premise for a whole session.
- **Audio cue is a function of angle alone**, never rate of change.
- Angle and speed target ranges are **individually** editable — one control edits one value.

---

## 6. Build and verify — including the traps

**Environment:** Xcode 15.2 (15C500b), Swift tools 5.9 (deliberately downgraded from 6.0
for this Xcode). 29 core source files, 50 app source files, 24 core test files.

```bash
# Core tests. The --disable-sandbox is REQUIRED in an agent shell.
swift test --disable-sandbox
```

**Trap:** an agent shell cannot create nested sandboxes, so SwiftPM steps that sandbox a
subprocess fail with `sandbox-exec: sandbox_apply: Operation not permitted`. Hence
`--disable-sandbox`. CLI `xcodebuild` fails at manifest loading with no equivalent flag —
**this is an agent-shell limitation only; Adeesh's Xcode GUI builds fine.** Never tell him
"xcodebuild is broken".

**The app target is invisible to SwiftPM.** `Sources/MotoTelemetryApp` is outside every
SwiftPM target, so `swift build` / `swift test` never compile it. This is precisely why the
data-correctness bugs in §2 survived. To typecheck the app yourself:

```bash
xcrun --sdk iphoneos swiftc -typecheck \
  -load-plugin-path "$(xcrun --find swift | xargs dirname)/../lib/swift/host/plugins" \
  $(find Sources/MotoTelemetryApp -name '*.swift')
# Strip #Preview blocks first — PreviewsMacros.dylib has an ABI mismatch on this machine
# (it works in Xcode).
```

**Before claiming done:** run `AccuracyMatrixTests` explicitly. It was left unrun after the
last gate change on Adeesh's instruction, and it is the test that caught the phantom-angle
regression — it covers live-angle accuracy during a wheelie. `AllanDeviationTests` is slow
(synthesises 360k+100k sample series in a debug build); that is expected, not a hang.
`PurityTests` enforces that Core has zero platform dependencies — keep it green.

---

## 7. Repo state on this branch

Branch `audit/live-log-2026-08-28`, cut from `staging/core-pipeline` at `f51722b`.

This branch commits **three earlier sessions' worth of previously-uncommitted work**
alongside the audit evidence. That work compiles and 129 fast core tests were green, but
**none of it has been device-verified**:

- re-anchor fix, angle-only audio cue
- the entire Diagnostics/logging subsystem (`Features/Diagnostics/`, `Services/Diagnostics/`)
  — new, and the reason this audit was possible
- Past Runs delete (per-run + all) and the RECENT sort chip; `PastRunsViewModel` converted
  from a stale cached list to derived-on-read properties
- individually-editable angle/speed target ranges
- the calibration change set that **caused bug 1**: vibration block removed, duration-
  confirmation gate, grace period, paused-time exclusion, sigma limit 0.05, ESKF
  `dwellNotMet` band fix, retry throttle. `Config` bumped to **version 3**

Note: `UserInterfaceState.xcuserstate` is both listed in `.gitignore` and tracked in git
(it predates the ignore rule), so it shows as modified and is committed here. Worth
`git rm --cached`-ing at some point; not done, as it wasn't asked for.

---

## 8. What the investigations left open

All five investigations **ran** and their reports are committed under
`docs/audit/investigations/` — see §3.10 for the summary table. Start there, not from
scratch. Three finished; two were stopped mid-write when the laptop closed.

**Reports 01, 03 and 04 are complete.** Treat their diffs as ready to apply and review,
covering bugs 3, 4, 6, 7 and 8.

**Two gaps to close — these are the only investigations worth re-running:**

1. **Report 02 (`CalibrationService`, bug 1)** — stopped immediately after naming the root
   cause, so it has **no patch**. The mechanism is certain (`estimator = nil` after `.done`
   + `canAutoStart` ignoring the calibrated state), so you may not need a sub-agent at all;
   just write the latch. Still needed from it: the **material-change threshold for
   re-anchor** (bug 5), which was never answered. Measured bias was
   `meanBiasX ≈ −0.097`, `meanBiasY ≈ 0.013`, `meanBiasZ ≈ 0.111` on *every* run, so
   anything above a few thousandths of a °/s would have suppressed 6 of the 7 re-anchors.
2. **Report 05 (logging, bug 2)** — identified the caller-side defect
   (`CalibrationService.feedIMU:262` passing a discriminator key that encodes
   `estimator == nil`, which flips constantly) and the sink's per-key 20/s coalescer at
   `DiagnosticLog.swift:130–139`. **Unresolved:** 10,480 lines / 197 s ≈ 53/s still exceeds
   a 20/s per-key window, so there is likely a **second defect in the sink** that the report
   had not isolated. Also unanswered: the `RawSampleRecorder` size cap (bug 11) and the
   watchdog fix (bug 9). Note it confirmed there is **no separate `*logging-contract*`
   file** — the contract lives inline in `Diagnostics.swift`, so don't hunt for one.

Fixing bug 1's auto-start churn will itself collapse most of the log spam, since the
oscillating `estimator == nil` discriminator is what defeats the emitter's own key check.
**Do bug 1 first, re-measure the log, then decide how much of bug 2 is left.** That
ordering may save the entire logging change.

### Re-dispatch notes, if you do spawn agents

Use `spawn_run` with a `tasks` array. **Do not pass `cwd`** — it is rejected unless it sits
under `~/workspace`; put absolute paths in the prompt instead. Set `include_memory=false`
and `include_project=false` (write fully-specified prompts); keep `include_lessons=true`.
Each prompt must stay under **5,000 characters** or the whole batch is rejected. Scope
agents to **disjoint file sets** and keep them **read-only** returning text diffs —
`Config.swift` and `RunRecorder.swift` are each touched by two investigations, so
concurrent edits would collide. Apply patches yourself, in §4 order.

## 9. Definition of done

### Pending action: open a PR (requested, BLOCKED)

Adeesh asked for a **pull request rather than a bare push**. It could not be done from the
machine this audit ran on, and this is the first thing to resolve:

- `git push` fails. SSH authenticates as `cloudtrov`, the HTTPS keychain as
  `vinothini-raju`; **both get 403** on `Adeesh-devanand/motorcycle-wheelie-app`. No fork
  exists under either account. Read access works, which is why nothing surfaced this
  earlier — `staging/core-pipeline` had already been 3 commits ahead of origin for three
  sessions.
- `gh` CLI is **not installed** on that machine, so there was no PR path even with
  credentials.

To unblock, any one of:
1. Grant `vinothini-raju` (or `cloudtrov`) push access, then
   `git push -u origin audit/live-log-2026-08-28` and open the PR.
2. Fork to an account that can push, add it as a second remote, push the branch there and
   open a cross-fork PR into `Adeesh-devanand/motorcycle-wheelie-app`.
3. Import the offline bundle (below), then push from wherever it lands.

**Offline bundle:** `~/Documents/Adeesh/handoff/audit-live-log-2026-08-28.bundle`
(~841 KB, `git bundle verify` reports a complete history). Restore with:

```bash
git clone /path/to/audit-live-log-2026-08-28.bundle restored
# or into an existing clone:
git fetch /path/to/audit-live-log-2026-08-28.bundle audit/live-log-2026-08-28:audit/live-log-2026-08-28
```

Suggested PR title (under 70 chars):
`Live-device log audit: 10 confirmed bugs, evidence, and handoff`

The PR body should lead with §0 and §3.11 — the log-is-older-than-source caveat is the
thing a reviewer most needs to know, since it retired one bug outright.

### Actual definition of done

1. Bugs 1–3 fixed together, core tests green **including `AccuracyMatrixTests`**, app
   typecheck clean across all 50 files.
2. A fresh device log shows: calibration reaching `.calibrated` and **staying** there;
   no re-anchor without a material bias change; reported pitch ≈ 0 when the phone is level;
   every session emitting samples; total log volume down by roughly an order of magnitude
   with the heartbeats intact.
3. Bugs 4–8 fixed, same verification.
4. `git push` to a **feature branch** and open a PR. Never push to `main`/`master`.

The remote session has a longer budget than a local one — use it to actually run the
verification loop (fix → core tests → app typecheck → fresh device log → re-read) rather
than reasoning about what the fix probably does. That loop is what turned this session's
guesses into the confirmed list above. Do not expand scope beyond §4 to fill the time.
