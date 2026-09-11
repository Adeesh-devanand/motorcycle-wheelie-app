**Loftmeter — app and AWS deployment review**

Reviewed 11 September 2026. Repository: Adeesh-devanand/motorcycle-wheelie-app.

The application review covers beta/calibrate-once at f91ef3789cd944c25f2ccd21cce75759a3edf6ad. I separately reviewed the updated meter branch at 357f84df483938bb828ffd81e2166c3c73e06971. Your correction explicitly anchors the fill to the bottom of the full-height track; the regression from my earlier styling change is treated as resolved. That correction is on the open meter PR, not yet on the beta branch. All other findings below concern the beta implementation.

This is a source and deployed-configuration review. I traced sensor ingestion, calibration, estimation, event detection, display updates, persistence, history, charts, audio, tests, and diagnostic uploads. I inspected the AWS stack using read-only calls and sampled small prefixes of two uploaded raw logs. There is no Swift compiler, Xcode, or iOS simulator in this environment; I did not run the test suite or verify device rendering, physical accuracy, battery consumption, or background continuity. The source-observed defects below include concrete reproduction scenarios for device/integration validation. No app or AWS configuration was changed.

**My assessment is that this is a promising specialist instrument with an uneven level of maturity.** The separation between the signal-processing core and iOS adapters is good. The core has substantial deterministic tests and useful diagnostic tooling. The main weaknesses are in the orchestration around that core: multiple representations of state disagree, quality information does not reach saved results, and error recovery is incomplete. These are repairable without a rewrite.

| Aspect | Assessment |
| --- | --- |
| Product focus | Strong: live angle, optional speed, automatic attempts, and post-run analysis make a coherent product. |
| Measurement design | Thoughtful, but long-session accuracy and uncertainty need physical validation and better product disclosure. |
| Core code | Good decomposition and substantial tests; some tested capabilities are not connected to the app. |
| App architecture | Reasonable starting boundaries; recording/session ownership needs consolidation. |
| Reliability | Several important silent-failure and lifecycle paths remain. |
| User experience | Distinctive and focused; readiness, feedback, recovery, and post-run clarity need work. |
| AWS | Appropriately small serverless stack, operating successfully at current load; privacy and operational controls need improvement. |
| Release readiness | Suitable for a closely managed beta; I would resolve the high-priority findings before broad distribution. |

**What is done well is worth preserving.**

The Foundation-only MotoTelemetryCore package separates mathematics from SwiftUI, Core Motion, and Core Location. Quaternion integration, coordinate conventions, calibration, segmentation, quality monitoring, interval detection, and downsampling have distinct implementations. Keeping radians and metres per second in the core and converting at the UI boundary is sensible. Dependencies are minimal. [Package.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Package.swift)

ServiceGraph gives the app shared service instances rather than creating new sensors for each screen. Main-actor display snapshots at 30 Hz coalesce the higher-rate sensor stream, and display smoothing is separate from recorded samples. That is the right direction for responsiveness and measurement fidelity. [RootTabView.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryApp/App/RootTabView.swift#L95-L125) [RunRecorder.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryApp/Services/RunRecorder.swift#L537-L565)

Calibration includes stillness, bias, and vibration checks. Event segmentation has thresholds and dwell states rather than interpreting every noisy crossing as a separate wheelie. The recorded-angle blur preserves raw values and records when smoothing is unavailable. These are meaningful engineering choices. They need better integration, not removal. [Calibration.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryCore/Calibration.swift) [EventSegmenter.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryCore/EventSegmenter.swift) [RunRecorder.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryApp/Services/RunRecorder.swift#L775-L822)

History and details already go beyond a basic gauge: chart downsampling, a shared time cursor, target intervals, overlap selection, filters, and relative metric colouring provide useful analysis. One JSON file per run, atomic writes, compatibility handling for older records, raw trace capture, and replay tooling are proportionate choices for this app's stage. [RunDetailsViewModel.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryApp/Features/RunDetails/RunDetailsViewModel.swift) [RangeIntervalTimeline.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryApp/Features/RunDetails/RangeIntervalTimeline.swift) [RunRepository.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryApp/Services/RunRepository.swift)

The test directory contains 21 core test files and 175 test methods, including coordinate conventions, calibration, synthetic accuracy scenarios, vibration aliasing, segmentation, speed validity, wire formats, and regression cases. This count describes checked-in tests, not a passing execution result.

**The highest-priority defects affect whether the rider can trust what the app shows and saves.**

| Priority | Finding | Consequence |
| --- | --- | --- |
| P1 | Targets and speed settings are captured only when the session starts. | Live settings can disagree with the next saved attempt. |
| P1 | GNSS values never expire merely because fixes stop arriving. | Old speed can remain available and enter new records. |
| P1 | Pipeline quality flags are dropped when saving; uncertainty is calculated with zero duration. | Questionable measurements can look clean and receive personal-best treatment. |
| P1 | Sensor watchdog starts after successful calibration. | First-launch sensor silence can leave calibration waiting indefinitely. |
| P1 | Mutable processing state has inconsistent isolation. | Session promotion has a source-level race risk. |
| P1 | Save failures are logged but not returned or retained for retry. | A completed attempt can silently disappear. |
| P1 | Beta uploads contradict device-only privacy wording. | Real uploaded GPS traces are not accurately described to testers. |
| P1 | The Xcode project contains 42 developer-machine paths. | Reproducible app builds on a clean Mac are compromised. |
| P2 | Disarming is incorrectly presented as no active event. | Timer and current-attempt maxima can reset during one attempt. |
| P2 | Idle telemetry buffering has no bound. | Memory and finalisation work grow with time spent waiting. |
| P2 | Audio recovery does not retain the intended stopped/running state. | A configuration change can restart audio after a deliberate stop. |
| P2 | Raw chart values and smoothed statistics disagree. | Peaks and target totals can be confusing to explain. |

P1 means I would address it before broadening the beta or treating results as dependable. P2 means a meaningful correctness, performance, or usability improvement. These are review priorities, not measured incident frequencies.

**1. Configuration needs one clear owner and an explicit effective time.**

The live meter writes changed target bands into RiderPreferences immediately. RunRecorder stores angleTarget, speedTarget, speedGaugeMaximum, and speedEnabled at startSession, and later writes those stored values into every run. There is no corresponding update path when the rider changes preferences while the session continues. [LiveWheelieView.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryApp/Features/Live/LiveWheelieView.swift#L188-L238) [RunRecorder.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryApp/Services/RunRecorder.swift#L282-L305) [RunRecorder.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryApp/Services/RunRecorder.swift#L811-L822)

For example, start with a 35–45° target, change it to 45–55° between attempts, then record another attempt without restarting. The visible target changes, but the saved run retains the original target. Its time-in-range calculation answers the wrong question.

The speed toggle has the same mismatch. Turning it on immediately changes the UI, but a session started with speed off already cancelled its location task. Turning it off changes the UI while a session started with speed on still retains its original recording configuration. The recorder comment explicitly says re-enabling applies next session; the settings screen does not explain this delay. [SettingsView.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryApp/Features/Setup/SettingsView.swift#L24-L45) [RunRecorder.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryApp/Services/RunRecorder.swift#L349-L365)

Use one settings command path through the session coordinator. Apply changes while idle, then freeze an immutable configuration at attempt onset. If a change must wait until the next session, display that fact. Persist the configuration revision, speed-enabled state, and relevant algorithm settings with each attempt.

Acceptance check: change both targets and the speed toggle between attempts; confirm live behaviour, hardware activity, saved configuration, and detail charts all agree.

**2. Speed validity needs an age, not just an optional number.**

Pipeline replaces lastSpeed when a GNSS fix arrives, including clearing it when an explicitly invalid fix arrives. However, silence does not clear it. RunRecorder considers speed available whenever that cached value is non-nil. The existing speed tests cover an invalid fix, not a stream that stops sending anything. [Pipeline.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryCore/Pipeline.swift#L150-L165) [Pipeline.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryCore/Pipeline.swift#L200-L212) [RunRecorder.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryApp/Services/RunRecorder.swift#L648-L655)

Introduce a reading that includes value, measurement time, arrival time, accuracy, and status. Expire it using a documented age policy. Do not interpolate across long GNSS gaps in recorded analysis.

SpeedService also computes its wall-clock-to-monotonic offset from the first location's timestamp and its arrival time. This makes the first fix appear fresh even if it was cached. Derive the clock offset from contemporaneous wall-clock and uptime readings, and validate the location timestamp separately. [SpeedService.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryApp/Services/SpeedService.swift#L167-L191)

The numeric zero saved for disabled speed is an intentional current product convention. Preserve that if desired, but also save a status so disabled, unavailable, and genuinely stationary can be distinguished and excluded appropriately from statistics. Today the persisted nonoptional number loses that distinction.

Acceptance check: inject one valid fix, continue IMU samples, then send no more GNSS. After the allowed age, both live and recorded data must indicate stale/unavailable.

**3. Quality assessment is implemented but disconnected from saved truth.**

Pipeline sets flags for vibration, saturation, gaps, and low rate. In finalizeCurrentEvent, the recorder creates a new empty flag set and adds only smoothingUnavailable when necessary. It does not propagate the pipeline flags or event confidence. The saved record therefore loses evidence that the measurement was degraded. [Pipeline.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryCore/Pipeline.swift#L175-L212) [Pipeline.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryCore/Pipeline.swift#L217-L250) [RunRecorder.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryApp/Services/RunRecorder.swift#L795-L822)

Repository personal-best queries and the history's ranking calculations do not filter by trustworthiness. A test named testDisqualifyingFlagsExcludeARunFromPersonalBests only tests QualityFlags.isTrustworthy; it does not exercise the repository or visible ranking. [RunRepository.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryApp/Services/RunRepository.swift#L45-L53) [PastRunsViewModel.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryApp/Features/Runs/PastRunsViewModel.swift#L130-L158) [QualityMonitorTests.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Tests/MotoTelemetryCoreTests/QualityMonitorTests.swift#L106-L115)

There is also a concrete uncertainty defect: Pipeline calls projectedPitchSigma with holdDuration: 0. BiasEstimate multiplies by that duration, so a normal calibrated estimate reports zero projected pitch uncertainty through this path. [Pipeline.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryCore/Pipeline.swift#L206-L209) [Calibration.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryCore/Calibration.swift#L85-L94)

Aggregate quality per attempt, save it, show a compact explanation in details, and exclude unverified attempts from verified records while retaining their data. Define whether uncertainty refers to total attitude error since the gravity anchor or a relative angle change during an attempt, then calculate the appropriate duration and propagate it.

Do not simply copy the cumulative session flags: a fault in an earlier attempt should not automatically disqualify every later attempt. Also do not equate a smoother curve with a more accurate one.

**4. Calibration startup cannot reliably detect complete sensor silence.**

startSensing starts the streams during calibration but does not arm the watchdog. The watchdog appears in startSession, which the normal UI reaches only after calibration and alignment have succeeded. It also requires that CalibrationService has never seen a sample. The intended check is therefore placed too late to rescue normal startup silence. [RunRecorder.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryApp/Services/RunRecorder.swift#L271-L277) [RunRecorder.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryApp/Services/RunRecorder.swift#L375-L439)

Give sensing its own startup timeout, distinguish unavailable hardware, denied access, and a stalled stream, and provide a retry that actually restarts acquisition. Track last-sample age throughout a session, not only whether a sample has ever arrived.

Acceptance checks: no first sample, failure after several samples, permission changes, and restart after a stalled calibration. Every case should lead to an honest status and a working recovery path.

**5. Session promotion needs consistent concurrency ownership.**

The 30 Hz main-actor bridge is a good improvement. However, startSession modifies pipeline, collectedSamples, rawRecorder, segmenter, and scorer outside processLock while the sensing tasks may already be running. processSample reads and mutates processing state under that lock. @unchecked Sendable suppresses checks but does not make these accesses safe. [RunRecorder.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryApp/Services/RunRecorder.swift#L291-L344) [RunRecorder.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryApp/Services/RunRecorder.swift#L595-L641)

This is a source-level race risk, not a crash I reproduced. Move processing state and session commands onto one serial owner, or consistently guard every access. Keep UI observables on MainActor and disk work on a separate store executor. Avoid creating an unbounded task for every sensor sample.

Acceptance checks should include repeated sensing-to-running transitions, rapid tab/recalibration changes, and stopping while a sample or finalisation is in progress, with Thread Sanitizer where practical.

**6. Recording state must reflect the whole attempt.**

EventSegmenter intentionally enters disarming while it waits to confirm an ending; the event can return to active if the angle recovers. RunRecorder treats only active and arming as active. During disarming it publishes an inactive event even though the attempt has not ended. [EventSegmenter.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryCore/EventSegmenter.swift#L204-L242) [RunRecorder.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryApp/Services/RunRecorder.swift#L669-L690)

The view model turns that into a zero timer. If the angle recovers, its false-to-true transition resets the attempt maxima, and controls guarded by eventActive can become editable mid-attempt. [LiveWheelieViewModel.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryApp/Features/Live/LiveWheelieViewModel.swift#L225-L245)

Publish an explicit attempt state and stable attempt ID. Confirmed active and disarming belong to the same attempt. Reset maxima on an onset event or a new attempt ID, not on a boolean display transition.

**7. Persistence must return a result and retain unsaved work.**

Atomic JSON writes are good, but RunRepository.save catches errors and returns Void. The recorder drains pendingSavedRuns first, invokes save, and emits “run saved” regardless of the result. A disk failure loses the pending attempt without user-visible recovery. deleteAll similarly ignores individual removal failures and clears the visible list. [RunRepository.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryApp/Services/RunRepository.swift#L64-L95) [RunRecorder.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryApp/Services/RunRecorder.swift#L542-L588)

Return success/failure, keep failed attempts available for retry, and show “Saved”, “Saving”, or “Could not save”. Apply deletions to the UI only when confirmed. Add a versioned record envelope and explicit migration tests; the current backwards-compatible quality-field handling is useful but should not be the entire migration strategy.

RunRepository also loads every sample of every run synchronously at startup. Start with a small summary index and load samples when opening a run. Cache derived summaries and intervals. A dedicated database can wait until the data model or queries justify it.

**8. Buffers need lifetime bounds.**

collectedSamples receives every telemetry sample during the running session, including idle riding, and is cleared on finalisation or session start. A long period without a completed event can accumulate indefinitely. At 100 Hz, one hour means approximately 360,000 samples; the exact memory cost needs profiling. Finalisation scans this accumulated array to extract the event. [RunRecorder.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryApp/Services/RunRecorder.swift#L697-L704) [RunRecorder.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryApp/Services/RunRecorder.swift#L775-L833)

Use a bounded pre-roll ring while waiting and an attempt buffer after onset, with a maximum event duration or chunked persistence. The existing raw-log size cap protects disk usage, not this memory buffer. Move blur, interval calculation, encoding, and disk writes off the sensor critical section and main actor where possible.

**9. Audio needs lifecycle intent and user controls.**

The continuous audio renderer, smoothed parameters, and route/interruption handling show real thought. However, stop only stops the engine. The configuration-change handler restarts any stopped engine without checking whether the app still wants cues running. A stale sensor feed can also leave the last cue parameters in effect. [CueAudioRenderer.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryApp/Services/CueAudioRenderer.swift#L285-L308) [CueAudioRenderer.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryApp/Services/CueAudioRenderer.swift#L590-L619)

Retain desiredRunning and input freshness. Clear sounding state on stop, and allow interruption/route recovery only when a session still requests audio. Add real mute, preview/test sound, route status, and cue preferences. The former settings controls are currently hidden; exposing them requires wiring actual behaviour. A brief distinct “measurement unavailable” indication should not sound like an angle reading.

**The estimator deserves physical validation before stronger accuracy claims.**

The current beta is a calibrated gyro integrator with an initial gravity anchor and mount alignment. It is not a continuously correcting fused attitude estimator. Avoiding accelerometer correction during strong vehicle acceleration is a defensible choice because acceleration can be mistaken for gravity. The tradeoff is accumulated residual gyro error. [CalibrateOnceEstimator.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryCore/CalibrateOnceEstimator.swift#L95-L166)

As a hypothetical sensitivity example, a constant uncorrected error of 0.01°/s accumulates to 0.6° in a minute. This is arithmetic, not a measured error rate for this app or an iPhone.

Test long sessions, thermal changes, mount stiffness, engine vibration, sampling gaps, phone orientations, and repeatability against known angles. Validate with a controlled fixture/reference measurement before interpreting synthetic test accuracy as device accuracy. The application measures the orientation of the mounted phone; it has no direct wheel-contact sensor, so event detection remains an inference.

A calibration timestamp and status would be useful. A quick re-zero can be convenient if it explicitly requires a suitable stationary pose. Do not automatically “correct” to zero while a slope or vehicle acceleration might be real. Low-confidence alignment fallback should be explained or confirmed instead of silently presented as an equally strong measurement.

**The architecture should evolve through a few clearer boundaries.**

| Boundary | Responsibility |
| --- | --- |
| Session coordinator | Calibration, readiness, settings effective time, start/pause/stop, interruptions, and stable session/attempt IDs. |
| Processing engine | Ordered sensor input, estimation, segmentation, per-attempt quality, bounded buffers, and immutable completed attempts. |
| Run store | Asynchronous persistence, summaries, migration, retry, export, and deletion results. |
| Main-actor presentation | Display snapshots, explicit statuses, navigation, and interactions. |
| Diagnostics service | Consent, redaction, file closure/rotation, upload queue, retry, and retention. |

Keep the existing small core modules. Refactor RunRecorder around these responsibilities; file length is less important than who owns mutable state and failures.

Use separate BikeID, CalibrationID, SessionID, and AttemptID concepts. The repository's runsForBike currently compares a bike ID against calibrationID; WheelieRun has no bike-profile field. The removed profile UI should stay removed until the model supports it. [RunRepository.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryApp/Services/RunRepository.swift#L40-L43) [SettingsView.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryApp/Features/Setup/SettingsView.swift#L3-L15)

Also reconcile duplicate calculation paths. RunScorer is populated by the app, but its finalised results are not used in the saved WheelieRun path. Strong tests for an unused scoring path do not validate the numbers shown to the rider.

Preserve raw measurements, but persist algorithm/configuration versions and immutable event metadata sufficient to explain derived metrics. A replay should record the actual calibration result and alignment, not merely configuration constants whose names contain “bias” or “alignment”.

**Code maintainability can improve without a new framework.**

Replace historical essay comments with concise descriptions of current invariants and move the investigation history into linked engineering notes. Several comments describe previous behaviour or requirements that current code no longer implements; CI's comment says tools-version 6.0 and iOS 18 while Package.swift actually declares 5.9 and iOS 17.

Reduce @unchecked Sendable to explicitly documented, consistently protected boundaries. Prefer typed sensor status and typed identifiers to booleans and interchangeable UUIDs. Separate physical-unit conversion from display formatting. Remove unreachable placeholder controls and dead paths after confirming they are not needed for stored-data compatibility.

Cache stable derived data. WheelieRun recreates interval UUIDs whenever angleIntervals or speedIntervals is accessed; the interval timeline toggles selection by UUID. Recomputing identities can prevent a second tap from recognising the same selection. Use deterministic identity or compute the immutable interval arrays once. [WheelieRun.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryApp/Models/WheelieRun.swift#L113-L141) [RangeIntervalTimeline.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryApp/Features/RunDetails/RangeIntervalTimeline.swift#L277-L284)

IntervalDetector also misses a crossing when two successive values are outside opposite sides of the target band. For samples (0 s, 30°) and (1 s, 50°), a 35–45° band is crossed from 0.25–0.75 s under linear interpolation, but the current enter/exit logic emits no interval. Define an acceptable interpolation gap, cover this crossing case inside that limit, and exclude longer gaps. [IntervalDetector.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryCore/IntervalDetector.swift#L93-L136)

**The user experience should make state and meaning easier to understand.**

The dark instrument style and paired angle/speed meters are distinctive. Keep the overall visual identity. Your latest bottom-anchoring fix addresses my specific rendering regression; no device-rendered claim is made here.

| Improvement | Why it matters |
| --- | --- |
| Explicit Ready / Recording attempt / Paused / Sensor unavailable states | “Calibrated” alone does not tell the rider whether data is fresh or saving is active. |
| Brief last-attempt summary with save confirmation | The rider can understand what happened without immediately opening history. |
| Optional simplified glance display | Large angle and time, with secondary details available when stopped. |
| High-contrast sunlight option and glove-sized controls | Fine rims and subtle gradients are attractive but should be checked outdoors. |
| Intentional session controls and screen-awake policy | Entering/leaving a tab should not be the only way users understand recording lifetime. |
| Audio mute, test, route status, and low-distraction feedback | Existing audio becomes predictable and controllable. |
| Clear GPS unavailable/stale indicator | A frozen value or numeric zero should not imply a current measurement. |
| Consistent chart/statistic signal | Raw chart peaks currently differ from smoothed max-angle and time-in-range calculations. |
| Preserved fractional target labels | Integer formatting can hide half-step target settings. |
| Real mph support | Convert the value, target, scale, export labels, and chart together; the retained enum alone is not support. |
| Accessible alternatives to chart gestures | Offer a readable interval list and selectable time/value details alongside the canvas. |

For charts, default to the same signal used in summary metrics and label an optional raw overlay. Preserve separate angle and speed peaks and repeated target intervals; those are useful existing concepts. Clearly explain whether short merged gaps count toward “time in range” or merely one continuous hold.

Validate Dynamic Type, VoiceOver, Reduce Motion, the smallest supported phone, larger phones, and iPad if it remains a supported device family. Fixed-size layouts and thin strokes need real rendering checks. Test background/lock behaviour with speed enabled and disabled: location background mode and audio code do not by themselves demonstrate uninterrupted motion sampling under every lifecycle condition.

**The most useful new features would deepen practice feedback.**

| Order | Feature | Scope and value |
| --- | --- | --- |
| First | Session summary | Attempts, verified target time, longest stable hold, and notes in one place. |
| First | Compare two attempts | Align at onset and compare angle, speed, and target dwell using existing recorded data. |
| First | Favourites, notes, and meaningful exports | Tag conditions/mount changes; share a summary image or CSV alongside existing JSON. |
| Next | Progress over time | Track consistency and time within the chosen target, with quality-filtered comparisons. |
| Next | Bike and mount profiles | Useful after stable IDs, stored configuration, and calibration validity are implemented. |
| Next | Privacy-preserving diagnostics sharing | User-selected logs with clear inclusion/exclusion of location and upload status. |
| Later | Video synchronisation | Potentially valuable for reviewing technique, but requires clock alignment and a larger media workflow. |
| Later | Optional backup/sync | Useful after save reliability, migration, conflict handling, and deletion semantics are settled. |

My strongest product recommendation is to emphasise consistency within a rider-selected range. Automatically rewarding ever-higher maximum angles would make a single noisy spike disproportionately important and is a weaker expression of controlled practice.

**The AWS deployment is real, active, and proportionate to the current product.**

I inspected loftmeter-beta-diag in us-east-1. CloudFormation reports CREATE_COMPLETE. The architecture is HTTP API → presigning Lambda → direct S3 upload. The bucket holds diagnostics, not a cloud implementation of the app's run repository.

Observed on 11 September 2026 around 19:37 UTC:

| Area | Verified deployed state |
| --- | --- |
| Objects | 81 NDJSON objects, 123,339,459 bytes, approximately 117.6 MiB. |
| Raw traces | Eight filenames identified as raw traces. |
| Grouping | Three distinct installation prefixes; this does not establish three people. |
| Recent uploads | Newest object modified at 19:29:39 UTC on 11 September. |
| Public access | All four S3 Block Public Access flags enabled. |
| Encryption | Default SSE-S3 AES256 encryption. |
| Retention | Enabled expiry after 90 days under beta/. |
| Presigner permission | s3:PutObject only under this bucket's beta/* prefix, plus standard Lambda logging permissions. |
| Lambda | Python 3.12, Active, last update Successful, 128 MB, 10-second timeout. |
| Presigned expiry | 900 seconds. |
| API throttle | 10 requests/second, burst 20. |
| Authentication | API route has no API Gateway authorizer; the function checks a shared X-Beta-Key. |
| Logs | Lambda log group retention is 14 days. |
| Monitoring | No CloudWatch alarms returned in the inspected region; API stage has no access-log configuration. |
| Bucket policy | None configured; this is not the same as a public bucket. |
| Versioning | Not enabled. |

The preceding approximately 24-hour CloudWatch window returned 104 API requests and Lambda invocations, three API 4xx responses, zero API 5xx responses, zero Lambda Errors, and zero Lambda Throttles. The maximum reported Lambda duration was 166.19 ms. The low traffic and seven populated hourly periods limit performance conclusions. API success is not proof that every later S3 upload completed; S3 objects independently demonstrate uploads did succeed.

**Privacy is the most immediate deployed-stack finding.** I sampled the first 128 KiB of two recent raw files. One contained latitude and longitude fields. The code also shows GNSS coordinates being captured in raw samples and the uploader selecting NDJSON files from the shared logs directory. Values and installation identifiers are deliberately omitted from this report. [RawSampleRecorder.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryApp/Services/Diagnostics/RawSampleRecorder.swift#L126-L165) [SpeedService.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryApp/Services/SpeedService.swift#L180-L191) [BetaDiagnosticUploader.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryApp/Services/Diagnostics/BetaDiagnosticUploader.swift#L310-L339)

The repository policy says ride/location data is device-only and never transmitted. That description does not match the configured beta. The uploaded data also has a persistent installation grouping. The uploader is guarded by BETA, so this finding does not establish that the normal Release build uploads data. [WheelieTrackerApp.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/Sources/MotoTelemetryApp/App/WheelieTrackerApp.swift#L22-L67) [privacy-policy.md](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/store/privacy-policy.md#L8-L35)

Provide a beta-specific explanation and meaningful control over uploading, with location redaction as a default option and clear retention/deletion terms. Speed diagnostics often do not need absolute coordinates.

The App Store questionnaire notes also incorrectly treat mere on-device location access as sufficient reason to declare collection. Apple's definition concerns transmission off-device with retained access. Questionnaire answers must match the actual submitted binary, including any diagnostics it enables. [Apple's App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/).

**AWS hardening should stay proportionate.** The private bucket, scoped write role, expiry, and API throttle are good. I would add the following:

- Explicit beta enrolment or scoped installation credentials before a wider beta. An extractable shared app token is an abuse gate; it does not prove that a client owns its supplied installID.
- Per-installation rate/byte budgets and server-enforced upload bounds. The current presigned PUT parameters bind key and content type but do not impose a file-size policy.
- A bucket policy denying non-TLS transport. Current application URLs use HTTPS, but the bucket has no policy enforcing it for all permitted clients.
- API error/throttle and Lambda error alarms, plus privacy-conscious access logs. Application-generated 500 responses may not count as Lambda execution errors.
- An explicit closed-file upload queue, durable completion/retry state, and recovery of background upload tasks after relaunch. Modification-time heuristics are weaker than knowing that a file is closed.
- A way to correlate “presign issued” with “object stored” without logging secrets, signed URLs, or location.
- A documented deletion path for one installation's uploaded diagnostics. Deleting on-device runs does not delete S3 objects.
- Cost monitoring focused on ingest volume and misuse. There is no evidence here that Kubernetes, a database, or a more complex backend is needed.

Versioning is optional for disposable diagnostic logs; enabling it has retention consequences and is not an automatic improvement. I did not modify resources, send test uploads, run a penetration test, audit all account-wide identities, or perform CloudFormation drift detection. The source returned by GetTemplate matches the reviewed presigner design, but that does not independently prove that no one has edited deployed Lambda code outside CloudFormation.

**Build and testing improvements should target the app integration gaps.**

The Xcode project contains 42 absolute references under one developer's home directory. Convert them to repository-relative references and verify from a clean checkout. The current CI runs swift build and swift test; Package.swift includes the core and motolog, not MotoTelemetryApp. App unit tests are empty templates, and the UI example only launches the app. A green package build cannot establish that the iOS app builds or that its lifecycle works. [project.pbxproj](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/MotoTelemetryApp/MotoTelemetryApp/MotoTelemetryApp.xcodeproj/project.pbxproj#L81-L126) [ci.yml](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/.github/workflows/ci.yml) [MotoTelemetryAppTests.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/MotoTelemetryApp/MotoTelemetryApp/MotoTelemetryAppTests/MotoTelemetryAppTests.swift) [MotoTelemetryAppUITests.swift](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/blob/f91ef3789cd944c25f2ccd21cce75759a3edf6ad/MotoTelemetryApp/MotoTelemetryApp/MotoTelemetryAppUITests/MotoTelemetryAppUITests.swift)

Use a fake clock, scripted sensor sources, and an injectable run store to cover these exact behaviours:

| Test | Required result |
| --- | --- |
| No first IMU sample | Calibration reaches a recoverable unavailable state. |
| GNSS silently stops | Speed expires; stale values cannot qualify as fresh. |
| Change target between attempts | Saved target matches the effective visible target. |
| Toggle speed mid-session | Location ownership, UI, and saved configuration agree. |
| Brief exit-threshold dip | Same attempt ID, retained maxima, continuous timer. |
| Gap, saturation, or high vibration | Saved quality and record eligibility reflect the fault. |
| Nonzero calibration uncertainty over time | Uncertainty cannot remain zero merely because duration was omitted. |
| Save or delete failure | User sees the failure and unsaved/undeleted data remains represented. |
| Long idle session | Memory stays bounded. |
| Stop then change audio route | Audio remains stopped. |
| Select an interval twice | Stable identity produces predictable deselection. |
| Open historical schemas | Data remains readable and missing quality is marked unverified. |

Add a simulator app build and focused integration tests to CI. Use snapshot tests or reviewable screenshots for meter geometry at empty, partial, and full scale; screenshots would have caught the anchoring regression I introduced. Keep real-device checks for sensors, audio routes, interruptions, screen lock, long-session drift, energy/thermal behaviour, and actual outdoor legibility.

For newer Xcode and iPhones, this source is not inherently tied to iPhone 15. Its configured app minimum is iOS 17.2 and the app Swift language setting is 5.0. However, this review cannot certify a newer toolchain build. Fix portable project paths, compile the app in the chosen newer Xcode, then run the simulator/device matrix. Review privacy-manifest requirements for the APIs used and validate the archive before submission.

**A practical implementation order is to make the measurements trustworthy, then improve convenience.**

1. Fix portable builds and establish an actual app build gate.
2. Fix configuration snapshots, speed freshness, per-attempt quality/uncertainty, startup health, and save failures.
3. Correct session-state ownership, concurrency, bounded buffering, and audio lifecycle.
4. Reconcile beta privacy wording and upload controls; add small AWS operational safeguards.
5. Make chart/statistic semantics consistent and add explicit readiness/save feedback.
6. Add session summaries, attempt comparison, notes, and exports.
7. Expand profiles, backup, or video only when there is demonstrated rider demand.

The strongest next release would make every displayed number, saved attempt, and quality claim explainable and consistent. That would improve this product more than a large feature expansion.

