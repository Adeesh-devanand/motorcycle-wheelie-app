# Design — Motorcycle Wheelie Telemetry, v1.0

Implements `requirements.md` in this directory. `docs/ui-spec.md` governs the view
layer; this document does not restate it and does not contradict it. Where the ui
spec defines a data contract, the design **bridges** to it rather than defining a
parallel one (§13).

## 1. Layering

Three compilation units, one dependency direction.

```
┌───────────────────────────────────────────────────────────────┐
│ MotoTelemetryApp (iOS, Xcode-owned .xcodeproj)                │
│  sensor adapters · disk writer · audio renderer · SwiftUI     │
│  ui-spec §13 file tree lives here, unchanged                  │
└───────────────┬───────────────────────────────────────────────┘
                │ imports (local SPM dependency)
┌───────────────▼───────────────────────────────────────────────┐
│ MotoTelemetryCore  — pure, no platform imports (R1.1)         │
│  Sample stream · Stage pipeline · calibration · alignment     │
│  ESKF · RTS smoother · segmenter · scorer · intervals · cue   │
│  log codec · run projection                                   │
└───────────────▲───────────────────────────────────────────────┘
                │ imports
┌───────────────┴───────────────────────────────────────────────┐
│ motolog (macOS CLI) — replay · synth · fft · allan · verify   │
│  MAY import Accelerate; it is not the core (R20.4)            │
└───────────────────────────────────────────────────────────────┘
```

The purity test of R1.1 greps `Sources/MotoTelemetryCore/` **only**, so the CLI's
use of Accelerate for FFT and Allan deviation is legal and deliberate: those are
offline analysis tools, not pipeline stages.

`Package.swift` changes: `platforms: [.macOS(.v14), .iOS(.v18)]`. Products and
target names are unchanged.

### 1.1 What "the app target stays thin" means concretely

The app is allowed to do exactly four things: convert a platform callback into a
`Sample` and hand it to the pipeline; write bytes the core gave it to disk;
render the `CueState` the core computed; and map core output onto ui-spec view
models for display. It contains no threshold, no filter, no unit of estimation
logic. Any temptation to "just smooth this one value in the view model" is
answered by ui-spec §7.3, which already allows display-only smoothing and
explicitly forbids it reaching the stored run.

## 2. Frame and sign conventions — canonical

Every sign in this design follows from this section. It is written out because
the existing code contains a contradiction (§2.2) that would otherwise be
resolved wrongly.

### 2.1 The conventions

- **World frame W:** right-handed, **+Z up**. Fixed by `AxisElevation`, which
  reads `fWorld.z` and compares against `Vector3(0, 0, 1)`.
- **Bike frame B:** right-handed, **+X forward, +Y left, +Z up**. (`x × y = z`
  requires *left*, not right, once Z is up.)
- **Attitude `Quaternion` q:** rotates **body → world**. Fixed by
  `Quaternion.rotate(_:)`'s documented behaviour and by `AxisElevation`'s use of
  it.
- **Nose-up is therefore a NEGATIVE rotation about +Y**, i.e. a wheelie of θ is
  `Quaternion.exp(rotationVector: Vector3(0, -θ, 0))`. Fixed by the passing test
  `AxisElevationTests.testPitchIsIndependentOfRoll`, which asserts exactly this.
- **Gyro sign:** a wheelie produces a **negative** `rotationRate.y`.
- **Specific force sign:** `IMUSample.specificForce` points **along** gravity, so
  a level bike at rest reads `(0, 0, -g)`. Fixed by
  `ValidityGateTests.level(_:)`. Formally

  ```
  f_B = R(q)ᵀ · (g_W − a_W)      where g_W = (0, 0, −g), a_W = world acceleration
  ```

  which is the negative of proper acceleration. For a bike pitched nose-up by θ
  and accelerating forward at `a`:

  ```
  f_B = ( −g·sinθ − a·cosθ ,  0 ,  −g·cosθ + a·sinθ )
  ```

  At θ=0, a=0 this is `(0, 0, −g)` ✓.

### 2.2 Defect in `SyntheticSource` — must be corrected before M3

`SyntheticSource.next()` emits, for nose-up θ:

```swift
rotationRate: Vector3(0, rate, 0) + scenario.gyroBias   // POSITIVE y for nose-up
fx = longitudinal * cos(pitch) + g * sin(pitch)         // POSITIVE x gravity term
fz = -longitudinal * sin(pitch) - g * cos(pitch)
```

Both the gyro sign and the gravity x-sign follow an aerospace-style convention
(nose-up positive about +Y, Z down) that contradicts §2.1. Verified numerically:
at nose-up 30° the quaternion convention requires `f_B = (−4.9033, 0, −8.4928)`
while the generator emits `(+4.9033, 0, −8.4928)`; and integrating the
generator's positive y-rate through `Quaternion.exp` yields **−30°**, not +30°.

Neither existing test detects this. `ValidityGate` tests only `|f|`, which is
`1.000 g` either way. `testAccelerometerAloneIsBadlyWrongDuringTheEvent` uses
`atan2(fx, -fz)`, which returns +30° for both sign choices.

**Resolution: the generator moves, not the estimator.** `AxisElevation` and its
test encode the convention that reaches the user, and an estimator built to the
generator's frame would report negative angles for real wheelies on device. The
correction is two signs in `SyntheticSource`:

```swift
rotationRate: Vector3(0, -rate, 0) + scenario.gyroBias
fx = -(longitudinal * cos(pitch) + g * sin(pitch))
fz = -g * cos(pitch) + longitudinal * sin(pitch)
```

and a new test that would have caught it: integrate the generator's own gyro
stream through `Quaternion.exp` from identity and assert the resulting
`AxisElevation.pitch` tracks `truePitch(at:)` to within 0.1° over a
bias-free, vibration-free scenario. That test is the convention's guard rail and
is a prerequisite for every accuracy criterion in R8, R9 and R21 — those numbers
are meaningless while the generator and the estimator disagree about which way is
up. It lands as an early task (see tasks.md), before the ESKF.

## 3. Module map

### 3.1 `Sources/MotoTelemetryCore/` — new and changed

| File | Status | Contents |
|---|---|---|
| `Sample.swift` | renamed from `Measurement.swift` | `Sample` enum + payload structs, unchanged wire format (R1.4–R1.6) |
| `Math.swift` | extended | `Matrix3`, `Matrix6`, `Symmetric6`, Cholesky solve, `skew(_:)` |
| `Config.swift` | extended, version → 2 | §17 field table |
| `Stage.swift` | unchanged | `Stage`, `MeasurementSource` |
| `ValidityGate.swift` | unchanged | as committed |
| `AxisElevation.swift` | unchanged | as committed |
| `LogFile.swift` | extended | streaming reader, `LogRecord` envelope for markers/thermal |
| `SyntheticSource.swift` | **corrected** | §2.2 sign fix; scenario gains mount rotation |
| `Conventions.swift` | new | §2.1 written as executable constants + doc comment |
| `Calibration.swift` | new | `BiasEstimator`, `BiasEstimate`, `CalibrationStatus` |
| `MountAlignment.swift` | new | `AlignmentSolver`, `MountAlignment` |
| `AttitudeESKF.swift` | new | live filter (§8) |
| `AttitudeSmoother.swift` | new | RTS backward pass (§9) |
| `GradeBaseline.swift` | new | slow road-grade reference (§8.6) |
| `EventSegmenter.swift` | new | §10 |
| `RunScorer.swift` | new | §11 |
| `IntervalDetector.swift` | new | §11.2, ui-spec §9.6 |
| `CueEngine.swift` | new | §12 |
| `QualityMonitor.swift` | new | §14 high-frequency indicator, flags |
| `Pipeline.swift` | new | composition + `PipelineOutput` (§4) |
| `RunProjection.swift` | new | core → ui-spec bridge inputs (§13) |
| `IntegrityReport.swift` | new | §15.4 |

### 3.2 App target — ui-spec §13 tree, with the service layer bound

ui-spec §13's file list is adopted verbatim. The binding of its `Services/` layer:

| ui-spec service | Implementation | Talks to core via |
|---|---|---|
| `MotionService` | `CMMotionManager` raw gyro + accel at 100 Hz, `CMDeviceMotion(.xArbitraryZVertical)` alongside | emits `Sample.imu` |
| `SpeedService` | `CLLocationManager` | emits `Sample.gnss` |
| `CalibrationService` | thin wrapper over core `BiasEstimator` + `AlignmentSolver` | publishes `CalibrationState` |
| `RunRecorder` | `SessionWriter` actor + `Pipeline` host | consumes `PipelineOutput` |
| `RunRepository` | file-backed store (§15) | reads/writes `WheelieRun` |

Added to that tree (no ui-spec conflict — these are services and screens the ui
spec does not cover):

```
Services/
  SessionWriter.swift        append-only NDJSON writer actor
  SessionRecovery.swift      partial-session repair
  CueAudioRenderer.swift     AVAudioEngine source node, lock-free CueState read
  VibrationRecorder.swift    vibration-mode mic capture (the only mic use)
  BikeProfileStore.swift
Features/Setup/
  BikeProfileSetupView.swift mount-alignment gestures live here, not in the
                             Live overlay (R6.11)
Features/Session/
  RecordingModeView.swift    ride / bench / vibration selection (R3.1)
```

## 4. The stream and the pipeline

`Sample` remains the single tagged stream. The pipeline is composed once and fed
one sample at a time; it is a value type so replay and live are the same code
path (R1.3, R1.7).

```swift
public struct PipelineOutput: Codable, Sendable {
    public var time: TimeInterval
    public var attitude: Quaternion
    /// Axis elevation above horizontal, radians, grade-corrected.
    public var pitch: Double
    public var pitchRate: Double
    public var roll: Double
    public var gyroBias: Vector3
    /// 1σ on pitch, radians.
    public var pitchSigma: Double
    public var gate: ValidityGate.Verdict
    /// Most recent valid GNSS ground speed, m/s; nil until the first fix.
    public var speed: Double?
    public var cue: CueState
    public var eventTransition: EventTransition?
    public var quality: QualityFlags
}

public struct Pipeline {
    public init(config: Config,
                alignment: MountAlignment,
                initialBias: BiasEstimate?)

    /// Returns output on `.imu` samples — the 100 Hz spine. `.gnss`, `.baro`
    /// and `.wheelSpeed` update internal state and return nil, per Stage's
    /// documented nil convention.
    public mutating func process(_ sample: Sample) -> PipelineOutput?

    public var integrity: IntegrityAccumulator { get }
}
```

Ordering inside `process(.imu:)`:

1. `QualityMonitor` — saturation, high-frequency indicator.
2. `ValidityGate` — verdict for this sample.
3. `AttitudeESKF.propagate` then conditional `update` (gravity, and any GNSS
   measurement whose `fixTime` falls in the delayed-state window, §8.5).
4. `GradeBaseline` — updates only while the gate is open; subtracted to give
   reported pitch.
5. `EventSegmenter` — consumes grade-corrected pitch and pitch rate.
6. `CueEngine` — consumes pitch, pitch rate, target, and the segmenter's state.

`.gnss` samples are buffered, not applied immediately, because their `fixTime` is
in the past (§8.5).

## 5. Numeric primitives

Accelerate is unavailable in core, so the linear algebra is fixed-size, explicit,
and small. No general matrix type, no dynamic allocation in the hot path.

```swift
public struct Matrix3: Equatable, Sendable {          // row-major, 9 stored
    public var m: (Double, Double, Double,
                   Double, Double, Double,
                   Double, Double, Double)
    public static func * (a: Matrix3, b: Matrix3) -> Matrix3
    public static func * (a: Matrix3, v: Vector3) -> Vector3
    public var transposed: Matrix3 { get }
    /// Analytic inverse via adjugate; returns nil when |det| < 1e-12.
    public func inverted() -> Matrix3?
}

/// Skew-symmetric matrix of v, i.e. [v]× such that [v]× w == v.cross(w).
public func skew(_ v: Vector3) -> Matrix3

public struct Matrix6: Sendable {                     // row-major, 36 stored
    public static func * (a: Matrix6, b: Matrix6) -> Matrix6
    public var transposed: Matrix6 { get }
    public static let identity: Matrix6
}

/// 6×6 symmetric positive-definite covariance. Stored full but symmetrised
/// after every update, because asymmetry is how a Kalman filter dies quietly.
public struct Symmetric6: Sendable {
    public var m: Matrix6
    public mutating func symmetrise()          // m ← (m + mᵀ)/2
    /// Cholesky factorisation; nil if not positive definite.
    public func cholesky() -> Matrix6?
    /// Solves self · X = B for X using the Cholesky factor. Used by the
    /// smoother, which needs P⁻¹ and must never form it explicitly.
    public func solve(_ b: Matrix6) -> Matrix6?
}
```

Numerical hygiene rules, each with a test:

- Covariance is symmetrised after every update.
- Joseph-form covariance update `P ← (I−KH)P(I−KH)ᵀ + KRKᵀ` rather than the
  short form, because the short form loses symmetry and positive-definiteness
  over 180 000 sequential updates.
- The quaternion is renormalised every sample (`Quaternion.normalized` exists).
- Cholesky failure is a hard, reported condition, not a silent fallback: the
  filter marks the run `estimatorDegraded` and the pipeline keeps running on
  gyro integration alone with inflated `pitchSigma`.

## 6. Calibration

```swift
public struct BiasEstimate: Codable, Sendable, Identifiable {
    public let id: UUID
    public var bias: Vector3            // rad/s
    public var sigma: Vector3           // rad/s, per axis
    public var sampleCount: Int
    public var monotonicTime: TimeInterval
    public var wallClock: Date
    public var bikeProfileID: UUID
    public var thermalStateAtCapture: Int
}

public struct BiasEstimator: Stage {
    public typealias Input = IMUSample
    public typealias Output = Progress

    public enum Progress: Sendable, Equatable {
        case collecting(elapsed: TimeInterval, required: TimeInterval)
        case rejected(ValidityGate.Reason)      // resets progress
        case done(BiasEstimate)
        case failed(Failure)
    }
    public enum Failure: Sendable, Equatable {
        case sigmaTooHigh(axis: Axis, sigma: Double)
        case vibrationTooHigh(rms: Double)
        case gateNeverOpened
    }
}
```

Mechanics. Welford accumulation of `rotationRate` over samples where the gate
verdict `isOpen` is true, restarting on any closure (R6.2). Rejecting a closure
reports `ValidityGate.Reason` straight through, which is what lets the UI say
*why* rather than spinning (ui-spec §7.2). Saturated samples are excluded before
the gate even sees them (R6.9). σ is the standard error of the mean,
`sample σ / √n`; with 8 s at 100 Hz, n = 800, and a typical consumer MEMS
`gyroNoiseDensity` of 0.004 °/s/√Hz the expected σ is ≈0.0014 °/s, comfortably
inside the 0.01 °/s acceptance of R6.4 — which means a failure there is real
signal (vibration, a running engine on a bad mount, someone sitting down), not a
tight threshold.

**Bias age and confidence.** `CalibrationStatus` carries the age and a projected
bias-drift σ:

```
σ_b(age) = √( σ_b0² + (gyroBiasInstability² · age) · thermalScale(state) )
```

`thermalScale` is 1.0 at `.nominal`, 2.0 at `.fair`, 4.0 at `.serious`,
8.0 at `.critical`, from `Config.thermalBiasNoiseScale`. Reported pitch
uncertainty over a hold of duration `t` is then dominated by `σ_b · t`, which is
the arithmetic behind C2 and is what R14.7 requires to grow monotonically.

Mapping onto ui-spec §5.3 is mechanical and lives in the app:

| Core | ui-spec `CalibrationState` |
|---|---|
| motion unavailable / permission denied | `.unavailable` |
| `Progress.collecting(elapsed, required)` | `.calibrating(progress: elapsed/required)` |
| `Progress.done(estimate)` | `.calibrated(referenceID: estimate.id, calibratedAt: estimate.wallClock)` |
| age > `biasStaleAfter`, bike changed, thermal jump | `.stale(reason:)` |
| `Progress.failed`, `Progress.rejected` past attempt window | `.failed(message:)` |

The overlay instruction is R6.10's amended sentence. Mount alignment is **not**
in this flow (R6.11) — it lives in `Features/Setup/`.

## 7. Mount alignment

Two gestures, closed form, no optimiser.

```swift
public struct MountAlignment: Codable, Sendable {
    /// Bike forward and up, expressed in DEVICE axes. These are exactly the
    /// vectors AxisElevation already takes, so nothing downstream needs a
    /// rotation matrix.
    public var forwardInBody: Vector3
    public var upInBody: Vector3
    public var residual: Double        // rad of non-orthogonality before fixup
    public var peakPullAcceleration: Double   // m/s², gesture (b) quality
    public var capturedAt: Date
    public var bikeProfileID: UUID
}
```

Solve:

1. **Rest, gate open, N ≥ 100 samples.** `f̄_rest` is the mean specific force.
   Per §2.1 specific force points along gravity, so `down = f̄_rest.normalized`
   and `up = down * -1`.
2. **Hard straight-line pull.** `Δf = f̄_pull − f̄_rest`. Per §2.1 the
   longitudinal term is `−a·cosθ`, i.e. **forward acceleration produces Δf along
   −forward**, so `forward_raw = (Δf * -1) − up * ((Δf * -1).dot(up))` —
   Δf projected off the up axis and sign-corrected.
3. **Orthonormalise.** `residual = |π/2 − angle(up, forward_raw)|`;
   Gram-Schmidt `forward = (forward_raw − up*(forward_raw.dot(up))).normalized`.
   The third axis is `up.cross(forward)` (left, per §2.1) and is stored only for
   `AxisElevation.roll`.
4. **Reject** when `peakPullAcceleration < Config.alignmentMinPullAccel`
   (0.25 g) or `residual > Config.alignmentMaxResidual` (5°) — R7.3.

Test (R7.5): `SyntheticSource.Scenario` gains `mountRotation: Quaternion`; the
generator rotates every emitted vector by it, the solver must recover axes that
reproduce `truePitch` to 0.5°.

## 8. Live estimator — ESKF

### 8.1 State

Error state, 6 dimensions. The nominal trajectory is carried outside the
covariance and never linearised away.

```
nominal:  q̂  (body→world unit quaternion),  b̂  (gyro bias, rad/s)
error:    δx = [ δθ (3) ; δb (3) ]           E[δx] = 0 by construction
error definition:   q = q̂ ⊗ exp(δθ/2)        (body-frame error)
```

Attitude error in the **body** frame is chosen because both measurements
(gravity, and forward-axis elevation) are naturally expressed there, which keeps
both Jacobians to one `skew()` call.

### 8.2 Propagation, per IMU sample

```
ω̂  = sample.rotationRate − b̂
q̂  ← (q̂ ⊗ Quaternion.exp(rotationVector: ω̂ · dt)).normalized
F  = [ −skew(ω̂)   −I₃ ]        Φ ≈ I₆ + F·dt
     [    0₃        0₃ ]
Q  = diag( σ_g²·dt·I₃ ,  σ_b²·dt·thermalScale·I₃ )
P  ← Φ P Φᵀ + Q ,  then symmetrise
```

`σ_g = Config.gyroNoiseDensity·√(1/dt)` and `σ_b = Config.gyroBiasInstability`.
The bias row of `F` is the term that makes bias observable at all: bias error
leaks into attitude error at rate 1, so any attitude measurement informs bias.
`dt` comes from consecutive sample times, clamped to
`[0.5/nominalRate, 4/nominalRate]`; a gap outside that range is a dropout, is
recorded in the integrity report, and propagates with the clamped `dt` and
inflated `Q` rather than pretending the gap did not happen.

### 8.3 Measurement 1 — gravity, 3-dimensional

Predicted specific force under quasi-static conditions, per §2.1 with `a_W = 0`:

```
f̂_B = R(q̂)ᵀ · (0, 0, −g)
r   = sample.specificForce − f̂_B
H   = [ skew(f̂_B)   0₃ ]
R_k = σ_a² · κ · I₃
```

`H` follows from `f_B(δθ) ≈ (I − skew(δθ))·f̂_B = f̂_B + skew(f̂_B)·δθ`.

The inflation factor κ is the mechanism that answers C1:

| Condition | κ (`Config`) |
|---|---|
| gate open | 1 |
| gate closed, `‖f‖` within 0.1 g of g | `accelNoiseInflation` = 100 |
| gate closed, `‖f‖` outside 0.1 g of g | `accelNoiseInflationDynamic` = 10 000 |
| `sample.saturated` | measurement **skipped** entirely |

Inflating rather than dropping keeps the filter continuous — a hard on/off
schedule injects a step into the covariance every time a bump closes the gate,
and steps are what make an angle readout jump. At κ = 10 000 the measurement's
weight is ~1e-4 of nominal, which is off in every practical sense while leaving
the filter's long-run tilt observable.

### 8.4 Measurement 2 — GNSS-aided pitch, scalar

This is the measurement that makes the run-up informative, and it is the
non-obvious part of the design. Per §2.1 the longitudinal specific force is

```
f_x = −g·sinθ − a·cosθ
```

GNSS gives `a` independently of the IMU: differentiate consecutive Doppler
speeds. Therefore

```
z    = −f_x − a_gnss·cos θ̂            (measured)
h(x) = g·sinθ(x)                       (predicted)
H    = [ −g · ê_zᵀ · R(q̂) · skew(x̂_B)   0₃ ]
```

derived from `θ = asin(ê_z · R(q) x̂_B)`; the `1/cosθ̂` from the `asin`
derivative cancels against the `g·cosθ̂` in `∂h/∂θ`, so no small-angle
approximation and no singularity at large θ.

Why it matters: the accelerometer alone cannot separate tilt from thrust (C1),
but the accelerometer *plus an independent acceleration measurement* can — the
difference is the gravity projection. Noise budget with
`speedAccuracy = 0.1 m/s` at `Δt = 1 s`:

```
σ_a  = √2 · σ_v / Δt          = 0.141 m/s²
σ_z  = √(σ_a² + σ_fx²)        ≈ 0.15 m/s²
→ angle equivalent σ_z / g    ≈ 0.0153 rad ≈ 0.88°
```

A ~0.9° pitch observation once per second, available **during acceleration**,
which is exactly when the gravity anchor is not. Over a 30 s straight-line run-up
that is 30 such observations constraining a bias state — the mechanism by which
"accuracy is decided during the boring run-up" (C2) actually happens.

Gating, honestly stated: at 1 Hz with ~0.25 s latency this measurement cannot
track a 1.2 s wheelie ramp, and `a_gnss` from a Doppler difference straddling the
onset is meaningless. So the measurement is **suppressed while the segmenter
reports an active event or within `Config.gnssAidingEventMargin` (1.0 s) of one**,
and suppressed when `!fix.isSpeedValid` or `speedAccuracy > 0.5 m/s`. Its job is
bias containment before the event, not tracking during it.

### 8.5 GNSS latency — delayed-state application

`GNSSFix.fixTime` precedes `arrivalTime` by 100–400 ms (R2.5 makes this
measurable, not assumed). Applying a fix to the current state smears a
0.25 s-old observation onto the present, which at 30 °/s is 7.5° of attitude.

Design: a ring buffer of the last `Config.delayedStateWindow` (2.0 s = 200
entries) of `(time, q̂, b̂, P, ω̂)`. On a fix, find the buffered state bracketing
`fixTime`, apply the update there, then **re-propagate forward** through the
buffered `ω̂` sequence to the present. Cost: 200 six-state propagations ≈ 200
`Matrix6` multiplies, ~50 µs — negligible at 1 Hz, and exactly reproducible on
replay, which the alternative (a latency-inflated `R`) is not in the same way.
A fix older than the window is discarded and counted in the integrity report.

### 8.6 Grade baseline

Reported wheelie angle is relative to the road, not to the geoid, so a constant
grade must not read as pitch (R8.8).

```swift
public struct GradeBaseline: Stage {
    /// First-order low-pass over gate-open pitch, τ = Config.baselineTimeConstant
    /// (25 s). Updated ONLY while the gate is open, frozen otherwise — which is
    /// what stops a wheelie from being absorbed into its own reference.
    public mutating func process(_ input: (pitch: Double, gateOpen: Bool)) -> Double?
}
```

Freezing while the gate is closed is the whole trick: a 25 s time constant would
otherwise eat a 10 s hold. Baro (`BaroSample.correctedAltitude(speed:k:)`) is
**not** used for grade in v1 — `baroDynamicPressureK` needs a per-mount
calibration we have no procedure for yet, and the gate-open pitch reference is
sufficient. The field stays in `Config` and the channel stays logged.

### 8.7 Outputs and budget

`pitchSigma` is read from `P` by projecting the attitude block onto the pitch
direction: `σ_θ = √(hᵀ P₃ₓ₃ h)` with `h` the pitch row of §8.4's `H` normalised.
Per-sample cost target < 200 µs (R8.10): the dominant term is two `Matrix6`
multiplies in propagation (~2×216 flops) plus a 3×3 inverse per gravity update.
Measured on device in the M3 task; if it exceeds budget the first lever is
propagating `P` at 50 Hz while integrating `q̂` at 100 Hz, which is stated here
so it is a planned fallback rather than an improvisation.

## 9. Post-ride smoother — RTS

### 9.1 Recursion

Forward pass stores, per sample: `q̂ₖ|ₖ`, `b̂ₖ|ₖ`, `Pₖ|ₖ`, `Pₖ₊₁|ₖ`, `ω̂ₖ`.
Backward, from N−1 down to 0:

```
Cₖ      = Pₖ|ₖ Φₖᵀ (Pₖ₊₁|ₖ)⁻¹                 // via Symmetric6.solve, never an explicit inverse
δx̂ₖ|N  = Cₖ · δx̂ₖ₊₁|N                          // error-state form: δx̂ₖ|ₖ ≡ 0 after each update
Pₖ|N    = Pₖ|ₖ + Cₖ (Pₖ₊₁|N − Pₖ₊₁|ₖ) Cₖᵀ
```

Because the forward filter resets the error state to zero after every update, the
smoothed correction is applied to the **stored nominal**:

```
qₖ|N = q̂ₖ|ₖ ⊗ Quaternion.exp(rotationVector: δθₖ|N)
bₖ|N = b̂ₖ|ₖ + δbₖ|N
```

This is what "the landing corrects the event" means mechanically: after the
wheelie the gate reopens, a sequence of κ=1 gravity updates pins attitude and
bias tightly, and `Cₖ` carries that backward through the event where no
measurement was admissible.

### 9.2 Memory, and why smoothing is windowed

Per-sample storage: `q̂` 4 + `b̂` 3 + `Pₖ|ₖ` 21 (upper triangle) + `Pₖ₊₁|ₖ` 21 +
`ω̂` 3 = 52 doubles = **416 B**.

| Span | Samples | Storage |
|---|---:|---:|
| One event + 10 s margin either side (≈30 s) | 3 000 | 1.25 MB |
| Whole 30-min session | 180 000 | **74.9 MB** |

74.9 MB of transient allocation on a phone during a post-ride pass is a jetsam
risk for no benefit, because RTS information decays over a few filter time
constants and nothing 20 minutes later informs this event. So smoothing runs
per-event over `[onset − margin, end + margin]` with
`Config.smootherWindowMargin` = 10 s, requiring the window to contain at least
`Config.smootherMinAnchorSamples` (200) gate-open samples **after** the event —
if it does not, the run is marked `smoothingUnavailable` (R9.7) rather than
smoothed against nothing.

Windowing is also what makes the 30 s completion budget (R9.6) easy: per event
the pass is ~3 000 × (a few `Matrix6` products) ≈ 10 ms.

## 10. Segmentation

```swift
public struct EventSegmenter: Stage {
    public enum State: Sendable, Equatable { case idle, arming, active, disarming }
    public struct Transition: Sendable {
        public enum Kind { case onset(TimeInterval), end(TimeInterval), discarded(TimeInterval) }
        public var kind: Kind
        public var confidence: Confidence
    }
}
```

State machine, thresholds all from `Config` (R10.1–R10.3):

```
idle      --pitch > eventEntryPitch (8°)--------------> arming   (mark candidate t)
arming    --held ≥ eventEntryDwell (150 ms)-----------> active   (onset = interpolated crossing)
arming    --pitch drops below---------------------------> idle
active    --pitch < eventExitPitch (5°)---------------> disarming
disarming --held ≥ eventExitDwell (250 ms)------------> idle     (end = interpolated crossing)
disarming --pitch rises above exit--------------------> active
end - onset < eventMinDuration (0.4 s)  →  discarded (unless debug)
```

Boundary interpolation (R10.5), on the two samples bracketing the threshold:

```
u = (threshold − pitch[i-1]) / (pitch[i] − pitch[i-1])
t = time[i-1] + u · (time[i] − time[i-1])
```

`eventEntryPitchRate` (15 °/s) is the primary *confidence* signal rather than a
second gate: crossing it during `arming` yields `.confident`, absence yields
`.weak`. The GNSS cross-check of R10.4 upgrades confidence when IMU-derived and
GNSS-derived longitudinal acceleration diverge as thrust-under-pitch predicts
(`f_x + g·sinθ̂ ≈ −a·cosθ̂` per §2.1); it never vetoes, because at 1 Hz it cannot.

Determinism (R10.6) is structural: the segmenter is a value type over the same
sample sequence, so app and CLI agree by construction, and the parity test is a
regression guard rather than a hope.

## 11. Scoring and intervals

### 11.1 Metrics

```swift
public struct EventMetrics: Codable, Sendable {
    public var onset, end: TimeInterval
    public var duration: TimeInterval
    public var liveMaxAngle, smoothedMaxAngle: Double?      // rad
    public var liveMaxAngleSigma, smoothedMaxAngleSigma: Double?
    public var averageHeldAngle: Double                     // rad, hold window only
    public var angleStdDev: Double                          // rad, consistency
    public var distance: Double                             // m, GNSS-integrated
    public var entrySpeed: Double                           // m/s
    public var rollMin, rollMax: Double                     // rad
    public var timeInAngleBand: Double
    public var flags: QualityFlags
}
```

The **hold window** (R11.2) is `[end of rise, start of descent]`, found by the
last zero crossing of pitch rate after onset and the first before end, with a
`Config.holdRateEpsilon` deadband so vibration does not produce spurious
crossings. `angleStdDev` over the full event would measure the ramp, not the
rider's steadiness, which is the metric's whole point.

`distance` integrates GNSS speed over the event by trapezoid on `fixTime`; with
1 Hz fixes a 5 s event has ~6 samples, so the value carries
`Config.distanceMinFixes` (4) as a validity floor and reports nil below it rather
than a fabricated number.

### 11.2 Interval detection

ui-spec §9.6 is the specification; this is its type.

```swift
public struct IntervalDetector {
    public init(range: ClosedRange<Double>,
                minDuration: TimeInterval,      // Config.intervalMinDuration 0.15
                mergeGap: TimeInterval)         // Config.intervalMergeGap 0.10
    public func intervals(over series: [(time: TimeInterval, value: Double)])
        -> [(start: TimeInterval, end: TimeInterval)]
}
```

Order of operations is load-bearing and matches ui-spec §9.6 exactly: detect raw
in-range spans with interpolated boundaries → **merge** gaps ≤ 0.10 s → **then**
drop fragments < 0.15 s. Merging before filtering is what stops jitter around a
band edge from being deleted as three fragments when it is one real interval;
filtering first would delete them and then have nothing to merge. Run against ui
spec §17 fixtures 5, 6, 7 (R12.7).

Computed once at finalisation (R12.4), against the run's stored snapshot, never
current preferences (R12.5).

## 12. Cue engine

```swift
public struct CueState: Codable, Sendable, Equatable {
    public enum Tone: String, Codable, Sendable { case silent, approach, loopOut }
    public var tone: Tone
    /// 0…1 urgency; the renderer maps it to frequency and amplitude.
    public var urgency: Double
    /// Seconds to the target's upper bound, nil when not closing.
    public var timeToThreshold: TimeInterval?
}

public struct CueEngine: Stage { /* Input: (pitch, pitchRate, event state) */ }
```

Decision, per sample:

1. `ttt = AxisElevation.timeToThreshold(current: pitch, rate: pitchRate, target: angleTarget.upper)`
   — the existing function, unchanged. Nil (not closing, or already past) ⇒ this
   channel is silent, which is R13.3's "creep up slowly stays quiet" for free.
2. Lead time `L = Config.timeToThresholdWarn (0.4) + Config.audioLatencyCompensation`.
   The renderer supplies a measured route latency which replaces the config
   default when available (§16.3).
3. `tone = .approach` when `ttt ≤ L`, with `urgency = 1 − ttt/L`, so frequency
   rises as time runs out — self-scaling in exactly the way R13.3 requires,
   because a fast approach reaches a given `ttt` further from the threshold.
4. `pitchRate > Config.loopOutPitchRate` ⇒ `tone = .loopOut`, which **preempts**
   `.approach` (R13.4). Distinct timbre, not merely a higher pitch of the same
   tone — the renderer uses a different waveform and an interrupted envelope so
   the two are unmistakable through a helmet.
5. Hysteresis: once sounding, a tone persists until its condition has been false
   for `Config.cueReleaseTime` (0.15 s). Without it a tone chatters on and off
   across the boundary at 100 Hz, which is worse than useless at speed.

The engine returns a value; it does not make sound. That is what allows
`motolog replay --cues` to print the exact cue timeline for a recorded ride
(R13.7) and lets a test assert "no cue below 3 °/s, cue ≥0.35 s early at 60 °/s"
with no audio hardware.

## 13. Bridge to the ui-spec data contracts

Core stays SI, monotonic, radians. The ui-spec types stay exactly as ui-spec §5.1
declares them. One mapper crosses the boundary, once, at finalisation.

```swift
// Core, pure: SI units, monotonic time.
public struct RunRecord: Codable, Sendable {
    public var id: UUID
    public var sessionID: String
    public var span: SessionSpan                  // R19.4 reference into the raw log
    public var metrics: EventMetrics
    public var display: [DisplayPoint]            // decimated, SI
    public var angleIntervals, speedIntervals: [(TimeInterval, TimeInterval)]
    public var snapshot: TargetSnapshot           // SI copy of the targets in force
    public var configVersion: Int
    public var flags: QualityFlags
}

public struct DisplayPoint: Codable, Sendable {
    public var elapsed: TimeInterval
    public var pitch: Double        // rad
    public var speed: Double        // m/s
}
```

Field-by-field mapping, performed by `RunMapper` in the app's `Models/` layer:

| ui-spec type / field | Source | Conversion |
|---|---|---|
| `TelemetrySample.elapsed` | `DisplayPoint.elapsed` | none |
| `TelemetrySample.angleDegrees` | `DisplayPoint.pitch` | `× 180/π` |
| `TelemetrySample.speedKPH` | `DisplayPoint.speed` | `× 3.6` |
| `WheelieRun.id` | `RunRecord.id` | none |
| `WheelieRun.startedAt/endedAt` | `LogHeader.startedAt + span` | monotonic → wall clock via the session's single anchor (R2.4) |
| `WheelieRun.samples` | `RunRecord.display` | decimated series (R19.4) |
| `WheelieRun.duration` | `metrics.duration` | none |
| `WheelieRun.maxAngle` | `metrics.smoothedMaxAngle ?? liveMaxAngle` | `× 180/π`; the UI labels which |
| `WheelieRun.maxSpeed` / `averageSpeed` | `metrics` | `× 3.6` |
| `WheelieRun.angleIntervals` / `speedIntervals` | `RunRecord` | wrap in `RangeInterval` with `MetricKind` + fresh `UUID` |
| `RunConfigurationSnapshot.angleTarget` | `snapshot.angle` | rad → deg into `MetricRange` |
| `RunConfigurationSnapshot.speedTarget` / `speedGaugeMaximum` | `snapshot` | m/s → km/h |
| `RunConfigurationSnapshot.calibrationID` | `BiasEstimate.id` | none |
| `CalibrationState` | `CalibrationStatus` | §6 table |
| `RiderPreferences` | app-owned | stored in display units per ui-spec §5.2; converted to SI when building `TargetSnapshot` |

`WheelieRun.maxAngle` deliberately reads from the smoothed value when present
(R9.4) while `WheelieRun.samples` is the live display series — the hero number and
the trace can differ by up to ~1.5°, which is not a bug and is why R9.4 requires
the UI to state which number it is showing.

Extended fields (`angleStdDev`, `entrySpeed`, roll envelope, `flags`,
`timeInAngleBand`) hang off a sidecar `RunExtras` keyed by run id, so the ui-spec
`WheelieRun` shape is not mutated and ui-spec §16's criteria stay checkable
against the type they were written for.

## 14. Quality monitoring

```swift
public struct QualityFlags: OptionSet, Codable, Sendable {
    public static let saturatedInEvent, highVibration, aliasingSuspect,
                      lowRate, gapExceeded, recovered, smoothingUnavailable,
                      estimatorDegraded, lowConfidence: QualityFlags
}
```

The high-frequency indicator (R14.1) is a per-second RMS of the specific-force
residual above `Config.highFreqCutoff` (20 Hz), obtained with a one-pole
high-pass in the core (no FFT, no Accelerate):

```
hp[n] = α·(hp[n-1] + f[n] − f[n-1]),  α = 1/(1 + 2π·fc·dt)
rms    = √(mean(hp²)) over a 1 s window
```

Compared against `Config.highFreqRMSThreshold`. Above it: calibration fails
(R14.2), the interval is recorded (R14.3), and the UI names mechanical isolation
as the fix — never a software toggle, per C3.

`aliasingSuspect` (R14.4) is assigned by matching the ride's indicator and
gate-open baseline shift against the bike profile's marked bands. The profile is
built by `motolog fft` from a `vibration` recording, where audio provides the
unaliased firing frequency (R3.4) — the ride itself only ever sees the symptom.

`lowConfidence` is set when live σ > 3° or smoothed σ > 1.5° (R14.7), or on
`saturatedInEvent`, `lowRate`, or `gapExceeded` (R4.5). Flagged runs are excluded
from personal-best anchors (R18.3), which is why ui-spec §8.4's colour anchors
read from the filtered set.

## 15. Persistence

### 15.1 Layout

```
Application Support/
  Sessions/<sessionID>/
    session.ndjson          append-only, LogHeader line + Sample lines
    manifest.json           mode, files, sizes, sha256, completion state
    audio.caf               vibration mode only
  Runs/<runID>.json         WheelieRun (ui-spec shape)
  RunExtras/<runID>.json
  Profiles/bikes.json
  Profiles/calibrations.json
  preferences.json
  schema.json              { schemaVersion: Int }
```

### 15.2 Writer

```swift
actor SessionWriter {
    func open(header: LogHeader, mode: RecordingMode) throws
    nonisolated func enqueue(_ encoded: Data)      // never blocks the caller
    func close() async throws
}
```

- The sensor callback encodes the `Sample` and pushes into a single-producer
  single-consumer ring buffer of `Config.writerRingCapacity` (8192 samples ≈ 80 s
  of headroom). **Overwrite is forbidden**: a full buffer increments a dropped
  counter that surfaces in the integrity report and must be 0 for a session to
  be non-`lowConfidence`. Silently dropping raw samples would violate R2.2's
  whole point.
- The writer drains in batches, appending with `O_APPEND`, and `fsync`s on a
  `Config.fsyncInterval` (1.0 s) cadence — which is precisely R4.2's "loses at
  most 1 s".
- `manifest.json` is written atomically (temp + `rename(2)`) on open, on each
  fsync boundary with updated sizes, and on close with `complete: true`.

### 15.3 Recovery

On launch, any `Sessions/*` whose manifest lacks `complete: true` is repaired
(R4.3): scan `session.ndjson`, discard a trailing line with no terminating
newline, recompute sizes and checksums, write a manifest with
`recovered: true`, set the `recovered` flag on derived runs. The reader used here
is a **streaming** line reader added to `LogFile` — the committed
`LogFile.read(contentsOf:)` loads the whole file as a `String`, which is fine for
its documented 30-min/16 KB-s case but not for repairing a truncated file, and
not for the smoother's windowed reads (§9.2). `read(contentsOf:)` stays for the
CLI and tests; `LogFile.stream(url:)` is added for the app.

### 15.4 Integrity report

Accumulated during recording by `IntegrityAccumulator`, serialised into the
manifest: per-channel achieved vs nominal rate, gap count and max gap,
saturated-sample count, thermal timeline, GNSS fix count and median
`arrivalTime − fixTime`, discarded-late-fix count, writer drop count, sync-flash
timestamp, battery delta (R19.6). Queryable by `motolog verify` and rendered in
the app (R4.6).

## 16. App target architecture

### 16.1 Threading

| Work | Where | Rule |
|---|---|---|
| CoreMotion / CoreLocation callbacks | CM's `OperationQueue`, one serial queue | encode + `Pipeline.process` inline (~200 µs, budget 10 ms) |
| Disk | `SessionWriter` actor | never touched from the sensor queue except a non-blocking ring push |
| Audio render | CoreAudio real-time thread | reads the latest `CueState` from an atomic snapshot; no locks, no allocation, no Swift concurrency |
| UI | `@MainActor` view models | fed a throttled 30 Hz publication (ui-spec §12) |
| Smoothing / scoring | detached task | off-main, progress reported (R9.6) |

Running the pipeline synchronously on the sensor queue is a deliberate choice
over an `AsyncStream` hop: the cue engine's value is its latency budget (R13.6,
<120 ms end to end), and an actor hop plus scheduling jitter spends a chunk of
that for no benefit, given the work is bounded and allocation-free.

### 16.2 Sensor adapters

`CMMotionManager` with `gyroUpdateInterval` and `accelerometerUpdateInterval` at
`1/100`, plus `deviceMotion(using: .xArbitraryZVertical)` — all three, so raw is
recorded alongside fused (R2.1) and never replaced by it. Raw gyro and accel
arrive on separate callbacks; they are paired into one `IMUSample` by nearest
timestamp within half a sample period, and an unpaired sample is emitted with the
missing channel zero-filled **and** counted in the integrity report rather than
being dropped or interpolated.

`saturated` (R2.3) is set by comparing each axis against the configured
full-scale values in `Config.gyroFullScale` / `accelFullScale` with a 1% margin.

### 16.3 Cue renderer

`AVAudioEngine` with an `AVAudioSourceNode` generating the tone procedurally —
no sample assets, no third-party audio (R1.2). Session category
`.playback` with `.mixWithOthers`, `UIBackgroundModes = audio` (R19.1). Route
latency is read from `AVAudioSession.outputLatency` plus `.ioBufferDuration`,
classified as wired / HFP / A2DP from the route description, surfaced to the
rider when A2DP (R13.6), and fed back into the cue engine's lead constant.

### 16.4 Recording modes

`ride` and `bench` never instantiate `VibrationRecorder`, so the microphone is
not merely unused — it is unreachable, and the permission is requested lazily on
first `vibration` recording (R19.2).

## 17. `Config` version 2

Existing fields keep their names and meanings. Changes and additions:

| Field | Value | Requirement |
|---|---|---|
| `version` | 1 → **2** | R1.9 |
| `eventExitPitch` | 4° → **5°** | R10.2 |
| `eventEntryDwell` | 0.15 s | R10.1 |
| `eventExitDwell` | 0.25 s | R10.2 |
| `accelNoiseInflation` | 100 | R8.2 |
| `accelNoiseInflationDynamic` | 10 000 | §8.3 |
| `accelDynamicThreshold` | 0.1 g | R8.2 |
| `delayedStateWindow` | 2.0 s | §8.5 |
| `gnssAidingEventMargin` | 1.0 s | §8.4 |
| `gnssMaxSpeedAccuracy` | 0.5 m/s | §8.4 |
| `thermalBiasNoiseScale` | [1, 2, 4, 8] | R8.4 |
| `biasSigmaLimit` | 0.01 °/s | R6.4 |
| `alignmentMinPullAccel` | 0.25 g | R7.3 |
| `alignmentMaxResidual` | 5° | §7 |
| `smootherWindowMargin` | 10 s | §9.2 |
| `smootherMinAnchorSamples` | 200 | R9.7 |
| `holdRateEpsilon` | 1 °/s | R11.2 |
| `distanceMinFixes` | 4 | §11.1 |
| `intervalMinDuration` | 0.15 s | R12.3 |
| `intervalMergeGap` | 0.10 s | R12.3 |
| `loopOutPitchRate` | 60 °/s | R13.4 |
| `cueReleaseTime` | 0.15 s | §12 |
| `highFreqCutoff` | 20 Hz | R14.1 |
| `highFreqRMSThreshold` | 1.5 m/s² | R14.1 |
| `liveSigmaLimit` / `smoothedSigmaLimit` | 3° / 1.5° | R14.7 |
| `displayDecimationRate` | 30 Hz | R19.4 |
| `writerRingCapacity` | 8192 | §15.2 |
| `fsyncInterval` | 1.0 s | R4.2 |
| `syncFlashFrames` | 6 | R2.13 |
| `gyroFullScale` / `accelFullScale` | 2000 °/s / 16 g | §16.2 |
| `nominalSampleRate` | 100 Hz | R2.9 |

Decoding a `version: 1` header supplies v2 defaults for absent fields (R1.9);
`motolog` prints both the header version and any override (R20.2).

## 18. CLI

```
motolog synth  [--peak deg] [--bias degps] [--grade deg] [--vib amp,hz]
motolog replay <session> [--config file] [--stages out.ndjson] [--cues] [--json]
motolog verify <session>            integrity report + exit non-zero on failure
motolog fft    <session>            vibration profile from a `vibration` recording
motolog allan  <session>            ARW + bias instability from a `bench` recording
motolog parity <fixture-dir>        the R20.7 app/CLI equality check
```

`fft` and `allan` import Accelerate (legal per §1). `fft` segments the recording
by the rider's held RPM bands, takes the audio track's dominant firing frequency
per band as the unaliased truth, computes the IMU's aliased image
`|f_true − round(f_true/f_s)·f_s|`, and reports the gate-open baseline shift per
band as the phantom-tilt offset — emitting the `VibrationProfile` of R3.5.

## 19. Error handling → ui-spec §15

| Condition | Behaviour |
|---|---|
| Location denied/unavailable | `speed = nil` throughout; UI shows unavailable, never 0; GNSS aiding off; distance nil |
| Motion unavailable | calibration and recording blocked, retry offered |
| Calibration lost mid-run | run finalised with `lowConfidence` + reason; never presented as normal |
| Corrupt samples in a stored run | hero metrics from stored values, charts replaced by `Telemetry unavailable` |
| Raw log deleted | decimated series + reduced-fidelity label; re-smoothing disabled (R19.4) |
| Missing snapshot in migrated data | marked legacy fallback, disclosed |
| Empty interval set | single muted baseline + `No time in configured ranges` |
| Cholesky failure | `estimatorDegraded`, gyro-only with inflated σ |
| Writer ring full | drop counter → `lowConfidence`; surfaced, never silent |

## 20. Test architecture

- **Purity** (R1.1): a test shelling `grep -rE "^import (CoreMotion|CoreLocation|UIKit|SwiftUI|AVFoundation|Accelerate)" Sources/MotoTelemetryCore` and failing on any hit.
- **Convention guard** (§2.2): integrate the generator's gyro through
  `Quaternion.exp`, assert tracked pitch matches `truePitch` within 0.1°.
  This test must exist before the ESKF.
- **Determinism** (R1.7): run a fixture twice, compare encoded `PipelineOutput`
  byte for byte.
- **Scenario matrix** (R21.2): peak {30, 45, 70}° × bias {0.05, 0.3, 0.5} °/s ×
  grade {0, ±4}° × vibration {0, 83 Hz, 100 Hz} × GNSS {on, off}, asserting live
  ≤2° and smoothed ≤0.5°. The 100 Hz cell asserts **disclosure**, not accuracy
  (R21.3) — asserting an accurate angle through an aliased channel would encode a
  false claim in the suite.
- **Parity** (R20.7): one fixture runner used by both XCTest and
  `motolog parity`, so the two paths cannot drift apart quietly.
- **Interval/colour units** (R21.6): ui-spec §17 fixtures 5–8 including
  all-values-equal.
- **Recovery** (R4.2): truncate a fixture mid-line, assert only the partial line
  is lost.

## 21. Risks

1. **The generator defect (§2.2) invalidates the accuracy suite until fixed.**
   Highest-priority item; it precedes M3.
2. **GNSS aiding rests on `speedAccuracy` being honest.** If CoreLocation
   reports optimistic accuracy the measurement is over-weighted and drags pitch.
   Mitigation: the M1 ride logs both, and M3 compares GNSS-derived acceleration
   against IMU during known-level cruising before the aiding is enabled by
   default.
3. **100 Hz raw pairing may not be what iOS actually delivers.** If raw gyro and
   accel timestamps do not interleave cleanly the pairing in §16.2 degrades.
   Measured in M1; the fallback is to log both channels unpaired as separate
   `Sample` cases, which is a log-format change and therefore a v2 decision, not
   a quiet fix.
4. **Cue latency through a helmet intercom is unverified.** R13.6's budget is
   measurable but the perceptual question — whether a rising tone is legible at
   speed with wind noise — is not settled by any test here and needs the M6 ride.
