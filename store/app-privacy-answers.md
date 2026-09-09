# App Privacy — App Store Connect questionnaire answers

Fill the "App Privacy" section in App Store Connect exactly as below.

## Does this app collect data?
**YES** — because it accesses precise location. (On-device-only storage of runs
is NOT "collection" per Apple, but the location *access* must be declared since
it is used to produce functionality even though it is not transmitted. Declare
it conservatively as below; if you are certain location never leaves the device
AND is not used beyond on-device functionality, Apple still expects it listed
under the data type with the "App Functionality" purpose.)

## Data types

### Location → Precise Location
- **Collected:** Yes
- **Linked to the user's identity:** **No** (no account, no identifier)
- **Used for tracking:** **No**
- **Purposes:** **App Functionality** only
  (NOT Analytics, NOT Product Personalization, NOT Advertising)

### Everything else
- Contact info: **No**
- Health & Fitness: **No** (pitch angle / speed are motion telemetry, not Health-kit data)
- Financial: **No**
- User Content: **No** (runs stay on device; not uploaded)
- Identifiers: **No**
- Usage Data: **No**
- Diagnostics: **No** (logs are on-device, not transmitted)

## Tracking
- **This app does not track.** Do not enable App Tracking Transparency; you make
  no cross-app/website tracking, so no `NSUserTrackingUsageDescription` is needed.

## Sensitive note
If you are 100% certain the app performs **zero** network transmission of
location (pure on-device), you *may* answer "Data Not Collected" entirely — but
the safe, defensible answer for review is the Location/App-Functionality/no-tracking
combination above. Pick one and keep the privacy policy consistent with it.
