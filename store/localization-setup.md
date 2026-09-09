# Localization — how Loftmeter is set up

The app is now fully localizable. Adding a language later is a data task
(fill in translations), not a code refactor.

## How it works

- **`MotoTelemetryApp/.../Localizable.xcstrings`** — String Catalog for all
  in-app UI text. SwiftUI `Text("…")`, `Button("…")`, `navigationTitle("…")`,
  `Section("…")`, `.accessibilityLabel("…")` etc. take `LocalizedStringKey`
  automatically, so the English literal in the code IS the key. On build, Xcode
  extracts every such key into this catalog.
- **`MotoTelemetryApp/.../InfoPlist.xcstrings`** — String Catalog for the
  permission prompts (`NSMotionUsageDescription`,
  `NSLocationWhenInUseUsageDescription`,
  `NSLocationAlwaysAndWhenInUseUsageDescription`).
- **Service/non-View strings** that are built as plain `String` (not through a
  `Text`) are wrapped in `String(localized: "…")` so they are extractable too.
  Currently: the calibration blocking-reason strings in `CalibrationService.swift`.
- **`CalibrationScreen.title`** was changed from `String` to `LocalizedStringKey`
  so its four titles localize (the `.failed` case is the format key
  `"Couldn't calibrate:\n%@"`).
- The project's `knownRegions` includes `en`, `Base`, `fr`.

## Adding / editing a language

1. Open the project in Xcode.
2. Select `Localizable.xcstrings` (and `InfoPlist.xcstrings`) → the editor shows
   every key with a column per language. Click **+** to add a language, or edit
   the existing **fr** column.
3. Build once — Xcode auto-extracts any NEW `Text("…")` keys you've added since.
4. Translate the new/empty rows. `fr` (Canadian French) stubs are already filled
   in as a starting point; have a fluent Quebec-French speaker review them.

## Rules going forward (so it stays localizable)

- **Always** use a string literal directly in `Text(...)`, `Button(...)`, etc.
  Do NOT build a user-facing `String` and pass it in unless you wrap it with
  `String(localized:)`.
- For dynamic values, use interpolation inside the literal
  (`Text("Speed: \(kmh) km/h")`) — Xcode turns it into a format key.
- Keep units/number formatting locale-aware (`.formatted()`), not hand-built.

## The fr stubs are machine-drafted
The French values in the two catalogs are a reasonable starting draft, NOT
professionally reviewed. Before shipping French to Quebec consumers, have them
checked by a fluent speaker (Quebec French). See `store/localization-notes.md`
for the legal context.

## Still English-only in code (extracted on next Xcode build)
The ~100 `Text`/`Button`/`Section`/nav-title literals across the Features views
(ANGLE/SPEED meter labels, "Settings", "Diagnostics", "Data Integrity", Past
Runs labels, About rows, etc.) are already localizable keys — they just need
their `fr` values filled in once Xcode extracts them into `Localizable.xcstrings`
on the first build. The catalog currently seeds the service-code and calibration
strings that are NOT auto-extractable on Linux.
