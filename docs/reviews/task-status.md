# Remediation task status

Check and update this file on `codex/live-meter-reference-polish` before editing a task. Fetch the latest file and use its blob SHA when updating to avoid overwriting another agent's claim. Claim one task before touching implementation; preserve other agents' entries. For simultaneous claims, resolve any SHA conflict by re-reading and checking ownership, not blindly retrying. Work on a task-specific branch from the current integration head. Do not merge automatically.

| Task | Status | Owner | Working branch | Notes |
| --- | --- | --- | --- | --- |
| K01 | **DONE** | Codex (this ChatGPT session) | `codex/k01-portable-ios-build` | Merged via [PR #3](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/pull/3) as `1155704` on the integration branch (`bba0aeb` reachable). [CI run 34642324805](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/actions/runs/34642324805) passed: Debug/Beta/Release iOS builds, 175 core tests, 2 app template tests on iPhone 16 / iOS 18.5 / Xcode 16.4. User meter correction preserved. |
| K02 | **AWAITING MAC GATE** | Kiro (EC2 session) | `kiro/k02-integration-harness` | Harness implemented and pushed (`3f975e8`): scripted `MotionProviding`/`SpeedProviding` sources (reusing existing protocols), a ManualClock, an isolated temp-dir `RunRepository`, and an injectable write-failure hook. Minimal production-preserving seam in `RunRepository` (optional `runsDirectory` init → nil = Documents/runs unchanged; test-only `writeInterceptor` → nil in production; `save()` signature untouched, K09 still owns returning outcomes). Tests cover: real save → allRuns + disk + reload; injected write failure leaves no run/file; scripted motion reaches the real RunRecorder with no wall-clock sleeps. **NOT READY FOR REVIEW** — EC2 has no Xcode, so this is UNBUILT/UNRUN. **Mac agent:** add `TelemetryIntegrationSupport.swift` + `TelemetryIntegrationHarnessTests.swift` to the MotoTelemetryAppTests target, build the app + run the suite on a simulator; end-to-end segmenter-driven save deferred to you. |
| K03–K10 | UNBLOCKED — SEQUENTIAL | — | — | K01 integrated. These form a strict chain on `RunRecorder` (K03→K04→K05→K06→K07→K08→K09, plus K10 after K06+K09); each rebased/remeasured on its accepted predecessor. Do not edit simultaneously. K03 opens once K02 is accepted. |
| K11 | BLOCKED | — | — | Await K02/K05; separate interval and chart PRs. |
| K12 | **READY FOR REVIEW — SPEC ONLY** | Codex (ChatGPT remote) | `codex/k12-uncertainty-contract` | [Draft PR #4](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/pull/4), `8ddc5fc`. Six analytical examples independently recalculated; links/whitespace checked. No runtime or threshold changes. Model decision and physical validation remain outstanding; K12 is not DONE. |
| K13 | **READY FOR REVIEW — DOCS ONLY** | Codex (ChatGPT remote) | `codex/k13-beta-privacy-docs` | [Draft PR #5](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/pull/5), `2d38466`. Source/data-flow review and documentation checks complete. Policy remains a publication draft pending verified contact. Consent/redaction and synthetic-data tests remain outstanding after K02; K13 is not DONE. |
| K14 | **READY FOR REVIEW — TLS/MONITORING SLICE** | Codex (ChatGPT remote) | `codex/k14-diagnostics-guardrails` | [Draft PR #6](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/pull/6), `302ec7d`. Baseline RED; 4 tests GREEN with 6 negative controls; independently rerun. AWS CloudFormation ValidateTemplate passed in us-east-1. No deployment. Authentication/size limits and deployment/change-set/notification gates remain outstanding; K14 is not DONE. |
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

Every handoff records: sender/receiver, requested outcome, exact commit, allowed files, completed evidence, missing gate, and next action. On a blocker, state the concrete capability missing and route that step to a capable peer; do not mark unrun code complete. READY FOR REVIEW applies only to the named slice. DONE requires the agreed evidence and integration. User reviews draft PRs; no automatic merge or deployment.

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
