# Wheelie Tracker UI & Interaction Specification

Version: 1.0  
Primary target: iOS 17+ with SwiftUI  
Secondary targets: Android, Flutter, React Native, web, or any UI framework capable of drawing charts and custom gauges

## 1. Purpose

This document is the canonical implementation specification for three screens in a motorcycle wheelie-tracking application:

1. **Live Wheelie** — calibrated and calibrating states
2. **Past Runs** — a sortable and filterable run history
3. **Run Details** — synchronized telemetry charts and interactive in-range intervals

An implementation should reproduce the behavior and hierarchy described here even if the platform uses different native controls. The visual mockups establish the aesthetic direction; this specification governs behavior, data, state, accessibility, and edge cases.

## 2. Product principles

- **Glanceable while active:** the live screen prioritizes current angle, speed, and elapsed wheelie time. Configuration controls must never compete with live telemetry.
- **No historical clutter on Live:** attempts, longest hold, lifetime bests, and previous runs belong on the Runs screens.
- **Honest telemetry:** partial meter fills stop at the current reading. Empty track above the cursor remains visibly unfilled.
- **Separate concepts:** angle and speed have independent scales, target ranges, maxima, histories, and in-range intervals.
- **One shared time axis:** Run Details aligns angle, speed, and range-entry information to the same run-relative time.
- **Performance colors are relative:** history colors are normalized independently per field between the applicable personal worst and best.
- **Dark, restrained, technical:** use near-black surfaces, muted blue/teal telemetry, and bright green only for confirmed/calibrated states and genuine personal-best or maximum markers.
- **Safety first:** do not require or encourage interaction during an active wheelie. Configuration is disabled while an attempt is in progress.

## 3. Platform-independent layout baseline

Design against a portrait viewport of **390 × 844 points**. Adapt fluidly to other widths and safe areas.

### 3.1 Global geometry

| Token | Value | Notes |
|---|---:|---|
| Horizontal screen inset | 20 pt | May reduce to 16 pt below 360 pt width |
| Base spacing unit | 4 pt | Use multiples of 4 |
| Standard control height | 44 pt | Minimum interactive height |
| Compact chip height | 36–40 pt | Hit target still expands to 44 pt |
| Card corner radius | 14 pt | Use consistently |
| Pill corner radius | 999 pt | Fully rounded |
| Hairline | 1 device pixel | Not necessarily 1 logical point |
| Bottom tab height | 64 pt + safe-area inset | Fixed with content scrolling behind/inset above it |
| Minimum touch target | 44 × 44 pt | Applies to icons and tiny visual controls |

### 3.2 Responsive rules

- Respect safe-area insets and the platform status bar.
- At widths below 360 pt, reduce internal card padding before reducing font sizes.
- Run Details is vertically scrollable. Keep the bottom navigation fixed.
- Past Runs uses a virtualized/lazy list.
- Live Wheelie should fit without vertical scrolling on standard portrait phones. On very short screens, reduce meter height before reducing live-value size.
- Landscape support is optional for v1. If implemented, use a two-column layout rather than stretching portrait components.

## 4. Design tokens

### 4.1 Color palette

Use semantic tokens rather than embedding raw colors in individual components.

| Semantic token | Hex | Usage |
|---|---|---|
| `background` | `#0A0D0F` | Main screen background |
| `surface` | `#101519` | Cards and list cells |
| `surfaceRaised` | `#151B20` | Selected or elevated content |
| `surfaceOverlay` | `#050709` at 72% | Calibration dimming overlay |
| `border` | `#28323B` | Hairlines and inactive outlines |
| `textPrimary` | `#F2F5F7` | Titles and primary values |
| `textSecondary` | `#9AACBD` | Labels, timestamps, axes |
| `textTertiary` | `#657383` | Disabled and subordinate text |
| `accentBlue` | `#238CD8` | Active navigation and speed accents |
| `accentTeal` | `#10B9B7` | Angle accents and traces |
| `calibratedGreen` | `#42E56B` | Calibrated status dot |
| `personalBestGreen` | `#32E85B` | Personal bests and graph maximum markers |
| `rangeLowIndigo` | `#6559D8` | Lowest history value |
| `rangeLowBlue` | `#2F86D7` | Low-mid history value |
| `rangeMidTeal` | `#10B5B4` | Mid-high history value |
| `rangeHighGreen` | `#32E85B` | Highest history value |

Do not introduce yellow, orange, or red into the current visual system. Avoid fully saturated neon bloom. Glows should be low-opacity and tightly bounded.

### 4.2 Translucent colors

| Token | Value | Usage |
|---|---|---|
| `angleBandFill` | `accentTeal` at 12% | Angle target band behind graph/meter |
| `angleBandStroke` | `accentTeal` at 45% | Angle target boundary |
| `speedBandFill` | `accentBlue` at 12% | Speed target band behind graph/meter |
| `speedBandStroke` | `accentBlue` at 45% | Speed target boundary |
| `angleInterval` | `accentTeal` at 62% | In-range timeline interval |
| `speedInterval` | `accentBlue` at 62% | In-range timeline interval |
| `inactiveTrack` | `#8191A0` at 22% | Empty gauge and timeline tracks |

When angle and speed intervals overlap, render both on the same pixels using a screen/additive-style blend. The overlap should appear brighter blue-teal without becoming opaque.

### 4.3 Typography

On iOS, use the system San Francisco family. On other platforms, use the native system sans-serif.

| Role | iOS style / size | Weight |
|---|---:|---:|
| Screen title | 30–34 pt | Bold |
| Live primary value | 36–44 pt | Semibold/Bold, tabular numerals |
| Hero metric value | 34–40 pt | Semibold, tabular numerals |
| List metric value | 18–21 pt | Medium/Semibold, tabular numerals |
| Section heading | 16–18 pt | Semibold |
| Label | 12–14 pt | Medium, uppercase where shown |
| Body/helper | 14–16 pt | Regular |
| Axis/annotation | 11–13 pt | Regular/Medium, tabular numerals |

Use tabular numerals for every live, historical, chart, and time value. Keep units visually smaller than the numeric value.

### 4.4 Icons

Prefer platform-native outlined symbols. Suggested SF Symbols:

- Settings: `gearshape.fill`
- Back: `chevron.left`
- Share/export: `square.and.arrow.up`
- Filter: `slider.horizontal.3`
- Sort: `arrow.up.arrow.down`
- Live tab: custom twin-meter glyph or `gauge.with.dots.needle.33percent`
- Runs tab: `list.bullet`
- Calibration spinner: native indeterminate `ProgressView`

Icons are decorative when an adjacent text label communicates the same meaning. Interactive icon-only controls require accessibility labels.

## 5. Data contracts

The data model must be UI-framework-independent. Store raw samples so visualizations and range intervals can be regenerated.

### 5.1 Core model

```swift
struct TelemetrySample: Identifiable, Codable, Sendable {
    let id: UUID
    let elapsed: TimeInterval       // seconds from run start
    let angleDegrees: Double        // calibrated pitch, 0...90+
    let speedKPH: Double            // non-negative
}

struct MetricRange: Codable, Equatable, Sendable {
    var lower: Double
    var upper: Double
}

struct RunConfigurationSnapshot: Codable, Sendable {
    let angleTarget: MetricRange    // e.g. 35...45 degrees
    let speedTarget: MetricRange    // e.g. 35...50 km/h
    let speedGaugeMaximum: Double   // e.g. 100 km/h
    let calibrationID: UUID
}

struct WheelieRun: Identifiable, Codable, Sendable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let samples: [TelemetrySample]
    let configuration: RunConfigurationSnapshot

    var duration: TimeInterval
    var maxAngle: Double
    var maxSpeed: Double
    var averageSpeed: Double
    var angleIntervals: [RangeInterval]
    var speedIntervals: [RangeInterval]
}

struct RangeInterval: Identifiable, Codable, Sendable {
    let id: UUID
    let metric: MetricKind          // angle or speed
    let start: TimeInterval
    let end: TimeInterval
    var duration: TimeInterval { end - start }
}

enum MetricKind: String, Codable, Sendable {
    case angle
    case speed
    case duration
}
```

Store the target ranges used when the run was recorded. Historical graphs must use this snapshot, not the user's current settings.

### 5.2 Preferences

```swift
struct RiderPreferences: Codable, Sendable {
    var angleTarget = MetricRange(lower: 35, upper: 45)
    var speedTarget = MetricRange(lower: 35, upper: 50)
    var speedGaugeMaximum: Double = 100
    var speedUnit: SpeedUnit = .kilometresPerHour
}
```

Validation rules:

- Angle range: `0 ≤ lower < upper ≤ 90`
- Speed range: `0 ≤ lower < upper ≤ speedGaugeMaximum`
- Speed gauge maximum: positive and greater than the speed target upper bound
- Suggested speed maximum choices: 60, 80, 100, 120, 160 km/h, plus a validated custom value

### 5.3 Calibration state

```swift
enum CalibrationState: Equatable, Sendable {
    case unavailable
    case calibrating(progress: Double?)
    case calibrated(referenceID: UUID, calibratedAt: Date)
    case stale(reason: CalibrationStaleReason)
    case failed(message: String)
}
```

The UI consumes this state; the sensor service owns how calibration is calculated.

## 6. Shared navigation

- Root navigation contains two tabs: **Live** and **Runs**.
- Live is the default tab.
- Run Details is pushed within the Runs navigation stack.
- Returning from Run Details preserves scroll position, active filters, and sort order.
- Settings can be reached from Live and Runs. Run Details may also show Settings to match the mockup.
- Bottom navigation remains visible on all three screens unless native platform conventions strongly favor hiding it on pushed details. If hidden, behavior must remain consistent across all detail screens.

## 7. Screen 1 — Live Wheelie

### 7.1 Purpose

Show current pitch angle, current speed, live wheelie duration, and current-attempt maxima. Do not show prior attempts, all-time best hold, or attempt count.

### 7.2 State matrix

| State | Header | Content | Interaction |
|---|---|---|---|
| Calibrating | No small duplicate status spinner | Entire screen dimmed; one prominent centered spinner and instruction | Settings may remain available only if safe; live values unavailable |
| Calibrated, idle | Green dot + `CALIBRATED` | Meters active at current baseline; time `0.0s` | Target/settings controls enabled; tapping the status pill forces recalibration (shows overlay immediately) |
| Calibrated, wheelie active | Green dot + `CALIBRATED` | Meters and time update live | Configuration controls disabled |
| Calibration stale/lost | Transition to calibrating overlay | Freeze or blank live values | Require recalibration |
| Sensor failure | Error message with retry | No live values | Retry and settings available |

### 7.3 Calibrated layout

#### Header

- A centered rounded status surface containing one steady green dot followed by `CALIBRATED`.
- The status pill is tappable: tapping it forces a transition to `calibrating` state, immediately showing the calibrating overlay. If the rider is moving when they tap, the overlay remains until the validity gate opens (i.e., until they stop). This prevents riding against stale bias while believing recalibration occurred.
- One settings gear at the top-right.
- Do not show session duration or attempt number.

#### Dual vertical meters

Place two equal meters side by side:

- **Left:** Angle
- **Right:** Speed, horizontally mirrored so external scale labels sit on the far right

Recommended geometry at 390 pt width:

- Meter visual height: 430–480 pt, responsive
- Meter track width: 34–40 pt
- Gap between meter centers: 112–136 pt
- Tick-to-track gap: 8 pt

##### Angle meter

- Fixed scale: 0° at bottom, 90° at top.
- Major labels: 0°, 15°, 30°, 45°, 60°, 75°, 90°.
- Minor tick every 3° or 5°; avoid visual noise.
- Current cursor example: 38°.
- Target example: 35°–45°.
- Show `ANGLE` above the meter.
- Place the current value outside the meter on the left.
- Place a small target-edit/sliders button beside `TARGET 35°–45°`.

##### Speed meter

- Default scale: 0 at bottom, 100 km/h at top.
- Major labels: 0, 25, 50, 75, 100.
- Minor tick every 5 km/h.
- Current cursor example: 42 km/h.
- Target example: 35–50 km/h.
- Show `SPEED` above the meter.
- Place the current value outside the meter on the right.
- Place a target-edit/sliders button beside `TARGET 35–50`.
- Show an editable `MAX 100 km/h` control near the meter title/top.

##### Meter fill behavior

The track above the current cursor is always dark and unfilled.

```text
fillFraction = clamp(currentValue / scaleMaximum, 0, 1)
cursorY = trackBottom - (fillFraction × trackHeight)
fillRect = track from trackBottom up to cursorY
```

- Clip the fill to the rounded track.
- Fill and unfill continuously as the value changes.
- Use a monochromatic dark-blue-to-moderate-blue fill. The gradient is clipped to the filled portion only.
- Do not use a full-height gradient behind an empty track.
- Draw target ranges as translucent bands spanning their calibrated lower and upper positions.
- Draw the current cursor as a crisp horizontal line and small circular marker.
- Cursor movement should be continuous; use a short ease-out or spring with no overshoot.

Suggested live smoothing:

```text
displayValue(t) = α × sample(t) + (1 - α) × displayValue(t-1)
α ≈ 0.20–0.35 at 30 Hz
```

The stored run uses raw/filtered sensor data from the telemetry service, not animation-interpolated display values.

#### Bottom live metrics

Use three equal compact blocks in this exact left-to-right order:

1. **ANGLE** — current value `38°`; sublabel `MAX 47°`
2. **WHEELIE TIME** — live value `4.2s`
3. **SPEED** — current value `42 km/h`; sublabel `MAX 48`

The left and right metrics align spatially with their respective meters.

### 7.4 Calibrating layout

- Render the same underlying dual-meter layout in an inactive state.
- Set values to em dashes and keep tracks unfilled.
- Dim the entire content using `surfaceOverlay`.
- Show exactly one prominent centered indeterminate spinner.
- Below it show `CALIBRATING`.
- Below that show `Ride in a straight line at a constant speed`.
- Do not show another calibration icon or spinner in the header.
- Do not show a green status light until calibration succeeds.
- Announce calibration completion through VoiceOver and optional haptic feedback.

### 7.5 Target and scale editing

Tapping an angle/speed target control opens a bottom sheet:

- Title: `Angle Target` or `Speed Target`
- Dual-handle range slider
- Two numeric fields: Lower and Upper
- Units shown explicitly
- `Reset` secondary action
- `Apply` primary action
- Inline validation; Apply disabled when invalid

Tapping `MAX 100 km/h` opens a compact scale selector with presets and a custom option.

While a wheelie is active:

- Disable these controls.
- If tapped, show a non-blocking message: `Finish the current run to change targets.`

### 7.6 Live attempt lifecycle

Suggested defaults, owned by the telemetry layer:

- Begin an attempt when calibrated angle remains above 8° for at least 150 ms.
- End an attempt when angle remains below 5° for at least 250 ms.
- Discard accidental events shorter than 0.4 s unless debugging mode is enabled.
- Reset current-attempt maximums only when a new attempt begins.
- Persist the completed run atomically when it ends.

These thresholds should be configuration constants, not hardcoded UI values.

### 7.7 SwiftUI component sketch

```swift
struct LiveWheelieView: View {
    @StateObject var model: LiveWheelieViewModel

    var body: some View {
        ZStack {
            liveContent
                .allowsHitTesting(!model.isAttemptActive)

            if model.requiresCalibration {
                CalibrationOverlay(
                    message: "Ride in a straight line at a constant speed"
                )
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.displayAngle)
        .animation(.easeOut(duration: 0.12), value: model.displaySpeed)
    }
}
```

## 8. Screen 2 — Past Runs

### 8.1 Purpose

Provide a modern, scan-friendly history of completed runs. Each entry highlights only:

- Wheelie duration
- Maximum angle
- Maximum speed

Do not display attempt sequence numbers such as `#12`.

### 8.2 Header and controls

- Back chevron if the screen is presented inside a navigation stack; omit if it is the root of the Runs tab.
- Title: `PAST RUNS`.
- Subtitle: dynamic count and scope, e.g. `12 attempts today`.
- Settings gear at top-right.
- Three independent sort/filter chips: `TIME`, `ANGLE`, `SPEED`.
- One compact general filter/sliders control at the far right.
- Optional explanatory caption: `Color ranked to your personal range`.

#### Sort behavior

- First tap selects the metric and sorts descending.
- Repeated tap toggles descending/ascending.
- Selected chip uses a blue outline and slightly raised surface.
- Only one primary sort key is active.
- Default sort is most recent.
- The general filter sheet controls date scope and numeric min/max filters.

### 8.3 Row design

- Use compact rounded list cells or edge-to-edge grouped cells, not tall dashboard cards and not a rigid spreadsheet grid.
- Target height: 76–84 pt.
- Entire row is tappable and pushes Run Details.
- Far-right chevron is visual confirmation only; it is part of the row hit target.
- Use timestamp as the primary identifier, e.g. `9:41 AM`.
- Use relative time below it, e.g. `Just now`, `3 min ago`.
- Optional tiny badges:
  - `LATEST` on the newest run
  - `LONGEST` on the longest-duration run in the active history scope

Within each row, align three compact metric values under shared column headings:

- `TIME`
- `ANGLE`
- `SPEED`

Do not repeat full labels such as `MAX ANGLE` inside every row.

### 8.4 Personal-range color normalization

Normalize each field independently. Never use one numeric scale across duration, angle, and speed.

For metric value `x`:

```text
t = clamp((x - fieldMinimum) / (fieldMaximum - fieldMinimum), 0, 1)
```

Anchors:

- `fieldMinimum`: personal worst in the active date/history scope before row-level metric filters hide results
- `fieldMaximum`: personal best in the same scope
- Recalculate anchors when the date/history scope changes
- Sorting does not change anchors
- A numeric filter does not change anchors, preventing colors from jumping while filtering

If all values are equal, treat all as `t = 1` because they share the personal best.

Piecewise color stops:

| `t` | Color |
|---:|---|
| 0.00 | `rangeLowIndigo` |
| 0.33 | `rangeLowBlue` |
| 0.66 | `rangeMidTeal` |
| 1.00 | `rangeHighGreen` |

Interpolate in OKLCH when available. Linear RGB interpolation is an acceptable fallback. Do not add yellow to the high endpoint.

Apply the computed color to:

- The numeric value and unit
- A tiny intensity bar beneath the value

The bar's filled length may also represent `t`, but color must remain the primary encoding. Include accessible text such as `Personal best` because color alone cannot communicate ranking.

### 8.5 Example mapping

Given the following runs:

| Time | Duration | Max angle | Max speed |
|---|---:|---:|---:|
| 9:41 AM | 4.2 s | 47° | 48 km/h |
| 9:38 AM | 6.1 s | 44° | 52 km/h |
| 9:34 AM | 3.7 s | 39° | 45 km/h |
| 9:29 AM | 5.4 s | 46° | 50 km/h |
| 9:25 AM | 2.8 s | 35° | 41 km/h |

The brightest green values are independently:

- Duration: 6.1 s
- Angle: 47°
- Speed: 52 km/h

The darkest indigo values are independently:

- Duration: 2.8 s
- Angle: 35°
- Speed: 41 km/h

### 8.6 Empty, loading, and error states

- Loading: use 4–6 skeleton rows with no fake values.
- Empty: `No runs yet` and `Complete a wheelie to see it here.` Include a button to return to Live.
- Filtered empty: `No runs match these filters` and a `Clear filters` action.
- Load error: inline retry state; do not replace the entire tab if cached runs are available.

### 8.7 SwiftUI structure

```swift
NavigationStack {
    LazyVStack(spacing: 8) {
        ForEach(viewModel.filteredRuns) { run in
            NavigationLink(value: run.id) {
                RunHistoryRow(
                    run: run,
                    colors: viewModel.relativeColors(for: run)
                )
            }
            .buttonStyle(.plain)
        }
    }
    .navigationDestination(for: WheelieRun.ID.self) { id in
        RunDetailsView(runID: id)
    }
}
```

## 9. Screen 3 — Run Details

### 9.1 Purpose

Explain how one completed wheelie unfolded over time without duplicating the history list. Use the run's stored configuration snapshot.

### 9.2 Header

- Back chevron.
- Title: `RUN DETAILS`.
- Date and time, e.g. `Today · 9:38 AM`.
- Optional badge such as `LONGEST`.
- Share/export icon.
- Settings gear.

### 9.3 Hero summary

Use one softly elevated horizontal surface divided into three equal regions:

1. `WHEELIE TIME` — e.g. `6.1s`; show `PERSONAL BEST` only when applicable
2. `MAX ANGLE` — e.g. `44°`
3. `MAX SPEED` — e.g. `52 km/h`

Use bright green for a genuine personal-best value. Normal strong values use teal.

### 9.4 Synchronized charts

Use two vertically stacked charts sharing the same x-domain `[0, run.duration]`.

#### Angle chart

- Y-domain: 0°–90°.
- Plot the angle sample series.
- Draw the recorded angle target band behind the trace.
- Label the band at its right edge, e.g. `35°–45°`.
- Mark the angle maximum with a small bright-green point and numeric label, e.g. `44°`.
- This is the angle maximum only; do not label it generically as `Peak`.

#### Speed chart

- Y-domain: 0–the run's stored speed gauge maximum.
- Plot the speed sample series.
- Draw the recorded speed target band behind the trace.
- Label the band at its right edge, e.g. `35–50 km/h`.
- Mark the speed maximum with a separate bright-green point and numeric label, e.g. `52`.
- The angle and speed maxima can and usually will occur at different timestamps.

#### Shared scrubber

- A horizontal drag on either chart sets one shared `selectedTime`.
- Draw one vertical scrubber across both chart plot areas.
- Show a time bubble above the angle chart, e.g. `3.8s`.
- Interpolate and display both values at `selectedTime`, e.g. `42°` and `48 km/h`.
- Clamp the scrubber to the run domain.
- On touch end, keep the last selection until the user taps outside the charts or presses a clear affordance.

Interpolation:

```text
Given samples A before t and B after t:
u = (t - A.time) / (B.time - A.time)
value(t) = A.value + u × (B.value - A.value)
```

Downsample long series for drawing while retaining raw samples for maxima and scrubber interpolation. A largest-triangle-three-buckets or min/max bucket strategy is acceptable. Target no more than 300 rendered points per chart.

### 9.5 Insight strip

Show exactly three compact values:

1. `ANGLE IN RANGE` — total duration across all angle intervals, e.g. `3.9s`
2. `AVG SPEED` — time-weighted average while the run is active, e.g. `46 km/h`
3. `SPEED IN RANGE` — total duration across all speed intervals, e.g. `3.4s`

Do not show a generic `Peak At` value. Maximum angle and maximum speed are separate and already shown above.

### 9.6 One-line interactive interval timeline

The bottom timeline communicates every time the run entered and exited either target range.

#### Required geometry

- Exactly one horizontal baseline.
- Domain: 0.0 s to `run.duration`.
- `LIFT 0.0s` at the left endpoint.
- `DOWN {duration}s` at the right endpoint.
- No second line, no stacked tracks, no bracket/duration lines.

#### Rendering multiple intervals

- Draw every angle interval as a translucent teal segment directly on the baseline.
- Draw every speed interval as a translucent blue segment directly on the same baseline.
- Do not vertically offset angle and speed.
- Overlapping pixels use screen/additive blending, producing a brighter blue-teal overlap.
- Gaps reveal the muted baseline and indicate time outside both ranges.
- Use rounded segment caps.
- Small endpoint dots may be shown, but labels appear only for a selected segment.

Example:

```text
Angle intervals: 1.2–2.1, 2.3–3.1, 3.2–5.4
Speed intervals: 0.4–1.0, 1.6–2.7, 3.1–4.8
```

#### Interval detection

Calculate intervals independently per metric using the run's configuration snapshot.

1. A sample is in range when `lower ≤ value ≤ upper`.
2. Linearly interpolate exact boundary-crossing time between adjacent samples.
3. Ignore isolated in-range fragments shorter than 0.15 s.
4. Merge two intervals separated by a gap of 0.10 s or less to prevent sensor jitter from creating false fragments.
5. Preserve every remaining interval; never reduce the result to only the longest interval.
6. Total in-range duration is the sum of all interval durations after cleanup.

Keep the debounce/merge constants configurable and unit tested.

#### Interaction

Instruction: `Tap a segment for details`.

On tap:

- Convert tap x-coordinate to time.
- Hit-test all interval segments whose time domain contains the tapped time, with an expanded touch radius.
- If exactly one segment matches, select it.
- If angle and speed overlap at the tapped point, show a compact two-option chooser or a combined popover listing both; never silently choose one.
- Highlight the selected segment with a subtle glow or slightly thicker outline on the same baseline.
- Show only that segment's endpoint labels to avoid clutter.

Selected detail bubble format:

```text
ANGLE · RANGE 3 OF 3
3.2s → 5.4s
2.2s in range
```

For speed, substitute `SPEED`. `RANGE n OF N` is based on chronological order for that metric.

- Tapping the selected segment again dismisses the bubble.
- Tapping empty timeline space clears selection.
- Dragging across the timeline may snap between interval segments as an optional enhancement.
- Keep the popup above the bottom navigation and reposition it horizontally to avoid clipping.

#### SwiftUI Canvas sketch

```swift
Canvas { context, size in
    let y = size.height / 2
    let x: (TimeInterval) -> CGFloat = {
        CGFloat($0 / run.duration) * size.width
    }

    drawBaseline(in: &context, from: 0, to: size.width, y: y)

    context.drawLayer { layer in
        layer.blendMode = .screen
        for interval in run.speedIntervals {
            drawSegment(in: &layer, interval, y: y, color: .speedInterval)
        }
        for interval in run.angleIntervals {
            drawSegment(in: &layer, interval, y: y, color: .angleInterval)
        }
    }
}
```

The pseudocode is illustrative; equivalent drawing APIs are acceptable.

### 9.7 Share/export

The share action should export a compact summary and optionally a CSV/JSON telemetry file. Do not render or share content automatically. The user must explicitly confirm through the platform share sheet.

Suggested CSV fields:

```text
elapsed_seconds,angle_degrees,speed_kph
```

## 10. Accessibility

### 10.1 VoiceOver / screen readers

- Live meter examples:
  - `Angle, 38 degrees, target 35 to 45 degrees, current maximum 47 degrees.`
  - `Speed, 42 kilometres per hour, target 35 to 50, current maximum 48.`
- Calibration overlay: announce once when calibration begins and once when complete.
- History row: expose as one button with timestamp and all three values.
- Relative color must not be the only ranking signal. Include `personal best`, `lowest in selected period`, or percentile in the accessibility value.
- Chart scrubber announces selected time, angle, and speed as one grouped element.
- Timeline segments expose metric, ordinal, start, end, and duration.

### 10.2 Dynamic Type

- Support at least iOS Accessibility Large.
- At larger categories, allow history row height to expand and stack metric values below the timestamp.
- On Live, preserve large metric values; truncate or wrap labels before shrinking the values.
- Charts may keep fixed axis-label size but must provide a text summary for screen-reader users.

### 10.3 Contrast and motion

- Meet WCAG AA contrast for text.
- Color-coded history values must remain readable against the surface at every interpolation stop.
- Respect Reduce Motion: update meter cursors without spring animation and disable pulsing effects.
- Haptics are optional and must not fire continuously with live updates.

## 11. Localization and units

- Use locale-aware time and date formatting.
- Do not build timestamps from hardcoded strings.
- Support km/h initially; model units so mph can be added without schema migration.
- Store canonical speed in metres per second or km/h consistently; convert only for display.
- Use locale-aware decimal separators.
- Keep units out of numeric parsing fields and display them as adjacent labels.

## 12. Performance and lifecycle

- Consume sensor updates at the service's native rate, but render UI at no more than the display refresh rate.
- Throttle state publication to approximately 30 Hz if higher rates cause excessive SwiftUI invalidation.
- Use an observable view model isolated to the main actor; sensor processing should occur off the main actor.
- Do not recompute all historical color anchors on every row render.
- Precompute range intervals when a run is finalized and validate/recompute after schema upgrades.
- Persist raw samples in a compact format; consider delta timestamps and binary storage for long sessions.
- Pause nonessential chart work when the app enters the background.

## 13. Suggested SwiftUI architecture

```text
App/
  WheelieTrackerApp.swift
  RootTabView.swift
DesignSystem/
  AppColors.swift
  AppTypography.swift
  AppSpacing.swift
  TelemetryCard.swift
Models/
  TelemetrySample.swift
  WheelieRun.swift
  RangeInterval.swift
  RiderPreferences.swift
Services/
  MotionService.swift
  SpeedService.swift
  CalibrationService.swift
  RunRecorder.swift
  RunRepository.swift
Features/Live/
  LiveWheelieView.swift
  LiveWheelieViewModel.swift
  VerticalTelemetryMeter.swift
  CalibrationOverlay.swift
  TargetRangeEditor.swift
Features/Runs/
  PastRunsView.swift
  PastRunsViewModel.swift
  RunHistoryRow.swift
  RunFiltersSheet.swift
  RelativeMetricColorScale.swift
Features/RunDetails/
  RunDetailsView.swift
  RunDetailsViewModel.swift
  TelemetryChart.swift
  SharedChartScrubber.swift
  RangeIntervalTimeline.swift
```

Use protocols around sensor and persistence services so previews and tests can inject deterministic sample streams.

## 14. State ownership

| State | Owner | Persistence |
|---|---|---|
| Raw motion/speed stream | Sensor services | No, until attached to run |
| Calibration | Calibration service | Persist reference metadata; invalidate when stale |
| Active run | Run recorder | Temporary, then atomically persisted |
| Target ranges/top speed | Preferences store | Yes |
| Historical run/config snapshot | Run repository | Yes |
| History sort/filter | Past Runs view model | Session; optionally restore last selection |
| Chart scrubber selection | Run Details view model | No |
| Selected range interval | Run Details view model | No |

## 15. Error handling

- Location unavailable: show speed as unavailable without fabricating `0`; explain permission requirement outside active riding.
- Motion unavailable: block calibration and show retry/instructions.
- Calibration lost during a run: mark the run incomplete or low-confidence; do not silently save normal-looking telemetry.
- Corrupt historical samples: show summary metrics if valid and replace charts with `Telemetry unavailable`.
- Missing configuration snapshot in migrated data: use a clearly marked legacy fallback, not current targets without disclosure.
- Empty interval set: show the single muted baseline and `No time in configured ranges`.

## 16. Acceptance criteria

### 16.1 Live Wheelie

- [ ] Angle scale is always 0°–90°.
- [ ] Speed scale uses the configured maximum.
- [ ] Each meter fills only from zero to the current cursor.
- [ ] Track above the cursor remains unfilled.
- [ ] Angle is left; speed is right and mirrored.
- [ ] Bottom order is Angle, Wheelie Time, Speed.
- [ ] Current-attempt maxima update without showing history statistics.
- [ ] Target ranges and speed maximum are editable while idle.
- [ ] Calibrating state dims the entire screen.
- [ ] Calibrating state contains exactly one spinner and the correct instruction.
- [ ] Calibrated state contains one green dot and `CALIBRATED`.

### 16.2 Past Runs

- [ ] No hash/attempt numbering appears.
- [ ] Rows are compact and fully tappable.
- [ ] Time, angle, and speed can each be selected for sorting/filtering.
- [ ] Metric colors normalize independently.
- [ ] Each field's personal best is bright green.
- [ ] No yellow appears in the scale.
- [ ] Selecting a row opens the correct Run Details record.
- [ ] Sort/filter state survives return from details.

### 16.3 Run Details

- [ ] Hero metrics show duration, max angle, and max speed.
- [ ] Angle and speed charts share one time selection.
- [ ] Both target bands remain visible on their main graphs.
- [ ] Angle and speed maxima use separate graph markers.
- [ ] No generic `Peak At` metric or timeline event appears.
- [ ] Insight strip shows angle in range, average speed, and speed in range.
- [ ] Bottom visualization contains exactly one baseline.
- [ ] Every valid in-range interval is rendered, not only the longest.
- [ ] Angle and speed intervals occupy the same line and blend where overlapping.
- [ ] Tapping one segment shows metric, ordinal, start, end, and duration.
- [ ] Tapping an overlap does not silently choose the wrong metric.
- [ ] Historical target bands come from the run snapshot.

## 17. Test fixtures

Provide deterministic fixtures for previews, snapshot tests, and cross-platform comparison:

1. **Calibrating:** no values, inactive tracks, overlay visible.
2. **Calibrated idle:** angle 0°, speed 18 km/h, time 0.0 s.
3. **Active run:** angle 38°, max angle 47°, speed 42 km/h, max speed 48 km/h, time 4.2 s.
4. **History:** at least eight runs with distinct minima/maxima per field.
5. **Repeated intervals:** three angle and three speed intervals with partial overlap.
6. **No intervals:** valid run that never enters either configured range.
7. **Complete overlap:** angle and speed intervals cover the same time span.
8. **Single-value history:** all personal-range values equal.
9. **Long run:** at least 10,000 samples to verify downsampling and interaction performance.
10. **Accessibility:** extra-large text and screen-reader labels.

## 18. Definition of done

The feature is complete when:

- The three screens meet all acceptance criteria.
- Sensor-driven values are reproducible from stored test fixtures.
- History colors and range intervals are covered by unit tests.
- Live meter fill and cursor behavior are covered by visual/snapshot tests.
- Both calibration states are covered by UI tests.
- Run Details supports repeated overlapping intervals on one line.
- VoiceOver can understand all essential telemetry without relying on color.
- No active-riding workflow requires tapping the screen.

