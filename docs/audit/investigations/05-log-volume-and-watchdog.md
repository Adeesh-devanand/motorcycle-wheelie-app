I'll read the owned files and the logging contract first.Now let me find the logging contract and the "autostart status" / "gate reason" emitters, which live outside my owned files.The two flooding lines both come from `CalibrationService.swift` (not one of my owned files, but I need to read the emitter to diagnose). Let me read the relevant sections and find the logging contract.No file matching `*logging-contract*` exists; the rate-discipline rule lives inline in `Diagnostics.swift` (quoted above). Let me grep the spec files for the contract text and confirm the `ValidityGate` core emitter obeys the rule.I now have everything needed. The key insight: the `DiagnosticEmitter.emit` keys on the `key` string I pass, and both flooding call sites pass a key that **embeds a value that flips every sample**, defeating both the emitter's transition rule and the sink's coalescer. Let me confirm the exact mechanism for each.

**"autostart status"** (line ~264): `diag.emit("autostart:\(estimator == nil ? "idle" : "active")", ...)`. The key alternates `autostart:idle` ↔ `autostart:active` **every sample** during the settling window (estimator gets created then torn down / generation-mismatched repeatedly), so `changed == true` on nearly every call → emits at 100 Hz. The sink's coalescer keys on `(category|message)` = `cal|autostart status` (message is constant), so it *should* catch it — unless the emitter's `changed` path... no, the sink coalesces regardless of emitter. Let me verify why the sink didn't catch it.

The sink coalesce window is `0.05s` (20/s) and keys on `category+"|"+message`. Message `"autostart status"` is constant → key is constant → it **should** coalesce to 20/s. But the measured rate is 100/s. That means the sink coalescer is NOT catching it. Reason: the emitter uses **sample time** (`event.time`) for the window comparison — `event.time - last < coalesceWindow`. If sample time advances by 0.01s per sample, then `0.01 < 0.05` → drop... that would coalesce. So why 100/s?

Let me check: the "autostart status" line is `.info` level. The coalescer explicitly bypasses `.warn`/`.error` only. `.info` is coalesced. So the sink SHOULD reduce it to 20/s. The measured 100/s means either the message isn't constant or the time isn't advancing as expected. The message `"autostart status"` is literally constant. Let me re-examine — the "gate reason X -> Y" message embeds `old`/`reason` so its message varies, but "autostart status" is constant.

The one variable: the sink compares `event.time - last`. For "autostart status" the time is `sample.time`. If two samples arrive with near-identical `sample.time`... no. Let me just check whether there's a second emit path. Actually — re-reading: 10,480 lines over 197s = 53/s, not 100/s. The 100/s measurement was the *emitter* rate. The sink got 10,480. So the sink **is** partially coalescing (100→53) but not to 20. Let me verify by reading requirements for the contract and confirm my count math, then write the report.I have enough. The contract is inline in `Diagnostics.swift` (no separate `*logging-contract*` file exists — I confirmed by listing the spec dir). Now the full analysis.

---

# DEFECT A — 89% of the log is one repeated line

### 1. The coalescing implementation

`/Users/vinothiniraju/Documents/Adeesh/motorcycle-wheelie-app/Sources/MotoTelemetryApp/Services/Diagnostics/DiagnosticLog.swift`, inside `emit(_:)`:

```swift
// line 130
bufferLock.lock()
// Defence-in-depth coalescing over the core's transition+heartbeat rule.
let key = event.category + "|" + event.message                    // line 132
if let last = lastEmitByKey[key], event.time - last < coalesceWindow,
   event.level != .warn, event.level != .error {                  // lines 133-134
    droppedCount += 1
    bufferLock.unlock()
    return
}
lastEmitByKey[key] = event.time                                    // line 139
```

with `private let coalesceWindow: TimeInterval = 0.05  // ~20/s` (line 44).

- **Key:** `category + "|" + message` — **not** the `values`.
- **Budget:** **per-key**, not a global budget. Each distinct `(category, message)` pair gets its own 20/s allowance via `lastEmitByKey[key]`.
- **Clock:** the window is measured on `event.time` (sample time), consistent with the rest of the system.

### 2. Why 10,480 "autostart status" lines got through

The **emitter** (`DiagnosticEmitter.emit`, `Diagnostics.swift` line ~150) gates on the caller-supplied `key`, emitting whenever `key != lastKey`. The caller in `CalibrationService.feedIMU` (line 262) passes:

```swift
diag.emit("autostart:\(estimator == nil ? "idle" : "active")", time: sample.time,
          level: .info, message: "autostart status", values: [...])
```

The discriminator key **encodes `estimator == nil`, which flips every few samples** during the settling window (an estimator is created, then torn down by the generation-mismatch / auto-start-retry churn, repeatedly). So `key` oscillates `autostart:idle ↔ autostart:active`, `changed` is true on a large fraction of samples, and the emitter fires far