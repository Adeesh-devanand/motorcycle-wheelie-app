**K01 — portable iOS build and CI gate**

Owner: Codex. Base: `3a19910d2f560b881f895d9cc5aea17da74950f4` on `codex/live-meter-reference-polish`, including the user's corrected meter fill. Task claim is maintained in [task-status.md](task-status.md) on the integration branch. K01 is not complete until the actual app build/test gate passes and the change is accepted.

**Scope:** the Xcode project, `.github/workflows/ci.yml`, this evidence file, and the new `MotoTelemetryApp/MotoTelemetryApp/BetaUploadDefaults.xcconfig`. The small defaults file extends the initial K01 allowlist to resolve a clean-checkout build prerequisite: Debug/Beta previously referenced an ignored file that does not exist on CI. No application source or test implementation is changed.

Changes:

- Convert all 42 developer-home source references to `../../Sources/...`, relative to the directory containing the Xcode project.
- Make Debug/Beta read committed empty upload defaults and optionally include the existing gitignored `BetaUpload.xcconfig`. Local configured uploads retain their overrides; clean checkouts require no credentials. Release keeps its existing configuration and compilation conditions.
- Remove `motolog` from the app's package-product dependencies and framework link phase. It remains the independent executable in Package.swift; the app links the core library.
- Retain the package build/tests and add separate Debug, Beta, and Release iOS Simulator app builds, with app unit-test execution in Debug.
- Pin macOS 15 / Xcode 16.4 and select an available iPhone 16 / iOS 18.5 simulator by UUID. Fail explicitly if the pinned simulator is unavailable. Save build logs and result bundles even when a job fails.

The toolchain and simulator combination was checked against [the runner image inventory](https://github.com/actions/runner-images/blob/7b7aa2607800f9735b3062b0229bca92376e7bd2/images/macos/macos-15-Readme.md) during implementation. Runner availability can change; CI emits toolchain and destination discovery output to diagnose that separately from app failures.

**Baseline evidence:** at the base commit, 42/42 absolute source references do not exist in the clean Linux checkout, and `BetaUpload.xcconfig` is absent. The existing package-only CI passed ([run 34641085327](https://github.com/Adeesh-devanand/motorcycle-wheelie-app/actions/runs/34641085327)); that workflow does not build the iOS application. An actual baseline Xcode failure was not executed locally because this host has neither `swift` nor `xcodebuild`.

**Local validation:** all 42 replacement source paths resolve to existing files. The project no longer references the command-line executable as an app link dependency. Debug/Beta reference the committed defaults file; Release has not acquired a configuration override. Signing settings, bundle IDs, deployment minimums, Swift language versions, compilation conditions, and device families match the base. Both shared schemes parse as XML. Workflow YAML parses, embedded shell scripts pass `bash -n`, and `git diff --check` passes. The corrected meter source is byte-for-byte unchanged.

**Pending executable validation:** GitHub Actions must run the new core job and all three iOS matrix jobs. App unit tests are currently templates; running them establishes test-target wiring, not coverage of recorder correctness. The meaningful integration harness belongs to K02. UI tests, physical sensors, signing/archive distribution, and actual meter rendering are not validated by this K01 gate.

Reproduce on a Mac from the repository root, without creating BetaUpload.xcconfig:

```bash
export DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer
swift build
swift test
xcodebuild -list -project MotoTelemetryApp/MotoTelemetryApp/MotoTelemetryApp.xcodeproj
xcodebuild build \
  -project MotoTelemetryApp/MotoTelemetryApp/MotoTelemetryApp.xcodeproj \
  -scheme MotoTelemetryApp -configuration Debug \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
xcodebuild test \
  -project MotoTelemetryApp/MotoTelemetryApp/MotoTelemetryApp.xcodeproj \
  -scheme MotoTelemetryApp -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' \
  -only-testing:MotoTelemetryAppTests -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO
```

Repeat the build with `-configuration Beta` and `-configuration Release`. CI uses a fresh checkout under a `source` directory and resolves the test simulator UUID before testing. A failed app compiler check must be diagnosed explicitly; do not suppress it or call K01 green because the core package passes.
