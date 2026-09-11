# K12: Pitch uncertainty contract — proposed, awaiting measurement-design review

Status: specification only; no estimator, thresholds, persisted schema, or runtime behaviour changed. This document does not complete K12 implementation or validate physical accuracy.

Baseline: `db40cd2af92a57182993a2c32037c048b4f2e887`, branch `codex/k12-uncertainty-contract`, based on the polish integration branch. Scope and implementation allowlist are in [the Kiro fix plan](2026-09-11-kiro-fix-plan.md).

## Observed implementation

- `AxisElevation.pitch` reports the elevation of the estimated bike-forward axis above the world horizontal: `asin((R f).z)`. This is absolute elevation relative to the gravity anchor, not angle gained since an attempt started. It does not measure wheel contact or subtract road grade.
- `CalibrateOnceEstimator` integrates bias-subtracted gyro measurements; no measurement correction or covariance propagation occurs during the session. Its gravity anchoring establishes tilt, leaving heading arbitrary.
- `BiasEstimate.sigma` is the per-axis standard error of the calibration mean. It describes sampling uncertainty under the calibration estimator's assumptions; it is not a measurement of all residual bias, mounting error, thermal drift, or absolute angle error.
- `BiasEstimate.projectedSigma` computes `sqrt(worstSigma² + gyroBiasInstability² × age × thermalScale)`; `projectedPitchSigma` multiplies it by hold duration. Pipeline currently passes zero hold duration, yielding zero for a normal finite calibration estimate regardless of age.
- `gyroBiasInstability` is labelled rad/s in Config, while its present use as a random-walk coefficient requires rad/s/√s. Its numerical value must not be carried into a revised model without resolving the units and evidence. The thermal multiplier currently scales variance, not standard deviation, and uses the thermal state captured at calibration.
- A missing calibration estimate returns `liveSigmaLimit`. A threshold value is not an estimate of uncertainty and should not imply one.

Evidence: [Pipeline](../../Sources/MotoTelemetryCore/Pipeline.swift), [calibration](../../Sources/MotoTelemetryCore/Calibration.swift), [estimator](../../Sources/MotoTelemetryCore/CalibrateOnceEstimator.swift), [axis elevation](../../Sources/MotoTelemetryCore/AxisElevation.swift), [configuration](../../Sources/MotoTelemetryCore/Config.swift). Source comments containing device accuracy figures are not independent validation evidence.

## Proposed public semantics

The live quantity should refer to **absolute elevation error since the attitude anchor**, because that is the angle the live meter publishes. It must include pre-attempt propagation; starting or finishing an attempt does not reset absolute uncertainty.

A distinct optional quantity may describe **relative elevation change error between two specified times**. It must never be used to certify the absolute live angle, target-band membership, or maximum absolute angle. Common initial errors can cancel in a simple relative model while the absolute estimate remains wrong.

Use three distinct concepts:

1. Modelled standard deviation, with named included components and assumptions. A one-sigma value does not by itself guarantee 68% coverage; that interpretation additionally needs an appropriate error distribution and empirical validation.
2. Deterministic error allowance or bound, if independently justified. A known systematic bias is an offset, not zero-mean random noise. Do not combine a claimed bound with variances and call the result a sigma.
3. Validity and exclusions: unavailable, model-only, validated for a stated operating envelope, or invalid after a discontinuity. A small number cannot override missing coverage, stale sensors, saturation, poor alignment, or mount movement.

Recommended conceptual output: quantity kind; model revision; anchor/calibration IDs; monotonic time interval; optional standard deviation in radians; included error components; assumptions/exclusions; validity and reason codes. Names and storage layout are maintainer decisions. Legacy records with no model metadata remain unknown, rather than zero uncertainty. Quality flags remain separate from uncertainty and are handled by K08.

## Analytical reference model

The following is a proposed **one-dimensional, fixed-axis, small-error reference model**. It supplies exact test oracles under explicit assumptions; it is not an assertion that real riding obeys them.

Let calibration finish at time 0; anchor occur at calibration age A; evaluate T seconds after anchoring. All durations use the same monotonic clock. Define:

| Symbol | Meaning | Units |
|---|---|---|
| V₀ | Initial elevation-error variance at anchoring | rad² |
| σb² | Variance of constant residual bias at calibration completion | rad²/s² |
| Qg | Continuous white rate-noise intensity: angle variance added per second | rad²/s |
| Qb | Bias random-walk intensity: rate variance added per second | rad²/s³ |
| A, T | Calibration age at anchoring; time since anchor | s |

Assume zero-mean independent initial elevation error, constant calibration bias error, rate noise, and bias random walk starting at calibration completion. Further assume no unmodelled motion interval and a constant projection onto the measured pitch axis. Then:

```text
Vabsolute(A,T) = V₀ + σb² T² + Qg T + Qb (A T² + T³/3)
σabsolute = sqrt(Vabsolute)
```

Derivation: angle error integrates rate error. Constant bias contributes `σb² T²`; independent white increments contribute `Qg T`. The Brownian bias already accumulated at anchor contributes `Qb A T²`; subsequent drift contributes `Qb ∫₀ᵀ (T−u)² du = Qb T³/3`. This derivation states its independence assumptions: if the initial attitude and bias errors are correlated, their cross-covariance terms must also be propagated.

For a scalar relative change over duration H starting at calibration age S, with the same independent-increment assumptions:

```text
Vrelative(S,H) = σb² H² + Qg H + Qb (S H² + H³/3)
```

The initial additive elevation error cancels in this reference case. For arbitrary three-dimensional rotation, an initial attitude or mounting error need not cancel in the difference of two elevations; endpoint covariance and cross-covariance are required. Do not obtain relative variance by simply adding two absolute variances.

These formulae differ from multiplying the final bias sigma by elapsed time. When only bias random walk is present and A=0, that multiplication yields `Qb T³`, whereas integrating the process gives `Qb T³/3`. Substitution of session age for zero hold duration therefore does not resolve the model.

Do not infer Qg from a noise-density label without specifying the spectral convention and sampling bandwidth. For independent discrete rate errors with variance vᵢ, each held over Δtᵢ, the exact scalar angle variance is `Σ vᵢ Δtᵢ²`. Correlated samples require covariance terms; calibration SEM does not establish that independence.

## Three-dimensional applicability

An implementation intended to report general riding uncertainty should propagate a documented attitude/bias error model through the actual rotation trajectory and project onto axis elevation, including initial tilt and mount-axis uncertainty when these are available. For a world-frame small rotation error δθ and world-frame unit forward axis f = R f_body, away from vertical:

```text
J = (f × worldUp)ᵀ / sqrt(1 − f.z²)
Velevation ≈ J Pattitude Jᵀ
```

Here the error convention is `δf = δθ × f`; a different convention changes the Jacobian accordingly. Mount-axis uncertainty and covariance cross-terms are additional contributions. Near vertical the elevation map has no unique linearisation direction; a small-error Gaussian approximation needs an explicit validity envelope or nonlinear treatment, not merely denominator clamping to produce a confident answer. The maximum per-axis sigma is not generally an upper bound on an arbitrary projection when cross-axis correlations are unknown.

Implementing error covariance does not require feeding accelerometer corrections back into the estimator. These are separate design decisions. Do not introduce such corrections as part of K12 without separate scope approval.

## Clock, reset, and failure contract

- Fresh anchoring resets the attitude propagation epoch, not the age of a reused bias calibration. A fresh bias calibration resets bias age but cannot make unknown initial/mounting error zero.
- Attempt onset, exit, target edits, and UI redraws do not reset the absolute model. Relative intervals explicitly record their own endpoints.
- Nonfinite inputs, negative covariance/noise intensities, incompatible clock epochs, or missing required model parameters produce an unavailable/invalid result with a reason. Do not substitute a display threshold or silently clamp arbitrary invalid inputs to zero.
- At T=0, absolute variance is V₀; an exactly identical relative endpoint has zero increment variance in the mathematical model. Neither establishes zero physical error.
- A skipped integration gap leaves the true orientation change unknown. Mark absolute validity invalid until an explicitly supported recovery/re-anchor. Quietly advancing the noise formula cannot bound unknown motion.
- Thermal-scale changes require an explicit piecewise process model; future implementation must not retroactively apply a new scale to the entire past. More generally the random-walk contribution is the integral of the squared integration kernel against the time-varying Qb.
- UI can cap a displayed number but must retain uncapped model output/status. No rounding may turn unavailable into zero or conceal threshold exceedance.

## Synthetic acceptance cases for later implementation

The following use artificial degree-based parameters for readable arithmetic, not measured phone characteristics. Production units remain radians. Test conversion consistency separately.

| Case | Inputs | Exact expectation |
|---|---|---|
| Initial error | V₀=4 deg²; all other terms zero | sigma=2° at all T |
| Constant bias uncertainty | σb=0.02°/s; T=10 s; other terms zero | sigma=0.2° |
| White rate noise | Qg=0.0004 deg²/s; T=25 s; other terms zero | sigma=0.1° |
| Fresh bias random walk | Qb=0.000003 deg²/s³; A=0; T=10 s | variance=0.001 deg²; sigma≈0.0316227766° |
| Aged bias random walk | Same Qb; A=20; T=10 | variance=0.007 deg²; sigma≈0.0836660027° |
| Combined | V₀=0.01; σb=0.02; Qg=0.0004; Qb=0.000003; A=20; T=10 | variance=0.061 deg²; sigma≈0.2469817807° |
| Relative comparison | Previous combined parameters; S=20; H=10 | variance=0.051 deg²; sigma≈0.2258317958° |
| Known systematic residual | Fixed rate error +0.01°/s over 60 s | deterministic signed error +0.6° in the defined positive pitch direction; not a sigma |

Required further tests: partition invariance of constant-parameter propagation; irregular valid sample intervals; degree/radian conversion; known cross-covariance; monotonic nondecrease of the scalar reference variance; separate anchor versus calibration reset; no reset at attempt boundaries; stale/missing calibration; invalid/overflow inputs; gap invalidation; reproducible model identifiers; legacy unknown decoding if persisted. Full trajectory projection additionally needs known rotations, mount transforms, and a defined near-vertical rejection case. Confidence at nominal temperatures cannot stand in for these checks.

A deterministic analytical test should compare variance with combined absolute/relative tolerance justified for Double arithmetic (proposed 1e-12 in degree-based fixture units), without tuning operating thresholds. A stochastic simulator may supplement this using a fixed seed and statistically justified sampling error, but cannot replace exact cases or device validation.

## Decisions and evidence required before implementation

Maintainer review must approve the absolute-versus-relative field/API contract, model complexity, initial attitude/mount error treatment, noise parameter units and provenance, invalidation/recovery policy, storage compatibility, and UI wording. No new default noise values or acceptance thresholds are proposed here.

Physical validation requires a documented reference with known uncertainty, synchronised timestamps, independent held-out runs, representative supported phones/mounts, stationary and controlled-angle trajectories, duration and temperature sweeps, and controlled vibration and gap cases. Compare signed error, drift with age, bias, and interval coverage over the stated envelope. Report reference uncertainty and timing error separately. Specify pass criteria before fitting parameters, record calibration and model versions, and retain failure cases. Synthetic success proves implementation consistency with assumptions; physical accuracy and statistical coverage remain blocked until this evidence exists.

Handoff: this document is the review gate for the later K12 code allowlist. K08 may preserve quality/unknown status without adopting this proposed model; K03/K06 own lifecycle and gap recovery mechanisms. After model approval, claim the implementation task separately in the shared tracker before editing core code.
