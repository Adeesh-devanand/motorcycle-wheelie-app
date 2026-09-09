# Localization notes — Canada / Quebec French

## Is French required to publish?
- **Apple technical requirement: NO.** You can ship an English-only app and an
  English-only App Store listing. Apple does not force fr-CA.

## The real obligation is legal, not Apple
Quebec's **Charter of the French Language** (Bill 96 amendments) and the
**Consumer Protection Act** require French for goods/services **offered to Quebec
consumers**, and this bites hardest on **paid, commercial** products and their
marketing. Key points:
- A **free**, English-first beta from Ontario is **low risk**.
- Once you **charge money** or **market to Quebec**, you should provide French:
  1. the **App Store listing** localized to **fr-CA** (name/subtitle can stay;
     description, keywords, screenshots text localized), and
  2. the **in-app UI** in French (at least the primary flows and legal text).
- French, when provided, must be **at least equal** in prominence to English.

## Recommendation for this launch
Ship **en-CA only** for the beta and initial free release. Localize to **fr-CA**
before you (a) introduce paid tiers or (b) actively market in Quebec.

## What fr-CA localization will involve later (scope, not now)
- Add `fr-CA` to the Xcode project's known regions and a `fr.lproj` /
  String Catalog (`Localizable.xcstrings`).
- Externalize the ~few dozen user-facing strings (currently hard-coded English:
  "Settings", "Diagnostics", "Data Integrity", "ANGLE"/"SPEED" meter labels,
  calibration prompts, Past Runs labels, the About rows, and the safety
  disclaimer).
- Localize the permission usage strings (Info.plist / build settings) to fr-CA.
- Localize the App Store listing + at least one screenshot set in App Store
  Connect.
- Have the French reviewed by a fluent speaker (Quebec French, not France French,
  for consumer-law comfort).
