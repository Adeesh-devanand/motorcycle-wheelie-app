# HANDOFF — beta/calibrate-once, Linux box → Mac (Xcode)

Written 2026-09-04 by the Linux-side agent. Everything below was **verified on this
box**, not remembered. Where something could not be verified, it says so.

The Linux box has no Xcode and the iOS app target cannot compile here at all
(SwiftUI / CoreMotion / AVFoundation are absent). So the whole app half of this
branch has been reviewed by reading and grep only. **Your Xcode build is the first
real compile this code has ever had.** Expect errors; that is the expected outcome,
not a sign something went wrong.

---

## 1. Where things stand

Branch `beta/calibrate-once`. Two logical chunks:

| | commit | state |
|---|---|---|
| Beta rewrite (ESKF → calibrate-once) | `6667875` | committed + pushed earlier |
| **Holistic audit fix pass** | the commit carrying this file | 36 files, +1710/−1365 |

Verified on this box before committing:

- **163 tests, 0 failures** (`/opt/swift/usr/bin/swift test`)
- `swift build` clean
- `motolog synth` works — 2001 imu samples, 1071 gate-open
- `motolog replay Fixtures/pre-rename-session.ndjson` works — 123 decoded, **119
  pipeline samples** (it produced **0** before this pass)

⚠️ **The Swift toolchain is NOT on PATH on the Linux box.** It lives at
`/opt/swift/usr/bin/swift`. A bare `swift test` there silently does nothing —
`nohup swift test` reports "No such file or directory" and looks like a pass. On your
Mac this is a non-issue, but do not trust any prior "tests passed" claim that used a
bare `swift`.

---

## 2. DO THIS FIRST — the Xcode project file is broken and will block the build

This is the single most important thing in this document, and it is **not** a
consequence of the audit fix pass — it predates it. `project.pbxproj` at
`MotoTelemetryApp/MotoTelemetryApp/MotoTelemetryApp.xcodeproj/project.pbxproj`
is out of sync with the source tree in **both** directions.

**Two files exist on disk but are NOT in the Xcode target at all (0 references).**
The build cannot succeed until they are added, because `LiveWheelieView` instantiates
both:

- `Sources/MotoTelemetryApp/Features/Live/CalibrationScreen.swift`
- `Sources/MotoTelemetryApp/Features/Live/SwipeAlignmentScreen.swift`

**Eight entries reference files that no longer exist** and should be pruned (4
references each — build file + file ref + group + sources phase):

- `CalibrationOverlay.swift` (deleted back in `6667875`, replaced by `CalibrationScreen`)
- `SessionWriter.swift`, `SessionRecovery.swift`, `VibrationRecorder.swift`
- `RecordingControlsView.swift`, `RecordingModeView.swift`, `ExportShareView.swift`,
  `SyncFlashView.swift`

Adding the two missing files is **blocking**. Pruning the eight stale ones is
housekeeping — Xcode tolerates missing refs with a warning, so do it while you are in
there but it will not stop a build.

To re-derive this list yourself rather than trusting it:

```bash
# on disk but not in the project → must be added
for f in $(find Sources/MotoTelemetryApp -name '*.swift' | sed 's|.*/||' | sort); do
  grep -q "$f" MotoTelemetryApp/MotoTelemetryApp/MotoTelemetryApp.xcodeproj/project.pbxproj \
    || echo "MISSING: $f"
done
```

(Ignore a `sourcecode.swift` hit — that is pbxproj's file-type token, not a file.)

---

## 3. What this fix pass changed, and which parts are unverified

A 9-agent read-only audit over ~17k lines found two critical bugs that the green test
suite could not see, plus a long tail. All were fixed. Core and CLI changes are
compiler-verified and test-covered. **Every app-target change is read-verified only.**

### Verified (core + CLI + tests — safe)

- **`motolog replay` produced nothing on every real log.** `Sources/motolog/main.swift`
  omitted the *defaulted* `gravityAnchor:` parameter, so `CalibrateOnceEstimator` was
  never anchored and `Pipeline.processIMU`'s `guard estimator.isAnchored` dropped every
  sample. Because the parameter is a defaulted optional, forgetting a required step
  compiled clean. Replay now runs a real `BiasEstimator` calibration over the log's own
  opening samples, falls back to the first sample's specific force **and says so**, and
  exits non-zero on an empty pipeline instead of printing `pipeline samples: 0` as if it
  were a result. Also switched to `StreamingReplaySource`, which tolerates a
  crash-truncated final line where `LogFile.read` throws.
- **`EventSegmenter.finish()` added.** An event still open when the stream ended was
  never emitted — the only path producing `.end` was the exit dwell elapsing, which
  cannot happen once samples stop. A ride stopped while still lofted lost the event
  entirely, biased toward the longest holds.
- **Segmenter dwells now restart across a gap** larger than `Config.maxSampleGap`. They
  compared raw timestamps, so one post-gap sample satisfied the 0.15 s entry dwell.
- **`CalibrateOnceEstimator.anchor()` clears `lastTime` and zeroes `pitchRate`.** The
  first sample after a re-zero was integrating the span from *before* the anchor onto
  the attitude just declared level.
- **`integrate()` zeroes `pitchRate` when it returns false** — "I don't know the rate"
  was reading as "the last rate still applies".
- **`SessionSummary.bestConsistency` filters on `holdWindowResolved`.** Worse than a
  missing filter: the heuristic fallback window is a narrow slice around the event
  midpoint, so it yields a *lower* std dev than an honest hold and was biased toward
  winning a personal best.
- **`Config` v6 → v7**, adding `maxIntegrationDt` and `maxSampleGap` (both were bare
  literals), plus the cue transfer-curve group moved out of `CueAudioRenderer`.
- **`ReachabilityTests` now strips comments before counting references.** A type
  mentioned only in a comment used to count as a caller — and this codebase documents
  deleted types in comments, so any of those names returning as a live type would be
  shielded by its own tombstone. This immediately caught two masked orphans:
  `TargetSnapshot` (deleted — superseded by the app's `RunConfigurationSnapshot`) and
  `StreamingReplaySource` (wired into motolog).
- **8 new regression guards** in
  `Tests/MotoTelemetryCoreTests/BetaAuditFixTests.swift`, each of which fails against
  the pre-fix code by construction.

### NOT verified — read + grep only, no compiler

Ordered by risk. If the build breaks, look here first.

1. **`RunRecorder.swift` — the concurrency restructuring. Highest risk by far.**
   It was writing `@Observable` UI state from detached 100 Hz sensor Tasks;
   `processLock` serialised the two writers against each other but did not make the
   writes main-actor-safe against SwiftUI reading them. Under Swift 6 strict
   concurrency that is a hard error. The fix: UI-facing properties are now
   `@MainActor`-isolated, `processSample` (off-actor, under the lock) writes internal
   non-observable mirrors and stages display values into a lock-protected
   `PendingDisplay`, and a `@MainActor flushDisplay()` applies them — called from the
   view model's existing 30 Hz display tick, so 100 Hz coalesces to 30 Hz with zero
   per-sample Tasks. `LiveWheelieViewModel` and `DisplayLinkProxy` are now `@MainActor`.
   A `sessionEpoch` bound to sensor-task lifetime makes late samples early-return
   instead of racing the next `startSession`.
   **What the compiler may reject:** `@MainActor` on individual stored properties of a
   non-isolated `@unchecked Sendable` class, `@objc tick` on a `@MainActor` class, and
   whether the watchdog `Task {}` inside the now-`@MainActor startSession` inherits main
   actor isolation. The *shape* is right; only Xcode can confirm the isolation checker
   agrees.
2. **`CueAudioRenderer.swift`** — added `AVAudioSession.interruptionNotification` and
   `.AVAudioEngineConfigurationChange` handling (the tone died permanently after any
   phone call and never restarted), clamped the render callback to the real buffer
   capacity, and added the **B5 hysteresis latch** using the four previously-inert
   `Config.cue*` fields. Unverified symbol spellings:
   `AVAudioSessionInterruptionTypeKey`, `AVAudioSessionInterruptionOptionKey`,
   `Notification.Name.AVAudioEngineConfigurationChange`.
3. **`RawSampleRecorder.swift`** — added `didEnterBackground`/`willTerminate` flush
   observers (its sibling `DiagnosticLog` had them; the recorder writing the *more*
   important file had none), lock-guarded accessors for the truncation signals, an
   idempotent `finish()`, and a **periodic fsync on `Config.fsyncInterval`**.
4. **`WheelieRun.swift`** — fixed a genuine build break: both interval bridges called
   `RangeInterval(start:end:)`, which does not exist (the struct has four undefaulted
   stored properties and no custom init; the only `init(start:end:)` belongs to the
   unrelated core type `IntervalDetector.Interval`). Now passes all four arguments
   including `metric:`, which `RangeIntervalTimeline` needs to tell the angle channel
   from speed. **This was the branch's headline fix — the IntervalDetector bridge meant
   to kill the permanent "ANGLE IN RANGE 0.0s" — and it never compiled.**
5. **`LiveWheelieView` / `LiveWheelieViewModel`** — speed now renders `—` rather than a
   fabricated `0` when GNSS has no fix (`liveSpeedAvailable` was set but never read, so
   a stationary bike and no satellites looked identical), and `speedInRange` no longer
   returns a verdict computed from a held value.
6. **`IntegrityReportView` / `BikeProfileSetupView` / `PastRunsView`** — three reachable
   screens stopped lying: fabricated telemetry (98.2 Hz, ±3.2 m GNSS) behind a "Data
   Integrity" title is now an honest empty state; a wizard claiming "Mount rotation
   matrix saved" whose state machine never advanced is gone; a VoiceOver-labelled
   Settings button with an empty action is removed.
7. **7 files deleted** — `SessionWriter`, `SessionRecovery`, `VibrationRecorder` and the
   four `Features/Session/` views, all verified zero-caller first. `SessionWriter`
   documented "a force-quit loses at most 1 second" and had **no callers**, so that
   guarantee was false for every ride ever recorded; it now lives in
   `RawSampleRecorder`, the writer that actually runs.

---

## 4. Next steps, in order

1. **Add the two missing files to the Xcode target** (§2). Blocking.
2. **Build.** Fix whatever the isolation checker says about `RunRecorder` first — that
   is the riskiest change and the most likely source of errors.
3. **Prune the eight stale pbxproj entries** (§2). Housekeeping.
4. **Re-run the core suite on the Mac** to confirm 163/0 travels (`swift test` — on the
   Mac the toolchain *is* on PATH).
5. **Commit the Xcode fixes** as their own commit so the pbxproj repair is separable
   from the audit pass.
6. **Ride it.** Two things no desk can verify:
   - Does the new **hysteresis latch actually stop the flapping tone**? That was the #1
     complaint from the 2026-09-01 test ride ("the active beeper rose and fell
     randomly"). This is the fix for it.
   - Does the **calibrate → swipe → live** flow behave on-device, and does calibration
     still complete with the engine running? (Historically the 1.10 g band and the
     5 °/s rotation limit forced the engine off — not a vibration metric.)
7. **Pull a fresh device log** and replay it: `motolog replay <log>`. Replay is real now,
   so a log from the ride is directly inspectable at a desk. Check whether the anchor
   line reports a real calibration or the `FALLBACK` path — if it always falls back, the
   log has no clean at-rest opening window and the calibration screen is not doing its
   job.

## 5. Genuine loose ends (not compile issues)

- **`IntegrityReportView` shows "No session data yet" and nothing feeds it.** The
  parameter is defaulted to `nil` so `SettingsView` still compiles; threading a real
  `IntegrityReport` from the quality monitor is unfinished work, not a bug.
- **`editingProfile` in `BikeProfileSetupView` is dead** — pre-existing, left alone
  deliberately to keep the diff scoped.
- **Three `Config` fields are inert**: `syncFlashFrames` (marked inert in-file with the
  reason — its view was deleted), and check `writerRingCapacity` / `fsyncInterval` are
  now genuinely read by `RawSampleRecorder` (they are).
- **`.kiro/settings/cli.json` is deliberately left uncommitted**, as in every prior
  commit on this branch — it is a local model-effort setting.
- **Not on `main`.** No PR opened. KiroCrew blocks pushes to protected branches, so
  landing this needs your own SSH session:
  `git fetch origin && git push origin origin/beta/calibrate-once:main`

## 6. The meta-lesson worth keeping

Every one of the worst findings was invisible to a green suite, each for a *structural*
reason, in two families:

- **A defaulted or synthesized thing let a required step be silently omitted** — the
  defaulted `gravityAnchor:` (replay produced nothing), the synthesized memberwise init
  with no `init(start:end:)` (the app did not compile).
- **A value or timer survived an event it should not have** — `pitchRate` across a gap,
  `lastTime` across a re-anchor, dwell timers across a discontinuity, and an open event
  *not* surviving stream end. All four produced a plausible number rather than an
  obvious break, which is why nothing flagged them.

Plus the project's signature failure mode, again: complete, tested, unconnected code
that lies about being wired. The comment-stripping `ReachabilityTests` guard now catches
that class mechanically — it found two orphans within one run of being tightened.
