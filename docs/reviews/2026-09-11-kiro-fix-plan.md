**Loftmeter: bounded remediation plan for Kiro**

This plan accompanies [the app and AWS review](2026-09-11-app-and-aws-review.md). It is a portable Markdown handoff based on the extension workflow described by the maintainer, not a claim about the extension's configuration syntax or installed capabilities.

**Use one coordinator and one focused task per worktree/session.** One capable coding agent can execute the sequence, but should not receive an unrestricted instruction to fix the entire review in one PR. The advantage comes from bounded scope and independently verified evidence, not from a particular model name.

The source baseline is beta commit f91ef3789cd944c25f2ccd21cce75759a3edf6ad plus the corrected meter branch at 357f84df483938bb828ffd81e2166c3c73e06971. These documents live on codex/live-meter-reference-polish. Your starting point is its latest fetched commit, including the documentation commits. Record that full SHA before every run. If the maintainer later merges or changes the integration branch, record the new base explicitly.

The corrected bottom-anchored meter fill is intentional and must be preserved. The review is a set of source-observed findings and recommendations, not proof that every issue still reproduces at a future HEAD. Revalidate each finding before editing. AWS observations are dated snapshots; do not describe them as current without fresh reads.

**Different tasks require different evidence.**

| Task class | Trustworthy ruler | Keep gate |
| --- | --- | --- |
| Correctness | A deterministic regression tied to the user-visible contract | RED on baseline; GREEN with fix; relevant existing tests remain green |
| Performance | Paired baseline/candidate runs on identical data and equipment, with calibrated variability | Predeclared improvement clears measured noise; correctness and fidelity do not regress |
| Build portability | Clean checkout in an arbitrary path on the supported Mac runner | Actual iOS app builds, and executable app tests run |
| UI | Fixed input fixtures and actual rendered screenshots | Geometric invariants plus human visual review; no subjective pixel-score optimisation |
| Privacy/infrastructure | Explicit data-flow and policy assertions, template validation, human review | Requirements satisfied with evidence; no production deployment as part of a coding cycle |
| Physical measurement | Known reference angles/motion and repeatable device procedure | Predeclared error limits validated on hardware; synthetic success alone is insufficient |

For deterministic bug tests there is no artificial performance noise threshold. Calibrate the test itself: prove it fails for the intended reason on baseline, passes on a minimal valid repair, and rejects a targeted negative control that reintroduces the defect. Keep calibration controls disposable and outside the candidate patch.

For performance, run baseline-versus-baseline repetitions first, alternate A/B order, fix dataset/device/build mode, and declare the primary metric and allowed tradeoffs before changing production code. Use a disposable known improvement to show that the ruler can detect a real win. If it cannot, stop that task with the calibration evidence. Do not pick a threshold after seeing results.

**Execution boundaries apply to every task.**

- Preserve the push-disabled clone. Do not add credentials, enable its remote, or use another tool to bypass that boundary. Produce local commits/patches and draft PR material; use only the extension's approved draft workflow. The maintainer publishes and merges.
- Create an isolated worktree at the recorded base. One finding per candidate, one resumable session per task. Do not rebase or delete someone else's worktree.
- Confirm repository instructions and the current test/build commands first. Missing Mac/Xcode access blocks app verification; it does not justify reporting success from source inspection.
- Expand the allowlist below to an explicit list of concrete files before edits. Paths listed as new files are permitted only for the named task. Any necessary expansion must be documented and reviewed before touching those files. No unrelated formatting or dependency upgrades.
- Add regression tests to the actual app test target when they depend on iOS models/services. Package-only tests do not validate RunRecorder, RunRepository, or SwiftUI.
- Reject candidates that weaken existing tests, change the assertion to fit the implementation, reduce sensor fidelity to win a benchmark, or remove quality checks.
- No changes to calibration thresholds, physical units, persisted-data semantics, warning-tone meaning, or target behaviour without the task's explicit contract.
- No AWS mutation, test uploads, production credential access, or raw location data committed to GitHub. Use synthetic/redacted fixtures.
- A failed candidate is reverted only in its own worktree. Retain its result and explanation in the task session so it is not repeated blindly.
- Record blockers and unresolved product choices. A missing prerequisite is not permission for a broad refactor.

**Path aliases below are allowlist prefixes, not wildcard permission.**

APP = Sources/MotoTelemetryApp; CORE = Sources/MotoTelemetryCore; TEST = Tests/MotoTelemetryCoreTests; XCP = MotoTelemetryApp/MotoTelemetryApp/MotoTelemetryApp.xcodeproj; APPTEST = MotoTelemetryApp/MotoTelemetryApp/MotoTelemetryAppTests.

**Dependency order.**

Start K01, then K02. Complete K03 before changing other RunRecorder behaviour. K04, K05, K06, K07, K08 and K09 all touch that coordinator and should be implemented and integrated sequentially, each rebased and remeasured on the accepted predecessor. K10 follows the freshness/session contracts. K11 can follow independently after app testing works. K12 requires a separate measurement specification. K13 and K14 are a separate privacy track. Performance work K15 comes after correctness is stable. Visual/features work K16 follows the accepted fixes.

If two tasks touch the same file, do not run their edits simultaneously. Separate implementation sessions do not require simultaneous agents. Independent review may happen separately without shared edits.

**K01 — Reproducible app build. Priority P1.**

Allowlist: XCP/project.pbxproj; .github/workflows/ci.yml; existing shared schemes only if necessary to enable app tests; new docs/reviews/build-validation.md.

Replace developer-home source references with repository-relative paths. Preserve signing, bundle IDs, deployment minimums, and Beta/Release flags. Discover the real scheme and available simulator from xcodebuild; pin the runner/toolchain intentionally. CI must build the iOS app as well as the Swift package. Do not fix unrelated compiler failures inside this task; report and isolate them.

Evidence: clean checkout under an unrelated directory on macOS; swift build/test; xcodebuild of the app for an available simulator. Record versions and commands. Verify the user's meter correction is included. A source search for absolute paths alone is not the keep gate.

**K02 — Minimal app integration harness. Depends K01.**

Allowlist: APPTEST/TelemetryIntegrationSupport.swift (new), APPTEST/TelemetryIntegrationHarnessTests.swift (new); APP/Services/RunRecorder.swift; APP/Services/RunRepository.swift; narrowly necessary protocol seams in MotionService.swift and SpeedService.swift; XCP/project.pbxproj for test membership only.

Provide a controlled clock, scripted motion/GNSS sources, an isolated temporary store, and an injectable write failure. Reuse existing provider protocols. Production defaults must remain unchanged. Prove the harness observes an actual recorder-to-store flow, does not depend on wall-clock sleeps, and rejects an injected failure. Keep this small; do not build a generic testing framework.

**K03 — One owner for processing state. Priority P1; depends K02.**

Allowlist: APP/Services/RunRecorder.swift; APPTEST/RunRecorderConcurrencyTests.swift (new); APPTEST/TelemetryIntegrationSupport.swift.

Make session promotion and sensor processing obey the same serialisation rule. Prefer a minimal consistent fix before introducing new architecture. Do not introduce one unbounded task per sample. Preserve the 30 Hz UI bridge and full-rate recording.

Evidence: deterministic overlap of sensing, session start, sample processing, and stop; no duplicate tasks, late writes, or lost completed attempts. Run relevant lifecycle tests and Thread Sanitizer where supported. A clean sanitizer run supports the ownership review but does not prove absence of all races.

**K04 — Effective settings and immutable attempt configuration. Priority P1; depends K03.**

Allowlist: APP/Services/RunRecorder.swift; APP/Models/RiderPreferences.swift; APP/Models/MetricRange.swift; APP/Features/Live/LiveWheelieView.swift and LiveWheelieViewModel.swift; APP/Features/Setup/SettingsView.swift; APPTEST/AttemptConfigurationTests.swift (new).

Contract: idle changes apply before the next attempt; an active attempt retains its onset snapshot. Speed enabled/disabled must agree between hardware ownership, display, and persistence. Preserve numeric-zero behaviour for intentionally disabled speed; do not confuse it with fresh stationary data. If a transition requires restart, make the effective time explicit in UI instead of silently disagreeing.

RED/GREEN: start at 35–45 degrees, change to 45–55 between attempts, verify the next saved target and intervals. Toggle speed both ways and verify provider start/stop and saved state. Verify edits during an active attempt cannot mutate its snapshot.

**K05 — GNSS freshness and stored validity. Priority P1; depends K04.**

Allowlist: CORE/Pipeline.swift, Sample.swift, Config.swift; APP/Services/SpeedService.swift and RunRecorder.swift; APP/Models/TelemetrySample.swift and WheelieRun.swift; APP/Features/Live/LiveWheelieViewModel.swift; TEST/GNSSSpeedFloorTests.swift; APPTEST/SpeedFreshnessTests.swift (new).

Specify the age limit, clock mapping, and unavailable/stale/disabled semantics before implementation. Derive wall-clock/monotonic offset independently of the age of the first fix. Add backwards-compatible persisted validity; old records must not be silently treated as newly verified data. Preserve the existing intentionally disabled numeric-zero convention.

RED/GREEN: one valid fix followed by IMU-only silence; cached first fix; explicit invalid fix; out-of-order fix; speed disabled. Assert expiry reaches display and saved analysis. Keep fresh valid speed tests passing. Chart presentation of gaps may be a separately scoped follow-up to K11; report that dependency rather than claiming full completion prematurely.

**K06 — Sensor startup and ongoing health. Priority P1; depends K05.**

Allowlist: APP/Services/RunRecorder.swift, CalibrationService.swift and MotionService.swift; APP/Features/Live/CalibrationScreen.swift and LiveWheelieViewModel.swift; APPTEST/SensorHealthTests.swift (new).

Arm health monitoring in sensing before calibration can complete. Distinguish no initial delivery from a later stall. Retry must restart acquisition and cancel the previous health task. Publish freshness to the audio lifecycle rather than letting a previous tone imply a current reading.

RED/GREEN: no first sample, delayed delivery, stream failure after success, cancelled session, retry, and late sample from a previous session. Use the fake clock; no five-second sleeps in tests.

**K07 — Stable attempt identity through disarming. Priority P2; depends K06.**

Allowlist: APP/Services/RunRecorder.swift; APP/Features/Live/LiveWheelieViewModel.swift; CORE/EventSegmenter.swift only if the existing transitions cannot express identity; APPTEST/AttemptLifecycleTests.swift (new).

Treat active and disarming as the same confirmed attempt. Reset maxima only at a new onset/attempt identity. Keep target edits locked through exit confirmation. Do not alter event thresholds or dwell values.

RED/GREEN: enter an attempt, reach a maximum, dip below exit briefly, recover, then end. Assert one attempt, retained maximum, continuous duration, and correct edit lock. Test discarded arming separately.

**K08 — Per-attempt quality reaches records and rankings. Priority P1; depends K07.**

Allowlist: APP/Services/RunRecorder.swift and RunRepository.swift; APP/Models/WheelieRun.swift; APP/Features/Runs/PastRunsViewModel.swift; APP/Features/RunDetails/RunDetailsView.swift; CORE/Pipeline.swift and QualityMonitor.swift if required for per-attempt snapshots; APPTEST/RunQualityIntegrationTests.swift (new).

Persist applicable quality flags and use trustworthiness in every relevant best/rank query. Retain degraded records with an explanation. Do not copy cumulative session flags indiscriminately or label smoothed data as accurate. Uncertainty modelling remains K12.

RED/GREEN: degraded event saved and excluded from verified bests; clean later event in the same session remains eligible when appropriate; missing historical quality remains unverified. Test the real repository/view-model path, not only QualityFlags.isTrustworthy.

**K09 — Durable save failure and truthful deletion. Priority P1; depends K08.**

Allowlist: APP/Services/RunRepository.swift and RunRecorder.swift; APP/Features/Live/LiveWheelieViewModel.swift and LiveWheelieView.swift; APP/Features/Runs/RunSettingsSheet.swift; APPTEST/RunPersistenceFailureTests.swift (new).

Return persistence outcomes; keep unsaved attempts available for retry; do not emit success before an actual write. Keep partial deletion failures represented. Retries must not duplicate records.

RED/GREEN: injected write failure, retry success, duplicate retry, and partial deleteAll failure. Verify saved bytes reload correctly and unsaved work remains visible. Do not rely on filling the developer's actual disk.

**K10 — Audio obeys session intent and freshness. Priority P2; depends K06 and K09.**

Allowlist: APP/Services/CueAudioRenderer.swift; APP/Services/RunRecorder.swift for lifecycle commands only; APPTEST/CueLifecycleTests.swift (new).

Track intended running state, reset sounding state on stop, and expire stale inputs. Preserve the current pitch-to-cue mapping. User-facing cue customisation is a separate feature.

RED/GREEN: stop then configuration change does not restart; active interruption resumes only when allowed; stale sensor data cannot continue an angle cue indefinitely. Record simulator limitations; confirm actual audio routes on a device before claiming device validation.

**K11 — Consistent chart values and stable intervals. Priority P2; depends K02 and K05. Split into separate PRs.**

K11a allowlist: CORE/IntervalDetector.swift; TEST/IntervalDetectorTests.swift. Cover both-outside crossing of the entire band and an explicit maximum interpolation gap. Preserve documented merge/min-duration semantics. Establish the expected answer mathematically before editing.

K11b allowlist: APP/Models/WheelieRun.swift and RangeInterval.swift; APP/Features/RunDetails/RunDetailsViewModel.swift, RunDetailsView.swift and RangeIntervalTimeline.swift; APPTEST/RunDetailsConsistencyTests.swift (new). Choose one labelled default signal for statistics and charts, retain raw data, cache stable interval identities, and honour speed validity. Verify peaks, scrubbed values, target totals, and repeated selection with a fixture where raw and smoothed peaks differ.

**K12 — Define and validate pitch uncertainty. Priority P1; requires measurement-design review.**

Allowlist for specification: docs/reviews/pitch-uncertainty-contract.md (new). After review, implementation allowlist: CORE/Calibration.swift, CalibrateOnceEstimator.swift, Pipeline.swift and Config.swift; TEST/BetaCalibrateOnceTests.swift; new TEST/PitchUncertaintyTests.swift.

The zero holdDuration is a real wiring issue, but substituting arbitrary elapsed time is not a validated uncertainty model. Define whether the quantity represents absolute attitude error since anchoring or relative hold-angle error, and which noise/bias assumptions it includes. Use analytically known scenarios to establish expected growth, units, reset behaviour, and numerical bounds. Do not tune calibration thresholds to make synthetic tests pass. Physical accuracy claims require the maintainer's reference-device measurements; leave those claims blocked until evidence exists.

**K13 — Beta diagnostics privacy and user control. Priority P1; depends K02.**

First PR: exact allowlist store/privacy-policy.md, store/app-privacy-answers.md, and a new docs/reviews/beta-data-flow.md. Document configured beta versus normal release behaviour accurately; preserve a list of verified transmissions and retention. Maintainer supplies contact details and chooses the diagnostics/coordinate-sharing contract.

Second PR after that decision: exact allowlist APP/Services/Diagnostics/BetaDiagnosticUploader.swift and RawSampleRecorder.swift; APP/Models/RiderPreferences.swift; APP/App/WheelieTrackerApp.swift; APP/Features/Setup/SettingsView.swift; APPTEST/BetaDiagnosticPrivacyTests.swift (new).

Acceptance: without consent no upload is scheduled; location-redacted mode has no coordinate fields in upload bytes; enabled mode is accurately described; controls persist; Release does not instantiate beta uploads. Use synthetic files and a fake transport, never real rider traces in fixtures. Redact an export copy if local raw traces are still needed for legitimate device debugging.

**K14 — AWS operational controls. Priority P2; draft infrastructure changes only.**

Allowlist: infra/diagnostic-upload.yaml; infra/README.md; new infra/tests/test_presigner.py and infra/tests/test_template_controls.py. Split transport enforcement/alarms from upload-auth/volume limits if both are pursued.

Validate a non-TLS deny policy, privacy-conscious access logs, and useful alarms without changing existing storage retention unintentionally. For size limits, test the enforcement mechanism itself: accepting a client-supplied size field is not an enforceable upload bound. A signed PUT and an S3 POST policy have different client implications; design and review before changing protocol. Test malformed input, unauthorised requests, namespace ownership, and limits with mocks. Template assertions must verify actual policy resources and conditions.

Do not deploy or rotate the production token in this task. Provide the proposed template diff, validation evidence, rollout/rollback plan, and explicitly outstanding live validation. Do not claim template tests prove deployed behaviour.

**K15 — Performance after correctness. Depends K09; separate two measured PRs.**

K15a allowlist: APP/Services/RunRecorder.swift; new APP/Services/AttemptSampleBuffer.swift if needed; APPTEST/RecorderBufferPerformanceTests.swift (new). Compare idle retention and event extraction at increasing synthetic durations, with identical sample rates and event fixtures. Primary objective: idle memory remains bounded. Guardrails: identical accepted events, required pre-roll, timestamps, quality, and sample fidelity. Prove memory plateaus rather than merely measuring a short run.

K15b allowlist: APP/Services/RunRepository.swift; APP/Models/WheelieRun.swift; APP/Features/Runs/PastRunsViewModel.swift; APPTEST/RunHistoryPerformanceTests.swift (new); new APP/Services/RunSummaryIndex.swift if justified. Compare startup latency and peak memory on fixed 100/1,000/10,000-run corpora. Preserve all records, rankings, migration, deletion, and export. Cache summaries/lazily load samples before considering a database migration.

Declare latency/memory tradeoffs in advance. Keep only improvements beyond baseline variability. Preserve benchmark datasets and commands as generated synthetic fixtures so others can reproduce results.

**K16 — Visual clarity and new features. Separate product work after core fixes.**

No implementation allowlist is granted by this plan. Scope each feature first: ready/recording/saved status, session summaries, two-attempt comparison, notes/exports, sunlight mode, real mph conversion. Each needs an exact file list and acceptance criteria. Preserve the corrected meter artwork unless a specific visual change is requested. Screenshots at zero/partial/full values and compact layouts should check bottom anchoring, target placement, clipping, and accessibility. Human review decides appearance; performance alone cannot accept a redesign.

**Required result for each task session.**

Return task ID; exact base SHA; finding status (reproduced/already fixed/blocked); allowlisted and changed files; ruler definition; calibration evidence; baseline and candidate results; relevant test results; screenshots/device evidence where applicable; behaviour and schema changes; unresolved risks; and local patch/commit plus draft PR text. Explicitly distinguish tests executed from tests only proposed.

Keep the PR description short: the user-visible problem, the specific fix, the evidence, and limitations. No automatic publishing, merging, or deployment. Once a prerequisite is accepted, the next session starts from that accepted base and reruns its own baseline.

**Suggested first Kiro message:**

Read docs/reviews/2026-09-11-app-and-aws-review.md and docs/reviews/2026-09-11-kiro-fix-plan.md on codex/live-meter-reference-polish. Execute K01 only. Record the current HEAD; preserve the meter correction. Establish an actual clean-checkout iOS build baseline before changing files. Use K01's allowlist, keep the clone push-disabled, and return a validated local change with draft PR material. If macOS/Xcode or another prerequisite is missing, report that blocker with evidence and do not broaden scope. Do not start K02 or later tasks in this session.
