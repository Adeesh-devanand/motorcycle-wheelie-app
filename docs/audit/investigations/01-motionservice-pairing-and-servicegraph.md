I'll read the three files I own to diagnose both defects.I have all three files. The root cause of Defect A isn't in the visible pairing code — I need to find why `start()` is called before the old session's queue drains. Let me check how `start()`/`stop()` are called and whether the queue is the shared bottleneck. The pairing state (`pendingGyro`/`pendingAccel`) is the prime suspect for Defect A, and the `@State` re-init on `RootTabView` is the suspect for Defect B. Let me confirm both.Now I need the two critical spots: RunRecorder's `startSession`/`stopSession` (to see the ordering of `motionService.start()` vs subscribe, and whether `stop()` is even called on tab switch), and LiveWheelieViewModel's `onAppear`/`startSession`. Let me read both.I now have everything for both defects. The key insight for Defect A: `MotionService` never clears `pendingGyro`/`pendingAccel` in `stop()`, and — more decisively — all three CoreMotion streams share a **single serial OperationQueue** (`maxConcurrentOperationCount = 1`). Let me confirm one detail about that queue and the pairing-parity mechanism before finalizing.

The evidence pattern (`unpaired` counter incrementing only on the *second* stash of the same channel) tells the whole story. Let me verify my reading of the parity logic is airtight — `unpairedCount` increments only when `pendingGyro != nil` (i.e., a gyro is already stashed and another gyro arrives). This means pairing works when gyro/accel **alternate**, and fails permanently when they arrive in a **fixed offset order** where one channel always stashes-then-overwrites. Confirmed from the code already read. Here is the report.

---

## DEFECT A — MotionService emits zero samples on some sessions

### 1. The pairing code, match key, and tolerance

`/Users/vinothiniraju/Documents/Adeesh/motorcycle-wheelie-app/Sources/MotoTelemetryApp/Services/MotionService.swift`

Match key = the CoreMotion `data.timestamp` of each callback. Tolerance = `pairTolerance` (line 49):

```
49:    private let pairTolerance: TimeInterval = 0.005   // 5 ms
```

`receive(gyro:at:)` (lines ~207–235):
```
209:        if let accel = pendingAccel, abs(accel.time - time) <= pairTolerance {
210:            pendingAccel = nil
...            emit(...)
        } else {
227:            if pendingGyro != nil {
228:                unpairedCount += 1
229:            }
230:            pendingGyro = (time, rate)
        }
```

`receive(accel:at:)` (lines ~238–252):
```
240:        if let gyro = pendingGyro, abs(gyro.time - time) <= pairTolerance {
241:            pendingGyro = nil
...            emit(...)
        } else {
248:            if pendingAccel != nil {
249:                unpairedCount += 1
250:            }
251:            pendingAccel = (time, force)
        }
```

A sample emits only when the *opposite* channel is already stashed AND its timestamp is within 5 ms. Otherwise the incoming sample is stashed into its own-channel slot, overwriting any prior stash there.

### 2. Why gen 3/5/6 pair instantly and gen 1/2/4 never recover — root cause

Two compounding faults, both in this file:

**(a) `stop()` never clears `pendingGyro` / `pendingAccel`.** `stop()` (lines ~161–199) stops the three CoreMotion streams but leaves the pairing state populated. Whatever half-sample was stashed when the previous session ended survives into the next `start()`.

**(b) The three CoreMotion streams all run on ONE serial queue.** `queue.maxConcurrentOperationCount = 1` (init) and gyro, accel *and* deviceMotion are all scheduled `to: queue`. On this serial queue the callback **delivery order** for a given ~10 ms tick is fixed by CoreMotion's internal scheduling and does not interleave gyro↔accel one-for-one. When the steady-state order is (…gyro, gyro, accel, accel…) rather than strict alternation, the algorithm live-locks: each new gyro finds no pending accel, so it *overwrites* `pendingGyro`; each new accel overwrites `pendingAccel`; nothing is ever within-tolerance of a live stash. Result: **0 emitted, unpaired climbs at ~100 Hz** — exactly gen 1/2/4.

The `first sample` line appearing only for gen 3/5/6, 6–7 ms after stream creation, confirms the state is decided in the very first tick: whichever channel happens to fire first *and* leaves a stash the other channel's first callback matches within 5 ms bootstraps alternation, and it self-sustains. If the first tick lands the two channels in the overwrite phase relation, it never self-corrects for the life of the session — the residual `pending*` from the previous session (fault a) biases which phase you boot into, which is why it's session-dependent rather than random per-sample.

The stale stash is the trigger; the shared serial queue with no per-channel ordering guarantee is the reason the bad phase is stable instead of self-healing.

### 3. Is `unpairedCount` reset per session?

**No.** It is declared `public private(set) var unpairedCount: Int = 0` and is only ever incremented — never reset in `start()` or `stop()`. `start()` resets `emittedCount`, `sawFirstSample`, `firstEmitTime`, `streamGeneration`, but *not* `unpairedCount`. So the "Unpaired samples" number logged at stop is a **process-cumulative** total. The diagnostic is misleading: the per-session unpaired count must be derived by differencing consecutive stops (as the task already did: gen4 ≈ 6012−4107 ≈ 1905). Any reader treating it as per-session over-counts every session after the first.

### 4. Minimal fix

The smallest fix that keeps raw gyro available: **clear the pairing state and reset `unpairedCount` in `stop()`** so each session starts clean, and make the pairing self-heal by evicting a stash that has gone stale (older than a couple of ticks) instead of overwriting silently. The stale-eviction is what breaks the permanent live-lock; the clear-in-stop removes the cross-session carryover.

Switching to `deviceMotion` (already available, `deviceMotionAvail=1`) would sidestep pairing entirely, but it would **lose the raw uncorrected `rotationRate` and raw `userAcceleration`/`gravity` split that the bias calibrator depends on** — `deviceMotion.rotationRate` is already bias-compensated by CoreMotion, so `CalibrationService`/`BiasEstimator` would be zeroing an already-zeroed signal and `specificForce` would no longer be the raw accelerometer reading the gate expects. Do **not** switch. Keep hand-pairing raw streams.

Proposed patch (text diff, not applied):

```diff
--- a/Sources/MotoTelemetryApp/Services/MotionService.swift
+++ b/Sources/MotoTelemetryApp/Services/MotionService.swift
@@
     public func stop() {
         manager.stopGyroUpdates()
         manager.stopAccelerometerUpdates()
         manager.stopDeviceMotionUpdates()
+        // Clear pairing state so the next session boots clean. A half-sample left
+        // stashed here biases the first tick of the next start() into the overwrite
+        // phase relation, from which the timestamp-pairing never self-heals and the
+        // whole session emits zero (gen 1/2/4). unpairedCount is reset too so the
+        // logged total is per-session rather than process-cumulative.
+        lock.lock()
+        pendingGyro = nil
+        pendingAccel = nil
+        latestAttitude = nil
+        unpairedCount = 0
+        lock.unlock()
         // Deliberately NOT calling `continuation.finish()`. The stream and its
```

And make pairing self-heal so a bad phase relation cannot live-lock (replace the two `else` stash blocks):

```diff
--- a/Sources/MotoTelemetryApp/Services/MotionService.swift
+++ b/Sources/MotoTelemetryApp/Services/MotionService.swift
@@ private func receive(gyro rate: Vector3, at time: TimeInterval) {
         if let accel = pendingAccel, abs(accel.time - time) <= pairTolerance {
             // Pair found
             pendingAccel = nil
             let attitude = latestAttitude
             lock.unlock()
             emit(time: time, rate: rate, force: accel.force, attitude: attitude)
         } else {
-            if pendingGyro != nil {
-                unpairedCount += 1
-            }
-            pendingGyro = (time, rate)
+            // A stale opposite-channel stash (older than the tolerance window) can
+            // never pair now, so evict it instead of leaving it to block future
+            // matches. Overwriting our own stash is still counted as a drop.
+            if let accel = pendingAccel, time - accel.time > pairTolerance {
+                pendingAccel = nil
+                unpairedCount += 1
+            }
+            if pendingGyro != nil {
+                unpairedCount += 1
+            }
+            pendingGyro = (time, rate)
             lock.unlock()
         }
@@ private func receive(accel force: Vector3, at time: TimeInterval) {
         if let gyro = pendingGyro, abs(gyro.time - time) <= pairTolerance {
             pendingGyro = nil
             let attitude = latestAttitude
             lock.unlock()
             emit(time: time, rate: gyro.rate, force: force, attitude: attitude)
         } else {
-            if pendingAccel != nil {
-                unpairedCount += 1
-            }
-            pendingAccel = (time, force)
+            if let gyro = pendingGyro, time - gyro.time > pairTolerance {
+                pendingGyro = nil
+                unpairedCount += 1
+            }
+            if pendingAccel != nil {
+                unpairedCount += 1
+            }
+            pendingAccel = (time, force)
             lock.unlock()
         }
```

If you want the absolute minimum single-hunk change, the `stop()` clear alone fixes the *cross-session* carryover and will recover most sessions; the self-heal hunk is what guarantees a session can't get stuck even on first launch. I recommend both — they are small and complementary.

Risk: Low. The clear runs under the same `lock` used by the pairing handlers, so no data race. The stale-eviction only discards samples that were already unpairable (already lost data); it cannot drop a sample that would otherwise have paired, because a same-channel arrival already meant the prior stash was going to be overwritten regardless. Behavior for the healthy alternating case (gen 3/5/6) is unchanged.

---

## DEFECT B — ServiceGraph constructed 3×

### 5. Where ServiceGraph is constructed / how held

`/Users/vinothiniraju/Documents/Adeesh/motorcycle-wheelie-app/Sources/MotoTelemetryApp/App/RootTabView.swift`

```
21:    @State private var services = ServiceGraph()
```

It is held as **`@State` inside a `View` (`RootTabView`), with an inline default-value initializer.** That is the bug. `@State private var services = ServiceGraph()` evaluates `ServiceGraph()` **every time `RootTabView.init` runs** as the autoclosure default. SwiftUI only *keeps the first* instance and discards the rest — but the discarded ones are **fully constructed first**, and `ServiceGraph.init` eagerly builds `RunRecorder`, `SpeedService`, `MotionService`, etc. and (for `SpeedService`) starts location authorization. So every re-init of `RootTabView` spins up a throwaway graph whose side effects (GPS auth, `SpeedService started`) have already fired before SwiftUI throws the object away.

### 6. Why saving a run causes reconstruction

`RootTabView` reads `services.repository` (passed to `PastRunsView`) and the recorder/calibration. `ServiceGraph` is `@Observable`, and its members `RunRepository` / `RunRecorder` are observable too. Saving a run mutates `RunRepository` (`Loaded 1 runs` / the run list publishes), which SwiftUI observes as a dependency of `RootTabView.body`. That invalidates `RootTabView`, SwiftUI re-runs its `init` to produce a fresh struct value, and the `@State` default autoclosure `= ServiceGraph()` **executes again** to build the candidate initial value — constructing a brand-new graph (new `SpeedService`, `generation=0.0` GNSS fix) even though SwiftUI will keep the original. That's the `00:51:48` pair of constructions coinciding exactly with the save, and the fresh graph logging `generation=0.0` while the live one was on `generation=5`.

### 7. Why twice at launch and twice on save

SwiftUI evaluates a `View`'s `@State` default initializer more than once during identity/layout setup — `RootTabView` is initialized twice during the initial `WindowGroup` render (once to establish identity, once for the first real body pass), so `ServiceGraph()` runs twice at launch → two `ServiceGraph constructed` + two `Loaded 0 runs`. On save, the observation-driven invalidation re-runs `RootTabView.init` and again the struct is materialized twice in the same update pass → two more constructions + two `Loaded 1 runs`. In both cases only one instance survives; the extras are the eagerly-built throwaways whose GPS/side-effects already ran, which is why you end up with 3 live `SpeedService`s and 3 authorization starts.

### 8. Minimal fix — exactly one ServiceGraph for the app lifetime

Move ownership up to the `App` (which is created once) and inject it, so the graph is constructed a single time and `RootTabView` merely receives it. `@State` on the `App` value is initialized exactly once for the process.

```diff
--- a/Sources/MotoTelemetryApp/App/WheelieTrackerApp.swift
+++ b/Sources/MotoTelemetryApp/App/WheelieTrackerApp.swift
@@
 @main
 struct WheelieTrackerApp: App {
-    @State private var calibrationService = CalibrationService()
-    @State private var runRepository = RunRepository()
-    @State private var riderPreferences = RiderPreferences()
+    // Single graph for the whole process. `App` is instantiated once, so this
+    // @State default runs once and every service inside it is constructed once.
+    @State private var services = ServiceGraph()
 
     init() {
         configureAudioSession()
     }
 
     var body: some Scene {
         WindowGroup {
-            RootTabView()
-                .environment(calibrationService)
-                .environment(runRepository)
-                .environment(riderPreferences)
+            RootTabView(services: services)
+                .environment(services.calibration)
+                .environment(services.repository)
+                .environment(services.preferences)
         }
     }
```

```diff
--- a/Sources/MotoTelemetryApp/App/RootTabView.swift
+++ b/Sources/MotoTelemetryApp/App/RootTabView.swift
@@
 struct RootTabView: View {
-    @State private var services = ServiceGraph()
+    // Injected by WheelieTrackerApp and held for the app lifetime. NOT a @State
+    // default initializer: that autoclosure re-runs `ServiceGraph()` on every
+    // RootTabView.init (twice at launch, twice again when saving a run publishes
+    // through RunRepository), eagerly building throwaway graphs whose SpeedService
+    // GPS side-effects already fired — the 3 concurrent SpeedServices.
+    let services: ServiceGraph
     @State private var selectedTab = 0
```

Risk: Low–moderate. The graph now outlives any single `RootTabView` value, which is the intent. Two things to verify after the change:
- `RootTabView` must not be given an explicit `init` that reruns construction — passing `services` as a plain `let` is correct; do not wrap it in `@State`, or the same autoclosure trap returns.
- `WheelieTrackerApp` previously injected three separate `@State` service instances into the environment; those are now sourced from `services` (`services.calibration`, `services.repository`, `services.preferences`) so any `@Environment` reader downstream gets the *same* instances the recorder uses — this actually fixes a latent split-brain where the environment's `CalibrationService`/`RunRepository` were *different* objects from the ones inside `ServiceGraph`. Confirm no view relied on those being distinct (they should not).