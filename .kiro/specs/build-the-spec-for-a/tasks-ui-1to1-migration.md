# Tasks — UI 1:1 Mockup Migration

Scope: **refinements to already-implemented screens** (Live, Past Runs, Run Details) to make
the rendered UI a pixel-for-pixel match of the three canonical mockups. This file does **not**
duplicate or replace `tasks.md`; it lists only the *changes* to existing code. Nothing here is a
new feature built from scratch — every task edits a file that already exists.

Authoritative source: the amended `docs/ui-spec.md` (§6, §7.3, §8.2, §8.3, §9.4).

Notes carried over from decisions made during review:
- **Record-only badges:** `LATEST` / `LONGEST` and the `PERSONAL BEST` sublabel are shown **only for a genuine record holder**. This is already the code's behavior (`isLongestRun` gating) and is correct — do **not** force them always-on. No task changes this.
- **Confirmed-correct, do NOT touch** (re-verified against the mockup pixels; the sub-agent gap reports were wrong on these): `·` middle-dot separators in the Run Details subtitle and interval callout; the `°` suffix on the angle chart max marker (`44°`), band label (`35°–45°`), and scrubber value (`42°`); the teal color of `MAX SPEED`; the timeline interior time labels (`boundaryTimesRow`); the `MAX 47°` bottom-card sublabel; and the two-line `TARGET` labels on the Live meters.

Status key: `[ ]` not started · `[~]` in progress · `[x]` done.

---

## M-UI1 — Live meter fill: drop the bright third stop
- [ ] **File:** `Sources/MotoTelemetryApp/DesignSystem/AppColors.swift`, `Features/Live/VerticalTelemetryMeter.swift`
- **Current:** fill is a 3-stop gradient `meterFillBottom (0x0A1F3D) → meterFillMid (0x1656A8) → meterFillTop (0x2E86E0)`; the top stop reads as a bright accent.
- **Change:** make the fill a **two-stop** ramp deep-navy → *moderate* blue. Either remove the `meterFillTop` stop from the gradient or lower it to a moderate blue so the cursor end no longer looks like a bright accent. Keep the fill clipped to the filled portion only.
- **Done when:** the filled meter shows a smooth navy→moderate-blue ramp with no bright top band; empty track above the cursor stays dark. `[ui-spec §7.3 Meter fill behavior]`

## M-UI2 — Live speed scale labels: 0/25/50/75 only (no top `100`)
- [ ] **File:** `Features/Live/VerticalTelemetryMeter.swift` (`makeScaleSteps()`)
- **Current:** non-angle path computes `step = span/4` over `0...speedGaugeMaximum`, producing `0,25,50,75,100` (5 labels) at max=100.
- **Change:** render exactly the four labels `0, 25, 50, 75` (i.e. the `0 / 25% / 50% / 75%` fractions of the gauge maximum). Do **not** draw a label at the track top; the maximum lives on the `MAX … km/h` chip. Minor ticks unchanged.
- **Done when:** speed meter shows four scale labels, none colliding with the MAX chip, for any `speedGaugeMaximum`. `[ui-spec §7.3 Speed meter]`

## M-UI3 — Remove the `MAX … km/h` chip; fix the speed gauge maximum at 100
- [ ] **File:** `Features/Live/LiveWheelieView.swift` (`gaugeMaxChip` + `speedMeter` header), `Features/Live/VerticalTelemetryMeter.swift`
- **Current:** a `MAX 100 km/h` chip (pencil + chevron) sits above the speed meter. It is non-interactive, and it also steals vertical space from the speed track (contributing to the unequal-height bug, M-UI10).
- **Change:** **remove the chip entirely.** Keep `speedGaugeMaximum` **fixed at 100 km/h** for now (no in-app editor). Removing the chip lets the speed header match the angle header height (see M-UI10). Do not add a scale selector; the earlier "make it interactive" plan is dropped.
- **Note:** this reverses the earlier interactive-MAX decision. The scale selector referenced in ui-spec §7.5 is deferred, not required for the 1:1 match.
- **Done when:** no MAX chip appears above the speed meter; the speed scale tops out at a fixed 100 km/h; the speed header no longer eats track height. `[ui-spec §7.3 Speed meter]`

## M-UI4 — Live speed current-value readout: big number + unit caption beneath
- [ ] **File:** `Features/Live/VerticalTelemetryMeter.swift` (`valueReadoutView`)
- **Current:** speed readout stacks `Text(number)` then `Text(unit)` — already visually close to the mockup (big `42` over `km/h`).
- **Change:** verify against the mockup that the number is large/bold and `km/h` is a smaller caption directly beneath, both in `accentBright` blue, tracked to the cursor. Adjust sizes only if it does not match. (This is a polish/verify task, not a rewrite — the stacked layout itself is correct per the mockup.)
- **Done when:** the speed readout matches the mockup's big-`42` / small-`km/h` pairing. `[ui-spec §7.3 Speed meter]`

## M-UI5 — Past Runs subtitle: "N attempts today" scoped to today
- [ ] **File:** `Features/Runs/PastRunsViewModel.swift` (`subtitleText`), `Features/Runs/PastRunsView.swift`
- **Current:** `subtitleText` returns `"\(count) runs"` / `"\(count) runs (filtered)"` over all runs.
- **Change:** count only runs whose `startedAt` is **today** (rider's local calendar day) and render `"\(todayCount) attempts today"`. Preserve any filtered-state variant using the same "attempts" noun.
- **Done when:** subtitle reads e.g. `12 attempts today`, counting today's runs only. `[ui-spec §8.2]`

## M-UI6 — Past Runs relative time: "N min ago" / "Just now"
- [ ] **File:** `Features/Runs/RunHistoryRow.swift`
- **Current:** `Text(run.startedAt, style: .relative)` — omits the literal `ago` and has no `Just now` floor.
- **Change:** format relative time explicitly: `Just now` for very recent runs (< ~60 s), otherwise `"\(n) min ago"` / `"\(n) hr ago"` etc. Keep it locale-aware (do not hardcode English if a localized formatter is available), but the shape must include the `ago` suffix and the `Just now` floor.
- **Done when:** rows read `Just now`, `3 min ago`, `29 min ago` matching the mockup. `[ui-spec §8.3]`

## M-UI7 — Bottom tab glyph: twin-meter for Live
- [ ] **File:** `Sources/MotoTelemetryApp/App/RootTabView.swift`
- **Current:** Live tab uses `Label("Live", systemImage: "gauge")`.
- **Change:** replace the Live tab glyph with the **twin-meter glyph** (two short vertical rounded bars) to match the mockup — a custom `Image`/shape or the closest SF Symbol that reads as two vertical meters. Runs keeps the list glyph. Active tab tinted `accentBlue`.
- **Note:** the tab bar itself is **already persistent** (root `TabView`), so no structural change is needed — this is a glyph swap only.
- **Done when:** the Live tab shows a twin-meter glyph, not a single gauge. `[ui-spec §6, §4.4]`

## M-UI8 — Run Details: one truly-shared scrubber across both charts
- [ ] **File:** `Features/RunDetails/RunDetailsView.swift`, `Features/RunDetails/TelemetryChart.swift`, `Features/RunDetails/SharedChartScrubber.swift`
- **Current:** each `TelemetryChart` draws its own independent `RuleMark` bound to `$viewModel.selectedTime` (two separate hairlines in two frames). `SharedChartScrubber.swift` exists but is **never referenced** (dead code). The `3.8s` time bubble is horizontally centered, not tracked to the scrubber x.
- **Change:** render **one continuous vertical line as a single overlay spanning both chart plot areas** (wire up / rewrite `SharedChartScrubber` and overlay it across the stacked-charts container, or draw a shared overlay whose x maps `selectedTime`). Remove the per-chart independent scrubber lines. Position the `3.8s` bubble at the scrubber's x so it tracks the line. Keep the interpolated value dots (`42°` on angle, `48 km/h` on speed) at `selectedTime`.
- **Done when:** dragging shows one unbroken vertical line from the top of the angle chart through the bottom of the speed chart, with the time bubble tracking its x. Delete `SharedChartScrubber.swift` only if fully superseded; otherwise wire it in. `[ui-spec §9.4]`

---

## Device-observed refinements (round 2)

These came from running the app on device; they are behavior/layout bugs, not mockup-styling deltas.

## M-UI9 — Live meter fill must track the live reading, not a fixed/arbitrary height
- [ ] **File:** `Features/Live/VerticalTelemetryMeter.swift`, `Features/Live/LiveWheelieViewModel.swift`
- **Current (device):** the solid blue fill does not clearly represent the current reading against the target range — it reads as an arbitrary value.
- **Change:** enforce the honest-telemetry model from ui-spec §7.3: the **solid fill height = `clamp(currentValue / scaleMaximum, 0, 1)`** (0 → current cursor only), driven by the live smoothed display value from the view model; the **target range is drawn ONLY as the translucent dashed band** at `lower…upper`, never as the solid fill. Verify the fill is bound to the live value (not a placeholder/constant) and that the band is visually distinct from the fill so the reading-vs-range relationship is unambiguous.
- **Done when:** as the live value changes the solid fill rises/falls to exactly the cursor, the empty track above stays dark, and the dashed band clearly marks the target range independent of the fill. `[ui-spec §7.3 Meter fill behavior]`
- **NOTE — confirm intent:** written as "fill = current reading, band = range" (the ui-spec model). If the rider instead wants the solid fill to *be* the target range span, flip this task.

## M-UI10 — The two meters must be equal height
- [ ] **File:** `Features/Live/LiveWheelieView.swift` (`metersSection`), `Features/Live/VerticalTelemetryMeter.swift`
- **Current (device):** the angle meter and speed meter render at different heights (the speed meter's top-of-track MAX chip and/or side content is shifting its track height).
- **Change:** with the MAX chip removed (M-UI3), the speed header no longer steals track height, which is the main fix. Give both meter **tracks** an identical height regardless of remaining side chrome (value readouts, target labels). Reserve equal vertical space above each track so both tracks pin to the same `height`, top and bottom aligned.
- **Done when:** angle and speed tracks are the same height and vertically aligned top and bottom. `[ui-spec §7.3 Dual vertical meters]`

## M-UI11 — Scale (y-axis) labels overflow the screen — constrain them
- [ ] **File:** `Features/Live/VerticalTelemetryMeter.swift` (scale label layout, `makeScaleSteps` / tick canvas)
- **Current (device):** the scale labels (angle on the left, speed on the right) render partly off-screen.
- **Change:** keep the scale labels inside the safe horizontal insets (20 pt, ui-spec §3.1). Constrain each meter column's total width (track + tick gap + label) so labels sit fully on-screen; reduce label/side-content width or the inter-meter gap before letting anything clip. Do not shrink the live values to make room (ui-spec §3.2 order: reduce padding/labels before values).
- **Done when:** every scale label is fully visible within the screen insets on the target device width. `[ui-spec §3.1, §3.2, §7.3]`

## M-UI12 — Live value readout overflows when at 0 — constrain it
- [ ] **File:** `Features/Live/VerticalTelemetryMeter.swift` (`valueReadoutView`)
- **Current (device):** at value `0` the current-value readout (e.g. `0°` / `0 km/h`) is pushed off-screen / clips, because it is offset to the cursor which is at the track bottom.
- **Change:** clamp the readout's vertical offset so it stays fully on-screen at the extremes (especially value = 0 at the track bottom and value = max at the top), and keep it within the horizontal insets. It should ride the cursor in the mid-range but stop at a safe margin near the ends rather than following the cursor off the edge.
- **Done when:** at `0` and at the scale maximum the readout is fully visible and does not overflow. `[ui-spec §3.1, §7.3]`

## M-UI13 — Remove the sliders button; make the `TARGET` label itself the tap target
- [ ] **File:** `Features/Live/VerticalTelemetryMeter.swift` (`targetLabelView`), and any call sites passing `onTargetEdit`
- **Current:** below each `TARGET` label there is a circular `slider.horizontal.3` button that opens the target editor; the label text is not tappable.
- **Change:** **remove the circular sliders button** on both meters. Make the `TARGET` + range text block itself the tappable control that invokes `onTargetEdit` (wrap the `VStack` of `TARGET` / range / triangle in a `Button` or add a tap gesture with a ≥44 pt hit target). Keep it disabled mid-attempt with the existing non-blocking message. Applies to both angle and speed.
- **Done when:** no sliders icon appears under either target; tapping the `TARGET 35°–45°` / `TARGET 35–50` text opens the target editor. `[ui-spec §7.3, §7.5]`

## M-UI14 — Space the meters apart: center each in its half of the screen
- [ ] **File:** `Features/Live/LiveWheelieView.swift` (`metersSection`), `Features/Live/VerticalTelemetryMeter.swift`
- **Current (device):** the two meters sit too close together in the middle of the screen.
- **Change:** position each meter so it is **centered within its own half of the screen width** — the angle meter centered in the left half, the speed meter centered in the right half (roughly the screen quarter-points). Increase the gap between meter centers toward the upper end of the ui-spec range (112–136 pt) or beyond as needed to reach the half-centers; **shrink the track width / side content if required** to keep both meters and their scale labels on-screen (works together with M-UI11). Keep angle on the left, speed on the right (mirrored).
- **Done when:** each meter is visually centered in its screen half, clearly separated, with all labels on-screen. `[ui-spec §3.1, §7.3 Dual vertical meters]`

## M-UI15 — Fill flat to the cursor: remove the rounded/semicircle fill cap
- [ ] **File:** `Features/Live/VerticalTelemetryMeter.swift` (fill shape / clip)
- **Current (device):** the top of the blue fill is rounded (a "semicircle" cap), so the fill does not read as reaching flat up to the cursor line.
- **Change:** the fill must terminate with a **flat top edge exactly at the cursor y**, not a rounded cap. The **rounded corners belong to the track outline only** (clip the fill to the rounded track so the *bottom* corners follow the track), but the fill's own top must be a straight horizontal edge meeting the cursor line. Do not stroke or cap the fill top with a circle/rounded rect.
- **Done when:** the blue fill rises as a solid column with a flat top flush against the white cursor line; only the track's bottom corners are rounded. `[ui-spec §7.3 Meter fill behavior]`


---

## Out of scope (explicitly not in this migration)
- Any new screen, model, or service. This file is refinement-only.
- Accessibility work (`T10.6` in `tasks.md`) — tracked there, unchanged.
- The confirmed-correct items listed at the top — leave them exactly as they are.

## Verification
After the code changes, verify on this machine with the project's typecheck path
(`xcrun --sdk iphoneos swiftc -typecheck …`, `#Preview` blocks stripped) and, where meter/chart
snapshot tests exist (T7.2, T8.7), update the fixtures. Final pixel confirmation is a device/GUI
build by the rider against the three mockups.
