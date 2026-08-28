I'll read the two files I own plus the two I may read.I have everything needed. Let me get exact line numbers for the key blocks in `AttitudeESKF.swift`.I have all the exact line numbers. Let me check the tests directory quickly for what pins this behavior.I have enough to write a precise report. Let me check the two most relevant test bodies — the deferred-anchor path (`testPitchRateReadsThroughTheAlignmentNotTheDeviceAxis` at 109 constructs with no anchor) and the reanchor test — to confirm which break.I have everything I need. Here is the analysis and the minimal fixes.

---

## Summary of root causes

All four evidence items trace to one design gap: **the deferred gravity anchor at `AttitudeESKF.propagate` lines 168–198 accepts the first sample whose specific-force *magnitude* is in band, applying no quiescence, rotation-rate, or near-level test** — and it publishes attitude on the same sample it anchors (and on samples before any anchor at all). Evidence 3 is a separate, unrelated issue in the covariance model. Details, patches, and risks per fix below.

---

### Q1 — Anchor acquisition code, with line numbers

`/Users/vinothiniraju/Documents/Adeesh/motorcycle-wheelie-app/Sources/MotoTelemetryCore/AttitudeESKF.swift`, inside `propagate(_:thermalState:)`:

```swift
168        if !hasAnchored {
169            let magnitude = sample.specificForce.magnitude
170            if magnitude >= config.gateSpecificForceLow,
171               magnitude <= config.gateSpecificForceHigh {
172                attitude = Quaternion.rotation(from: sample.specificForce,
173                                               to: Conventions.worldGravity)
...
189                if !hasDerivedAlignment {
190                    alignment = MountAlignment.fromMeasuredGravity(...)
191                    hasDerivedAlignment = true
192                }
195                hasAnchored = true
196                emitAnchor(time: sample.time, gravity: sample.specificForce)
197            }
198        }
```

**What triggers it:** the first sample after `hasAnchored == false` whose specific-force **magnitude** falls inside `[gateSpecificForceLow, gateSpecificForceHigh]` (0.97 g–1.03 g).

**What validity test it applies:** *only the magnitude band.* This is the bug. A magnitude test alone cannot reject a tilt — the whole point of a gravity vector at rest is that its magnitude is g **at every orientation**. The tilted anchor in Evidence 1 had `gravityMag=9.817`, squarely in band, so it passed. There is **no rotation-rate test, no dwell/quiescence test, and no near-level test.** The full `ValidityGate` (which does check rotation rate and dwell) is never consulted on this path; the estimator reimplements a weaker magnitude-only check. So a phone rotating in the user's hand at a 29° tilt is accepted as "level."

---

### Q2 — Fix Evidence 1 (anchor taken while tilted)

**Root cause** (`AttitudeESKF.swift:170–171`): anchor accepts on magnitude alone; magnitude is orientation-invariant at rest, so it cannot detect tilt. The 29.3° pose (`gravityY=-4.805`) passed because `|g|=9.817` was in band.

**Fix** (smallest, reuses `ValidityGate` per your instruction): thread the gate's `Verdict` (already computed upstream and already passed to `updateWithGravity`) into `propagate`, and anchor only when **the gate is open** (`.open` — which already encodes magnitude band + rotation-rate limit + dwell) **and** the pose is **near-level**. The near-level test is the only new predicate; it is the loosest test that still rejects 29°.

For the near-level test, use the world-up component of the normalized specific force: at rest `f ≈ -g·up`, so `f_z / |f|` near `-1` means level. A generous cutoff of **cos(20°) ≈ 0.94** (i.e. reject tilt beyond ~20°) rejects the 29° pose (its `|f_z|/|f| = 8.507/9.817 = 0.867`, well under 0.94) while tolerating a substantial off-level cradle. This does **not** tighten any existing threshold — it adds a new, deliberately loose one and leans on the already-open gate for everything else.

**While no valid anchor exists: hold previous anchor / report unavailable — never publish a number.** See Q3 for the publish guard.

```diff
--- a/Sources/MotoTelemetryCore/AttitudeESKF.swift
+++ b/Sources/MotoTelemetryCore/AttitudeESKF.swift
@@ -151,7 +151,7 @@
     /// `dt` is taken from consecutive sample times and clamped: a gap outside the
     /// plausible range is a dropout, and it is recorded and propagated with
     /// inflated process noise rather than pretended away.
-    public mutating func propagate(_ sample: IMUSample, thermalState: Int = 0) {
+    public mutating func propagate(_ sample: IMUSample, verdict: ValidityGate.Verdict, thermalState: Int = 0) {
         let nominalDt = 1.0 / config.nominalSampleRate
         var dt = nominalDt
         var gapFactor = 1.0
@@ -165,10 +165,17 @@
         // and anchoring to that would bake the error in permanently. The magnitude
         // band is the same one `ValidityGate` uses.
         if !hasAnchored {
-            let magnitude = sample.specificForce.magnitude
-            if magnitude >= config.gateSpecificForceLow,
-               magnitude <= config.gateSpecificForceHigh {
+            // The gate must be OPEN (magnitude band + rotation-rate limit + dwell,
+            // already proven upstream), AND the pose must be near-level. A magnitude
+            // test alone is orientation-invariant at rest and cannot reject a tilt:
+            // a 29 deg hand-held pose had |f| = 9.82 m/s^2, squarely in band, and
+            // became the definition of level. The near-level test rejects it: at
+            // rest f ~= -g*up, so |f.z|/|f| ~ cos(tilt); 0.94 rejects tilt past ~20 deg
+            // while tolerating an off-level cradle. Deliberately loose — the gate
+            // carries the strictness.
+            let mag = sample.specificForce.magnitude
+            let level = mag > 1e-6 && abs(sample.specificForce.z) / mag >= 0.94
+            if verdict.isOpen, level {
                 attitude = Quaternion.rotation(from: sample.specificForce,
                                                to: Conventions.worldGravity)
```

**Accuracy risk:** low, and net-positive. The gate being open already requires the phone be quasi-static and level enough that magnitude is within ±3% — the new `0.94` cutoff simply closes the orientation blind spot the magnitude test structurally cannot see. It never *tightens* the at-rest acceptance for a genuinely level phone (`|f_z|/|f|` for the healthy anchors is `0.9994`). Risk: if a bike's *mount* is legitimately tilted more than ~20° about the lateral axis (nose-down cradle), the deferred anchor would wait for a more level moment — but such a mount needs R7.1's real solve anyway, and holding the previous/no anchor is safer than freezing a wrong one.

**Tests to update:** `AttitudeESKFTests.testPitchRateReadsThroughTheAlignmentNotTheDeviceAxis` (line 109) and any other test calling `filter.propagate(sample)` with the 2-arg signature must pass a `verdict:`. All the `makeFilter()`-based propagate tests that rely on the deferred anchor (they feed `Conventions.restSpecificForce`, which is level) need a `.init(isOpen: true, heldFor: config.gateDwell, reason: .open)` verdict to keep anchoring. `Pipeline` is the production caller and must pass the gate verdict it already computes.

---

### Q3 — Fix Evidence 2 (garbage pitch published before any anchor)

**Root cause:** the heartbeat at `AttitudeESKF.swift:259` emits `pitchDeg` unconditionally, and `pitch` (line 453) is readable whenever `Pipeline` asks — including the ~27 ms window before `hasAnchored` becomes true, where `attitude == .identity` and the readout is the raw device axis (`-89.7°`). Nothing gates the readout on `hasAnchored`.

**Fix (smallest): expose `hasAnchored` and make the readout unavailable before a valid anchor.** Publish nothing (hold previous / report unavailable) until anchored. Minimal form: make `pitch`/`roll`/`pitchRate` optional-guarded via a public `isAnchored` flag the pipeline checks before publishing, and suppress the heartbeat's pitch line until anchored.

```diff
--- a/Sources/MotoTelemetryCore/AttitudeESKF.swift
+++ b/Sources/MotoTelemetryCore/AttitudeESKF.swift
@@ -47,6 +47,10 @@
     /// `AttitudeSmoother` already
     /// anchors (it passes the first gate-open sample); the live filter must too.
     private var hasAnchored: Bool
+
+    /// True once attitude has been tied to measured gravity. Until then the world
+    /// frame is the raw device frame and `pitch` is meaningless (it reads the device
+    /// axis, e.g. -89.7 deg for a flat phone), so the pipeline must publish nothing.
+    public var isAnchored: Bool { hasAnchored }
```

```diff
@@ -256,15 +260,17 @@
         // 1 Hz heartbeat: pitch deg, applied bias deg/s. Keyed on a constant so it
         // is a pure heartbeat (propagation has no categorical state of its own).
         let degrees = 180.0 / .pi
-        diag.emit("propagate", time: sample.time,
-                  message: "eskf heartbeat",
-                  values: [
-                    "pitchDeg": pitch * degrees,
-                    "biasXDegPerSec": bias.x * degrees,
+        // Do NOT report pitch before an anchor exists: attitude is identity and the
+        // number is the raw device axis, not a bike angle. Emitting it published
+        // -89.7 deg into the pipeline 16 ms before the anchor was acquired.
+        diag.emit("propagate", time: sample.time,
+                  message: "eskf heartbeat",
+                  values: [
+                    "pitchDeg": hasAnchored ? pitch * degrees : Double.nan,
+                    "biasXDegPerSec": bias.x * degrees,
                     "biasYDegPerSec": bias.y * degrees,
                     "biasZDegPerSec": bias.z * degrees,
                     "isDegraded": isDegraded ? 1 : 0,
+                    "isAnchored": hasAnchored ? 1 : 0,
                   ])
```

The **binding fix is in `Pipeline`** (not owned by me — flag for the pipeline owner): before publishing an output, `guard filter.isAnchored else { return nil /* or repeat last */ }`. Without that guard the pipeline can still read `filter.pitch` directly. I own only the estimator; the estimator now exposes `isAnchored` and stops emitting a pitch number pre-anchor. **The pipeline owner must add the publish guard** — that is where the `-89.7` actually entered the pipeline.

**Accuracy risk:** none to the estimate. It only suppresses output during the sub-30 ms pre-anchor window. Downstream consumers must tolerate "unavailable" at stream start (they already must, since the filter starts cold).

**Tests to update:** none of the estimator tests assert on the pre-anchor heartbeat. A new test is warranted: `testNoPitchPublishedBeforeAnchor` — propagate one out-of-band sample, assert `filter.isAnchored == false`. The `Pipeline`-level publish guard needs its own test in the pipeline suite.

---

### Q4 — Fix Evidence 3 (unobservable yaw-bias runs away)

**First, the critical question: can runaway bias-Z leak into reported PITCH?**

**Proof from code: yes, transiently, but it cannot accumulate into a static pitch error.** Trace: bias-Z corrupts the corrected rate `corrected = sample.rotationRate - bias` (line 227), which integrates into attitude at line 231 (`attitude * exp(corrected*dt)`). With the phone flat and world-Z ≈ body-Z, a bias-Z of 5°/s injects a spurious **yaw** rotation about the vertical axis. Pitch is `AxisElevation.pitch(attitude, forwardInBody)` — the elevation of `forward` above horizontal. A pure yaw rotates `forward` *within* the horizontal plane, leaving its elevation unchanged, so at exactly flat the pitch leak is zero. **But** the moment the phone is even slightly tilted (roll/pitch ≠ 0), body-Z is no longer world-vertical, so a rotation about body-Z has a horizontal-tilting component that *does* move `forward`'s elevation — i.e. bias-Z couples into pitch through the off-diagonal quaternion terms. It is second-order (proportional to `sin(tilt)`), so it's small while near-level and grows with tilt — precisely the wheelie regime. It is also self-limiting per-anchor (each re-anchor reset Z to 0.11), but between anchors an unbounded, monotonically climbing bias-Z is an unbounded pitch-error source during an event. **Urgency: real, not cosmetic** — the runaway must be bounded.

**Root cause:** yaw-bias-Z is structurally unobservable from gravity (gravity constrains only the two tilt axes X/Y), yet the covariance model lets its variance persist and the GNSS/gravity updates keep nudging `bias.z` via the `k2` block with nothing pulling it back. The process model adds `biasVariance` to all three bias axes equally each step (`Matrix6.diagonal([..., biasVariance, biasVariance, biasVariance])`, line ~250), so P for bias-Z only ever grows, and every update applies a Z correction that random-walks unboundedly.

**Recommendation — the single smallest fix: do not estimate bias-Z; hold it at its calibrated value.** Rationale: it is unobservable, so estimating it is not merely risky, it is meaningless — there is no measurement that informs it. The bias calibrator already measures `meanBiasZ` (0.111°/s in evidence) far more reliably than the filter. Clamping envelopes or decay both keep a live Z state that still random-walks between updates; zeroing the *bias-Z error state's* Kalman gain removes the runaway at the source with one line and keeps the trustworthy calibrated constant.

Concretely, zero the Z row of the bias-error corrections in both update paths (`k2.z` contribution) — the tightest expression is to project it out of `k2` before applying:

```diff
--- a/Sources/MotoTelemetryCore/AttitudeESKF.swift
+++ b/Sources/MotoTelemetryCore/AttitudeESKF.swift
@@ (applyVectorUpdate, after `let k2 = p21 * hT * sInverse`)
         let k1 = p11 * hT * sInverse
-        let k2 = p21 * hT * sInverse
+        var k2 = p21 * hT * sInverse
+        // Yaw-bias (Z) is UNOBSERVABLE from gravity: gravity constrains only the two
+        // tilt axes. Left free, bias.z random-walks unbounded (observed ~45x truth and
+        // climbing) and, once the phone tilts, couples into pitch through body-Z. It is
+        // held at its calibrated value instead — the bias calibrator measures it far
+        // better than an update that has no information about it can. Zero its gain row.
+        k2.setRow(2, to: .zero)
```

```diff
@@ (applyScalarUpdate, after `let k2 = (p21 * hVector) / s`)
         let k1 = (p11 * hVector) / s
-        let k2 = (p21 * hVector) / s
+        var k2 = (p21 * hVector) / s
+        k2.z = 0   // yaw-bias unobservable — see applyVectorUpdate.
```

(If `Matrix3.setRow` does not exist, the equivalent is zeroing the third component of each column of `k2`; in `applyScalarUpdate`, `k2` is a `Vector3`, so `k2.z = 0` is exact and trivial. I flag the `Matrix3` row-zero helper as the one thing to verify against the linear-algebra API before writing — per my standing lesson, confirm the real signature rather than assume `setRow` exists; if absent, construct the masked matrix explicitly.)

Optionally also stop *growing* P for Z (belt-and-suspenders, still one line at the process step): set the bias-Z entry of the process-noise diagonal to `0`. Not strictly required once the gain is zeroed, and I recommend keeping the fix to the gain alone (smallest).

**Accuracy risk:** low and favorable. Bias-Z was 45× wrong and climbing; pinning it to the calibrated 0.111°/s removes a growing pitch-error source and matches measured truth. The only lost capability is live re-estimation of yaw bias, which was never real (unobservable). X and Y remain fully estimated (gravity observes them), so nose-up pitch bias is unaffected.

**Tests to update:** add `testYawBiasDoesNotRunAwayOnAStationaryPhone` (propagate a flat, still stream with many gravity updates; assert `filter.bias.z` stays within a small band of its initial value). Check `testGNSSAidingContainsBiasDuringSustainedAcceleration` (line 239) still passes — it asserts on bias containment during acceleration; it should, since it exercises the pitch/X-Y channel, but confirm it does not assert a Z change.

---

### Q5 — MountAlignment: `forwardX = 0` (forward forced into YZ plane)

**Quote** (`/Users/vinothiniraju/Documents/Adeesh/motorcycle-wheelie-app/Sources/MotoTelemetryCore/MountAlignment.swift`, `fromMeasuredGravity`):

```swift
var lateralCandidate = Vector3(-1, 0, 0)          // device -X assumed lateral
if abs(lateralCandidate.dot(up)) > 0.94 {         // only if -X ~ up
    lateralCandidate = Vector3(0, -1, 0)
}
let projected = lateralCandidate - up * lateralCandidate.dot(up)
let left = projected.normalized
let forward = left.cross(up)
```

**Why forwardX ≈ 0:** `left` is device `-X` Gram-Schmidt'd against `up`. When the phone is near-upright/flat, `up ≈ (0, 0, 1)`-ish so the projection keeps `left ≈ (-1, 0, ~0)` — i.e. `left` stays essentially along device X. Then `forward = left × up`; a cross product of a vector lying (almost) along X with `up` has (almost) **zero X component** by construction. Hence `forwardX = 0.0` or `-5.4e-20` (floating-point zero). This is the **deliberate assumption documented in the doc comment**: *"the device's screen-horizontal axis (−X) is the bike's lateral axis."* Forward is *defined* as perpendicular to both up and the assumed lateral, so it necessarily has no lateral (X) component.

**Is it a real correctness limit? Yes — a known, documented one.** The doc comment states it plainly: `fromMeasuredGravity` "cannot detect a phone rotated in its cradle about the screen normal, and cannot tell forward from backward." Forcing `forwardX = 0` bakes in the assumption that the phone is not yawed within its mount. If the rider's phone *is* rotated about the screen-normal in the cradle (e.g. angled 20° in a handlebar mount), the true bike-forward has a nonzero device-X component, and this alignment mis-assigns it — a real tilt could read partly as lean and vice-versa. **This is not a bug to fix in `fromMeasuredGravity`** — gravity fundamentally cannot observe yaw. It is exactly what R7.1's two-gesture solve (`AlignmentSolver`, which uses the acceleration pull to measure the true forward axis, yielding a nonzero `forwardX`) exists to correct. 

**Flag:** the gravity-only anchor is a *portrait/square-mount* fallback with a genuine correctness limit for yawed mounts; it should not be treated as a substitute for R7.1, and the UI must disclose "assumed alignment" (the code comments already say it must). No code change proposed here — flagging as a limitation, per your instruction to bias toward the smallest fix and not redesign.

---

### Cross-cutting note on signature change

Fix Q1 changes `propagate`'s signature (adds `verdict:`). The production caller is `Pipeline` (not owned by me). Every test calling `filter.propagate(sample)` and the pipeline call site must be updated. If you prefer to avoid touching the signature, the alternative-smallest is to have `AttitudeESKF` hold its own `ValidityGate` and compute the verdict internally from the sample — but that **duplicates** gate state already living in `Pipeline` and risks the two disagreeing (the ESKF doc comment explicitly warns against duplicated frame state). Threading the already-computed verdict is the cleaner minimal change. Flagging the choice:

[OPTIONS: Thread the gate verdict into propagate (change the signature) | Give AttitudeESKF its own internal ValidityGate instead (no signature change) | Show me the Pipeline call site before deciding]