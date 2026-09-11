# Remediation task status

Check and update this file on `codex/live-meter-reference-polish` before editing a task. Fetch the latest file and use its blob SHA when updating to avoid overwriting another agent's claim. Claim one task before touching implementation; preserve other agents' entries. For simultaneous claims, resolve any SHA conflict by re-reading and checking ownership, not blindly retrying. Work on a task-specific branch from the current integration head. Do not merge automatically.

| Task | Status | Owner | Working branch | Notes |
| --- | --- | --- | --- | --- |
| K01 | **DONE** | Codex (this ChatGPT session) | `codex/k01-portable-ios-build` | Merged via [PR #3](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/pull/3) as `1155704` on the integration branch (`bba0aeb` reachable). [CI run 34642324805](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/actions/runs/34642324805) passed: Debug/Beta/Release iOS builds, 175 core tests, 2 app template tests on iPhone 16 / iOS 18.5 / Xcode 16.4. User meter correction preserved. |
| K02 | **AWAITING MAC GATE** | Kiro (EC2 session) | `kiro/k02-integration-harness` | Harness implemented and pushed (`3f975e8`): scripted `MotionProviding`/`SpeedProviding` sources (reusing existing protocols), a ManualClock, an isolated temp-dir `RunRepository`, and an injectable write-failure hook. Minimal production-preserving seam in `RunRepository` (optional `runsDirectory` init → nil = Documents/runs unchanged; test-only `writeInterceptor` → nil in production; `save()` signature untouched, K09 still owns returning outcomes). Tests cover: real save → allRuns + disk + reload; injected write failure leaves no run/file; scripted motion reaches the real RunRecorder with no wall-clock sleeps. **NOT READY FOR REVIEW** — EC2 has no Xcode, so this is UNBUILT/UNRUN. **Mac agent:** add `TelemetryIntegrationSupport.swift` + `TelemetryIntegrationHarnessTests.swift` to the MotoTelemetryAppTests target, build the app + run the suite on a simulator; end-to-end segmenter-driven save deferred to you. |
| K03–K10 | UNBLOCKED — SEQUENTIAL | — | — | K01 integrated. These form a strict chain on `RunRecorder` (K03→K04→K05→K06→K07→K08→K09, plus K10 after K06+K09); each rebased/remeasured on its accepted predecessor. Do not edit simultaneously. K03 opens once K02 is accepted. |
| K11 | BLOCKED | — | — | Await K02/K05; separate interval and chart PRs. |
| K12 | **IN PROGRESS** | Codex / uncertainty agent | `codex/k12-uncertainty-contract` | Claimed 2026-09-11 from `db40cd2`. Design/specification only; no estimator implementation or threshold changes. Separate worktree; root coordinates handoff. |
| K13 | **IN PROGRESS** | Codex / privacy agent | `codex/k13-beta-privacy-docs` | Claimed 2026-09-11 from `db40cd2`. Documentation phase only: audited beta versus Release data flow; no app changes or invented consent behaviour. |
| K14 | **IN PROGRESS** | Codex / infrastructure agent | `codex/k14-diagnostics-guardrails` | Claimed 2026-09-11 from `db40cd2`. TLS enforcement and monitoring template/tests only; no AWS deployment, token rotation, or upload protocol change. |
| K15 | BLOCKED | — | — | Await stable correctness and K09. |
| K16 | BLOCKED — SCOPE REQUIRED | — | — | Product/visual scope must be specified first. |

Statuses: UNCLAIMED, IN PROGRESS, BLOCKED, READY FOR REVIEW, DONE. READY FOR REVIEW means code/evidence is available; DONE requires the agreed acceptance gate and integration. Missing Xcode or a pending CI run is not a passing gate. Claiming K01 does not claim the whole plan.

[Task plan](2026-09-11-kiro-fix-plan.md) · [Review](2026-09-11-app-and-aws-review.md)
