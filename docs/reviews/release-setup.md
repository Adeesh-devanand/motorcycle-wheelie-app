# Release setup — TestFlight via GitHub Actions + fastlane

This project's local Mac (Xcode 15.2 / iOS 17.2 SDK) **cannot** build an App-Store-acceptable
binary: Apple requires the **iOS 26 SDK (Xcode 26+)**. The `Release (TestFlight)` GitHub
Actions workflow builds on a macOS runner with Xcode 26 and uploads with fastlane.

Signing uses the **App Store Connect API key only** — fastlane syncs (fetches or creates)
the distribution certificate and App Store provisioning profile at build time with that
key. **No `match`, no private signing repo, and no Ruby on your Mac.** Everything happens
on the runner, which has Ruby + fastlane preinstalled.

The workflow is **manual** (Actions → *Release (TestFlight)* → *Run workflow*) and refuses
to run until the three secrets below exist.

## One-time: create the App Store Connect API key (needs your Apple login)

App Store Connect → **Users and Access → Integrations → App Store Connect API** → **+**.
Role **App Manager** (or Admin). Download the `.p8` **once** (Apple never shows it again).
Note the **Key ID** (in the filename `AuthKey_<KEYID>.p8`) and the **Issuer ID** (shown
above the key list).

Base64-encode the `.p8` for the secret:
```bash
base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy   # paste into ASC_KEY_CONTENT_B64
```

## GitHub Actions secrets to add (only three)
Repo → **Settings → Secrets and variables → Actions → New repository secret**:

| Secret | What it is |
| --- | --- |
| `ASC_KEY_ID` | API Key ID (e.g. from `AuthKey_CU5V32396K.p8` → `CU5V32396K`) |
| `ASC_ISSUER_ID` | Issuer ID from App Store Connect (Integrations page) |
| `ASC_KEY_CONTENT_B64` | base64 of the `.p8` file |

Or from your own terminal (no Ruby needed):
```bash
gh secret set ASC_KEY_ID --body 'CU5V32396K'
gh secret set ASC_ISSUER_ID --body '<issuer-id>'
gh secret set ASC_KEY_CONTENT_B64 < ~/Downloads/AuthKey_CU5V32396K.p8.b64
```

Then delete the plaintext key so it isn't left on disk:
```bash
rm ~/Downloads/AuthKey_*.p8 ~/Downloads/AuthKey_*.p8.b64
```

## Run it
Actions → **Release (TestFlight)** → **Run workflow** → lane `beta`. It syncs signing via
the API key, bumps the build number, archives Release with Xcode 26, and uploads to
TestFlight (internal testers get it immediately; promote to external / App Store from
App Store Connect).

## Notes
- The app is **iPhone-only** (`TARGETED_DEVICE_FAMILY = 1`), which also cleared the iPad
  multitasking orientation validation error.
- The regular **CI** workflow still builds/tests on Xcode 16.4 for fast feedback; only
  this release job needs Xcode 26, because only uploads hit the SDK floor.
- The API key must have permission to manage certificates/profiles (App Manager or Admin)
  so the `cert`/`sigh` sync can fetch-or-create them.
- Revoke access anytime by deleting the API key in App Store Connect — no credential of
  yours is embedded in the build.
