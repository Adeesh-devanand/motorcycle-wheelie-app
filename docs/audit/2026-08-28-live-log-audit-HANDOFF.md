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

**Leading hypothesis (verify, don't assume):** on success the service consumes/nils the
estimator, so "no estimator exists" becomes true again and the auto-start predicate
re-fires. The `attempts < maxAttempts` cap evidently guards only the *failure* path.
Adeesh reports the **manual recalibrate button works fine** — find what the manual path
does that the auto path doesn't; that asymmetry is the shortest road to the bug.

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

## 4. The task list, in the order to do it

Ordered by user-visible value ÷ risk. Bugs 1 and 3 **ship together** (see §0).

| # | Bug | Where | Priority |
| --- | --- | --- | --- |
| 1 | Infinite calibration auto-start loop → flickering screen. Latch `.calibrated` on success; only re-arm on user request, stale bias (`biasStaleAfter=300`), or genuine sensor loss. Make the cap bound the success path too | `Services/CalibrationService.swift` | **P0** — user-confirmed |
| 2 | Log flood: 10,480 lines from one caller. Fix at the **caller** (transition + ≤1 Hz); leave the sink's coalescer as a backstop. Collapse `gate reason` thrash to a 1 Hz summary carrying the transition count + dominant reason | `Services/CalibrationService.swift`, `Services/Diagnostics/DiagnosticLog.swift`, `Core/Diagnostics.swift` | **P0** — user-confirmed |
| 3 | Anchor accepted while tilted 29° → phantom −27.87°. Require quiescent **and** near-level before accepting. Reuse the existing `ValidityGate` rather than inventing a second test. Publish **nothing** before a valid anchor exists | `Core/AttitudeESKF.swift`, `Core/MountAlignment.swift` | **P0** — ship with #1 |
| 4 | 3 of 6 sessions emit zero samples (accel/gyro pairing dies across restart). Also reset the `unpaired` counter per session | `Services/MotionService.swift` | **P1** |
| 5 | Re-anchor fires on every adopted calibration even when the bias is unchanged, resetting the rider's angle. Gate on a material-change threshold | `Services/CalibrationService.swift`, `Services/RunRecorder.swift` | **P1** — falls out of #1 |
| 6 | Bias estimator finishes on 25 samples after a stream gap. Require a minimum sample count derived from `duration × nominal rate` (don't hardcode 800), and/or treat a large inter-sample gap as a discontinuity | `Core/Calibration.swift`, `Core/Config.swift` | **P1** |
| 7 | Loosen gate thresholds per §3.9, with quantified justification per threshold | `Core/Config.swift`, `Core/ValidityGate.swift` | **P1** |
| 8 | ServiceGraph constructed 3× — saving a run rebuilds every service, leaving 3 GPS sessions live | `App/WheelieTrackerApp.swift`, `App/RootTabView.swift` | **P1** — battery |
| 9 | Watchdog reports "sensors unavailable" when the real fault is "samples arrive but none emitted". Give it a raw-callback count alongside the emitted count; reconsider a hard error at 5 s | `Services/RunRecorder.swift` (watchdog only) | **P2** |
| 10 | Yaw-bias runaway to 5 °/s. **Rank only after proving whether it leaks into pitch** (§3.4) | `Core/AttitudeESKF.swift` | **P2 or drop** |
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

## 8. Five investigation prompts — re-run these

Five read-only sub-agent investigations were dispatched and were still mid-flight when the
laptop closed; their partial output lived in `~/.kiro/crew/subagents/` on that machine and
**is not available to you**. The prompts are reproduced below so you can re-run them
cleanly. They are scoped to **disjoint file sets** so they can run in parallel without
conflicting, and all five are **read-only** — they return text diffs, they do not edit.
That was deliberate: `Config.swift` and `RunRecorder.swift` are each touched by two
investigations, so concurrent edits would collide. Apply the patches yourself afterwards,
in the §4 order.

Dispatch with `spawn_run` and a `tasks` array. **Do not pass `cwd`** — it is rejected
unless it sits under `~/workspace`; use absolute paths inside the prompt instead. Set
`include_memory=false` and `include_project=false` (the prompts are fully specified);
keep `include_lessons=true`.

1. **`MotionService.swift`, `WheelieTrackerApp.swift`, `RootTabView.swift`** — zero-sample
   sessions (§3.2) + 3× ServiceGraph (§3.7). Ask: what is the accel/gyro pairing key and
   tolerance; why instant success on gen 3/5/6 and never on 1/2/4 (look for state not
   cleared in `stop()`, a reused or cancelled `OperationQueue`, `start()` before the prior
   `stop()` drained, only one CoreMotion stream restarting); is `unpaired` reset per
   session; and for the graph, how it is held (`@State`/`@StateObject`/plain `let`) and why
   *saving a run* rebuilds it. If the code hand-pairs raw accel+gyro, require it to state
   what switching to `deviceMotion` would **lose** (raw uncorrected gyro for the bias
   calibrator) before recommending it.
2. **`CalibrationService.swift`** — the loop (§3.1). Give it the full state-transition
   quote, the `hasEstimator=0 → canAutoStart=1` hint, and the fact that the **manual button
   works while auto doesn't**; make it explain that asymmetry. Ask for the terminal-latch
   logic and the material-change re-anchor threshold.
3. **`AttitudeESKF.swift`, `MountAlignment.swift`** — anchor validity (§3.3), pre-anchor
   publication, yaw-bias runaway (§3.4). Tell it thresholds are being **loosened, not
   tightened**, and to find the loosest test that still rejects a 29° tilt. Require it to
   prove whether bias-Z leaks into pitch. Also ask about `forwardX=0.0`/`-5.4e-20` — forward
   is forced into the YZ plane, which looks like a baked-in portrait-mount assumption.
4. **`Calibration.swift`, `Config.swift`, `ValidityGate.swift`** — the 25-sample finish
   (§3.5) and the threshold table (§3.9). Require unit confirmation for
   `gateMaxRotationRate` first. Ask it to verify the claim that `resetAccumulation()` no
   longer wipes 8 s on one out-of-band sample, and to name every test asserting these
   thresholds.
5. **`Diagnostics/DiagnosticLog.swift`, `Diagnostics/RawSampleRecorder.swift`,
   `Core/Diagnostics.swift`, `RunRecorder.swift` (watchdog only)** — log volume (§3.6),
   watchdog conclusion (§3.8), raw-recorder disk cap (§4 bug 11). Ask which layer to fix
   (caller vs sink) and explicitly warn it **not to destroy the load-bearing heartbeats**.

Each prompt must stay under 5,000 characters or `spawn_run` rejects the batch.

---

## 9. Definition of done

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
