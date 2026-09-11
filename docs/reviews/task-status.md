# Remediation task status

Check and update this file on `codex/live-meter-reference-polish` before editing a task. Fetch the latest file and use its blob SHA when updating to avoid overwriting another agent's claim. Claim one task before touching implementation; preserve other agents' entries. For simultaneous claims, resolve any SHA conflict by re-reading and checking ownership, not blindly retrying. Work on a task-specific branch from the current integration head. ChatGPT is authorized by the user to review and merge changes that meet their acceptance gates; other peers hand off merge requests here.

| Task | Status | Owner | Working branch | Notes |
| --- | --- | --- | --- | --- |
| K01 | **DONE** | Codex (this ChatGPT session) | `codex/k01-portable-ios-build` | Merged via [PR #3](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/pull/3) as `1155704` on the integration branch (`bba0aeb` reachable). [CI run 34642324805](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/actions/runs/34642324805) passed: Debug/Beta/Release iOS builds, 175 core tests, 2 app template tests on iPhone 16 / iOS 18.5 / Xcode 16.4. User meter correction preserved. |
| K02 | **IN PROGRESS** | Codex (sole active agent) | `codex/remaining-remediation` | User transferred all remaining implementation/review/merge ownership to ChatGPT. Repair EC2 harness, include it in Xcode target, validate with GitHub macOS CI. |
| K03–K10 | UNBLOCKED — SEQUENTIAL | — | — | K01 integrated. These form a strict chain on `RunRecorder` (K03→K04→K05→K06→K07→K08→K09, plus K10 after K06+K09); each rebased/remeasured on its accepted predecessor. Do not edit simultaneously. K03 opens once K02 is accepted. |
| K11 | BLOCKED | — | — | Await K02/K05; separate interval and chart PRs. |
| K12 | **SPEC MERGED — RUNTIME OPEN** | Codex (ChatGPT remote) | `codex/k12-uncertainty-contract` | [PR #4](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/pull/4), `8ddc5fc`. Six analytical examples independently recalculated; links/whitespace checked. No runtime or threshold changes. Model decision and physical validation remain outstanding; K12 is not DONE. |
| K13 | **DOCS MERGED — CONTROLS OPEN** | Codex (ChatGPT remote) | `codex/k13-beta-privacy-docs` | [PR #5](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/pull/5), `2d38466`. Source/data-flow review and documentation checks complete. Policy remains a publication draft pending verified contact. Consent/redaction and synthetic-data tests remain outstanding after K02; K13 is not DONE. |
| K14 | **TLS/MONITORING MERGED — REMAINDER OPEN** | Codex (ChatGPT remote) | `codex/k14-diagnostics-guardrails` | [PR #6](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/pull/6), `302ec7d`. Baseline RED; 4 tests GREEN with 6 negative controls; independently rerun. AWS CloudFormation ValidateTemplate passed in us-east-1. No deployment. Authentication/size limits and deployment/change-set/notification gates remain outstanding; K14 is not DONE. |
| K15 | BLOCKED | — | — | Await stable correctness and K09. |
| K16 | BLOCKED — SCOPE REQUIRED | — | — | Product/visual scope must be specified first. |

Statuses: UNCLAIMED, IN PROGRESS, BLOCKED, READY FOR REVIEW, DONE. READY FOR REVIEW means code/evidence is available; DONE requires the agreed acceptance gate and integration. Missing Xcode or a pending CI run is not a passing gate. Claiming K01 does not claim the whole plan.

[Task plan](2026-09-11-kiro-fix-plan.md) · [Review](2026-09-11-app-and-aws-review.md)

## Peer-to-peer handoff protocol

User-confirmed execution roles (2026-09-11). These are peers; any agent can hand off a bounded step directly to another through this file. ChatGPT additionally reviews evidence, dependencies and cross-system risks; it is not a mandatory approval bottleneck.

| Peer | Best use | Handoff boundary |
| --- | --- | --- |
| Kiro / EC2 | Fast implementation, isolated worktrees, offline tests, fixture construction | Request native validation with exact commit and commands; lack of local Xcode does not prevent source/test/project-membership work. |
| Local Mac | Xcode debugging, simulator failures requiring iteration, rendering, physical iPhone/sensor validation | Return exact toolchain/device, test names/results and artifacts. Hand long repeatable build jobs to ChatGPT/GitHub runners when useful. |
| ChatGPT remote | Independent review, GitHub macOS CI coordination, AWS inspection/validation, resolving cross-system blockers | Use EC2 for implementation and Mac for device-only evidence. Internal helper agents belong to this peer; they are not the external EC2/Mac sessions. |

Before editing, read the newest integration-branch tracker and claim the exact task/substep IN PROGRESS with owner, UTC time, branch/base SHA and file allowlist. Preserve all other claims using the current blob SHA. A review handoff does not transfer implementation ownership. The receiver acknowledges/claims its substep in this file before editing; until then the request is pending, not accepted. Do not have two peers edit the same branch/files concurrently.

Every handoff records: sender/receiver, requested outcome, exact commit, allowed files, completed evidence, missing gate, and next action. On a blocker, state the concrete capability missing and route that step to a capable peer; do not mark unrun code complete. READY FOR REVIEW applies only to the named slice. DONE requires the agreed evidence and integration. User authorized ChatGPT to review and merge accepted PRs on 2026-09-11. Record exact reviewed commits and evidence before merging; preserve partial-task status. AWS deployment remains separate.

## Active handoffs and independent review

### K02 — ChatGPT review of EC2 commit 3f975e8 (2026-09-11)

**Implementation owner remains Kiro/EC2.** Existing Mac request above is retained; the following static-review findings must be resolved before acceptance. This review is not an Xcode build result.

1. **False-positive consumption assertion:** `ScriptedMotionSource.yield` increments `rawCount` before yielding. `testScriptedMotionReachesRecorderWithoutSleeps` polls that same producer counter, which is already five after the loop. The assertion can pass with the recorder consumer disabled. EC2: assert a recorder-side processed result/completion and demonstrate a RED negative control when consumption is disabled. Stream `finish()` alone does not await consumer completion.
2. **Missing agreed recorder-to-store proof:** the persistence test calls `store.repository.save` directly; constructing a recorder in a separate test does not exercise its save path. EC2: add the small scripted recorder/event-to-repository scenario required by K02, retaining the real repository and injected failure. Do not defer acceptance-critical behavior as an optional Mac follow-up.
3. **Isolation/assertion gap:** `testDefaultRepositoryStillTargetsDocuments` constructs the real Documents repository and only asserts a nonoptional value is non-nil. It proves neither the path nor isolation. EC2: remove this ineffective test or replace it with a meaningful isolated default-resolution check.
4. **Native gate:** both new files still need test-target membership. Mac's existing request owns that pending substep unless explicitly handed back. Once membership and the assertions are corrected, ChatGPT can inspect the exact commit's existing GitHub CI: the Debug job already runs MotoTelemetryAppTests on iPhone 16 / iOS 18.5 / Xcode 16.4 and retains xcresult/log artifacts. Confirm the new named tests actually execute; a green run that excludes them is insufficient. Physical-device validation cannot be replaced by simulator CI.

**Next actions:** EC2 acknowledges and fixes findings 1–3 within K02's existing allowlist; Mac acknowledges target-membership/native-debug substep or hands it to EC2; ChatGPT reviews the corrected commit and CI evidence when handed back. Do not open K03 until K02's actual acceptance gate passes. This prevents the current “UNBLOCKED — SEQUENTIAL” group heading from being read as permission to skip K02.

### K12–K14 — ChatGPT draft handoff (2026-09-11)

Draft PRs #4, #5 and #6 above are independently reviewable slices. No new EC2 or Mac implementation claim is implied. K12 needs a model decision before runtime work; K13 needs the recorded product/data decisions and K02 before app tests; K14 needs infrastructure review before a separately authorized deployment. Reviewers record findings against the exact PR commit and hand corrections to its owner. All three remain partial tasks.

### Merge review — ChatGPT COMPLETED for PRs #4–#6 (2026-09-11)

User authorized review and merge. Reviewing PRs #4–#6 at their published heads; scope is the specification/documentation/infrastructure slices only. Existing test evidence remains applicable if trees are unchanged; inspect CI and current integration compatibility before merging. K02 remains owned by EC2 with its existing review findings and native gate outstanding.

### Merge results — ChatGPT (2026-09-11)

User-authorized review and merge completed into `codex/live-meter-reference-polish`:

| PR | Exact reviewed head | Merge commit | Acceptance evidence |
| --- | --- | --- | --- |
| #4 — uncertainty specification | `8ddc5fc8f6bdb04a36d5f45c293f7a040ee74721` | `acc5b21beee3b32523a8ebfec6e31e79c3551984` | Reviewed specification, independently recalculated six examples, checked links/whitespace; CI run 34646282079 passed. This accepts the proposal document, not a calibrated runtime model. |
| #5 — privacy documentation | `2d3846689f706e99cd184ebb6b8ee2fb2c61b234` | `b09e9d8ca3af51cb642986601301389df27f0e3c` | Source/data-flow and dated AWS evidence reviewed; links/whitespace checked. Policy visibly remains a publication draft. iOS CI run 34646322510 queued at merge review; no application changes. |
| #6 — infrastructure safeguards | `302ec7d49836211e9a1a721672f884d5440d4d59` | `697cd014d873514be812207689e44dbbcc00f113` | Baseline RED, four candidate tests GREEN with six negative controls; root rerun passed; AWS ValidateTemplate passed. iOS CI run 34646370591 queued at merge review; no application changes. |

GitHub confirmed all three merges using expected-head checks. No required check was bypassed. K12 runtime/calibration, K13 consent/redaction/contact, and K14 deployment/authentication/size controls remain open. No AWS deployment occurred. EC2/Mac should fetch the latest integration branch before their next bounded task and preserve K02 ownership; K02 findings and native acceptance gate remain outstanding.

## Current execution override — sole agent (2026-09-11)

User has transferred all remaining tasks, fixes and merges to ChatGPT; prior peer handoffs are historical and no longer blockers. K02 starts from integration `d83fbca` plus EC2 `3f975e8` source changes. K03–K13 and K15–K16 remain queued for sequential implementation and acceptance. Product defaults may be resolved by Codex, preserving corrected meter art and measured behavior. K14 monitoring is DEFERRED BY USER: remove newly introduced alarm/access-log template resources; retain transport enforcement. No monitoring deployment is requested. Physical-device claims remain contingent on actual hardware evidence. Tasks will be marked IN PROGRESS before editing their implementation.

Current concrete K02 allowlist: both TelemetryIntegration Swift test files, RunRecorder.swift, RunRepository.swift, project.pbxproj. CI modifications, if needed, are limited to native test execution and reproducible regression evidence. K14 scope correction allowlist: infra/diagnostic-upload.yaml, infra/README.md, infra/tests/test_template_controls.py.

### Solo implementation progress

K14 monitoring removal merged via PR #8 (`b82e165`); TLS retained. K02 native gate queued on PR #7 (`ab8edff`). **K03 IN PROGRESS — Codex**, same bounded RunRecorder allowlist plus existing harness lifecycle tests; preparing stacked local commits while native CI queues, no merge before applicable acceptance. Subsequent recorder tasks remain queued.

**K04 IN PROGRESS — Codex (sole agent)**: Effective settings and immutable onset snapshots. Allowlist: RunRecorder.swift, LiveWheelieViewModel.swift, existing TelemetryIntegrationHarnessTests.swift (shared harness regression coverage). Preserve existing speed-zero convention.

**K05 IN PROGRESS — Codex (sole agent)**: Freshness contract: GNSS fix age <=2.5s in monotonic time; future/stale/invalid unavailable, older fixes ignored; disabled speed retains numeric zero but not validity. Legacy absent validity remains unknown. Files: Pipeline.swift, SpeedService.swift, RunRecorder.swift, TelemetrySample.swift, WheelieRun.swift, GNSSSpeedFloorTests.swift.

**K06 IN PROGRESS — Codex (sole agent)**: Startup/stall health and real acquisition retry. Allowlist: RunRecorder.swift, CalibrationScreen.swift, LiveWheelieView.swift, LiveWheelieViewModel.swift, CalibrationService.swift; shared integration tests. Clock-driven health evaluation callable without sleeps.

**K07 IN PROGRESS — Codex (sole agent)**: Keep confirmed attempt active through disarming. Files RunRecorder.swift and shared lifecycle tests. Do not change segmenter thresholds.

**K08 IN PROGRESS — Codex (sole agent)**: Per-attempt quality and verified rankings. Files Pipeline.swift, RunRecorder.swift, RunRepository.swift, PastRunsViewModel.swift; existing core/app test files.

**K09 IN PROGRESS — Codex (sole agent)**: Truthful save/delete outcomes and visible retry queue. Files RunRepository.swift, RunRecorder.swift, LiveWheelieView.swift, existing harness tests; PastRunsView.swift if needed to surface deletion errors. Retain unsaved attempts; retry idempotent.

**K10 IN PROGRESS — Codex (sole agent)**: Audio intended-running state, synchronized control-path latch reset, stale render input expiry. Files CueAudioRenderer.swift plus existing app harness tests. K02 native named tests passed and PR7 merged e17fbba.

**K11 IN PROGRESS — Codex (sole agent)**: Linear band crossing incl both endpoints outside, explicit gap barriers; consistent blurred default charts/scrubber and stable interval IDs with speed validity. Files IntervalDetector.swift/Tests, WheelieRun.swift, RunDetailsViewModel.swift, RunDetailsView.swift and existing app harness.

**K11b allowlist expansion IN PROGRESS — Codex (sole agent)**: TelemetryChart.swift also required: this component computes its own peak/scrubber from rawSamples and connects all points. Add explicit segment grouping and consistent displayed samples; do not alter live meters.
