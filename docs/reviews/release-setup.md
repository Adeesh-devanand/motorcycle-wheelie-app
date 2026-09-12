# Release setup — TestFlight via GitHub Actions + fastlane

This project's local Mac (Xcode 15.2 / iOS 17.2 SDK) **cannot** build an App-Store-acceptable
binary: Apple requires the **iOS 26 SDK (Xcode 26+)**. The `Release (TestFlight)` GitHub
Actions workflow builds on a macOS runner with Xcode 26 and uploads with fastlane.

Authentication uses an **App Store Connect API key** (scoped, revocable) and **fastlane
match** (signing assets in a private git repo) — no Apple ID/password and no `.p12`
juggling. Nothing sensitive lives in this repo; everything is a GitHub **Actions secret**.

The workflow is **manual** (Actions → *Release (TestFlight)* → *Run workflow*) and refuses
to run until the secrets below exist.

## One-time: things only you can create (need your Apple login)

### 1. App Store Connect API key
App Store Connect → **Users and Access → Integrations → App Store Connect API** →
**+**. Role **App Manager** (or Admin). Download the `.p8` **once** (Apple never shows it
again). Note the **Key ID** and the **Issuer ID** (shown above the key list).

Base64-encode the `.p8` for the secret:
```bash
base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy   # now paste into ASC_KEY_CONTENT_B64
```

### 2. fastlane match (signing certificate + provisioning profile)
`match` stores your Apple **Distribution** cert + App Store provisioning profile in a
**separate private git repo**, encrypted. Create an empty private repo (e.g.
`Adeesh-devanand/loftmeter-signing`), then from a Mac (any Xcode — signing generation
does not need Xcode 26):
```bash
gem install fastlane
cd motorcycle-wheelie-app
# Generates the cert + profile and pushes them encrypted to the signing repo.
bundle exec fastlane match appstore --git_url https://github.com/<you>/loftmeter-signing.git
```
It prompts for a **passphrase** — remember it, it becomes `MATCH_PASSWORD`. This step
authenticates to Apple with the API key too; export it first:
```bash
export ASC_KEY_ID=... ASC_ISSUER_ID=... 
# (or run `match` interactively and sign in once to seed the assets)
```

## GitHub Actions secrets to add
Repo → **Settings → Secrets and variables → Actions → New repository secret**:

| Secret | What it is |
| --- | --- |
| `ASC_KEY_ID` | API Key ID from step 1 |
| `ASC_ISSUER_ID` | Issuer ID from step 1 |
| `ASC_KEY_CONTENT_B64` | base64 of the `.p8` file |
| `MATCH_GIT_URL` | HTTPS URL of the private signing repo |
| `MATCH_PASSWORD` | the match passphrase |
| `MATCH_GIT_BASIC_AUTHORIZATION` | base64 of `<gh-username>:<PAT>` so CI can clone the private signing repo — `printf '%s' 'user:ghp_xxx' \| base64` |

## Run it
Actions → **Release (TestFlight)** → **Run workflow** → lane `beta`. It fetches signing
via match, bumps the build number, archives Release with Xcode 26, and uploads to
TestFlight (internal testers get it immediately; promote to external / App Store from
App Store Connect).

## Notes
- The app is **iPhone-only** (`TARGETED_DEVICE_FAMILY = 1`), which also cleared the iPad
  multitasking orientation validation error.
- The regular **CI** workflow still builds/tests on Xcode 16.4 for fast feedback; only
  this release job needs Xcode 26, because only uploads hit the SDK floor.
- Revoke access anytime: delete the API key in App Store Connect and/or rotate the PAT —
  no credential of yours is embedded in the build.
