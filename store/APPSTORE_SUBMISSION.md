# Loftmeter — App Store Submission Package

Publisher location: Ottawa, Ontario, Canada. Primary market: Canada (English),
with Canadian-French considerations noted. This folder holds everything App
Store Connect asks for that is *not* the binary itself.

Bundle id: `com.adeesh.MotoTelemetryApp` · Display name: **Loftmeter**

---

## 0. Prerequisites (one-time, you must do these)

- [ ] **Apple Developer Program membership** — US$99/yr, enrolled as an
      individual (sole proprietor) at your Ottawa address. Business enrollment
      needs a D-U-N-S number; individual does not.
- [ ] **Signing** — a Distribution certificate + App Store provisioning profile
      (Xcode "Automatically manage signing" handles this once the account is set).
- [ ] **App record created** in App Store Connect (name "Loftmeter", primary
      language English (Canada), bundle id above, SKU e.g. `loftmeter-001`).
- [ ] **Bank + tax forms** in App Store Connect → Agreements, Tax, and Banking —
      required even for a *free* app before it can go live. Canadian tax form
      (W-8BEN for US withholding) + Canadian banking details.

## 1. Required URLs (must be live, reachable HTTPS)

- [ ] **Privacy Policy URL** — MANDATORY for every app. Draft in `privacy-policy.md`.
      Host it (GitHub Pages, your site, or an S3+CloudFront static page).
- [ ] **Support URL** — MANDATORY. Can be a simple page or a mailto-style page.
      Draft in `support.md`.
- [ ] Marketing URL — optional.

## 2. App Privacy ("nutrition label") — App Store Connect questionnaire

See `app-privacy-answers.md` for the exact answers to give. Summary: the app
collects **Location (Precise)** used for **App Functionality only**, **not linked
to identity**, **not used for tracking**. Everything else (runs, angles) is stored
**on device**, which Apple does *not* count as "collection" as long as it never
leaves the phone.

- [ ] Fill the questionnaire to match `app-privacy-answers.md`.

## 3. Export Compliance

- [ ] Declare encryption usage. Loftmeter uses only standard OS HTTPS/TLS (if any
      network at all) and no proprietary crypto → qualifies for the exemption.
      Add `ITSAppUsesNonExemptEncryption = NO` to Info.plist (done — see below)
      so App Store Connect stops asking every build.

## 4. Age Rating

- [ ] Complete the age-rating questionnaire. Expected rating **4+** (no
      objectionable content). One judgment call: the app depicts/encourages
      motorcycle stunts — there is no Apple age-gate for that, but see the
      **safety disclaimer** requirement in §6 (this is the real review risk).

## 5. Screenshots & Metadata

- [ ] Screenshots: **6.7"** (iPhone 15/16 Pro Max, 1290×2796) and **6.5"**
      (1284×2778 or 1242×2688) are the two required sizes as of 2026. 6.9" also
      accepted. Min 1 per size, up to 10. Capture: calibration screen, swipe
      alignment, live meter mid-wheelie, past runs list, run details.
- [ ] Description / keywords / promotional text — draft in `metadata.md`.
- [ ] App icon 1024 — already in the asset catalog (marketing icon, opaque). ✔

## 6. Motorcycle-stunt review risk — and why Loftmeter is well-positioned

An app in this space can draw a safety / "encourages dangerous or illegal
activity" look (Guideline 1.1.6 / 1.4.1). Loftmeter's actual design answers
this directly, and the framing below is TRUE to what the app does:

- **No leaderboard, no ranking, no gamified "go bigger" incentive.** The app
  does not reward larger or riskier wheelies.
- **The audio cue is a WARNING, not a reward** — it alerts the rider when the
  pitch angle gets too high so they can back off before losing control. The
  app's role is to help PREVENT going past a safe angle. (Accurate wording:
  it warns on instantaneous angle; do not claim crash *prediction*.)
- **It is a measurement/safety instrument** the rider reviews afterward, not a
  coach that instructs stunts.

Lead with this in the description, screenshots, and the App Review notes.

Belt-and-suspenders (recommended, not strictly required):
- [ ] **First-launch safety disclaimer** ("closed course / private property /
      obey local law; you assume all risk") — a one-time acknowledged sheet.
      Reinforces the position; spec in `SAFETY_DISCLAIMER.md`.

## 7. Canada / Quebec French

- **TestFlight & App Store technical submission: French NOT required.**
- **Consumer-facing obligation:** Quebec's Charter of the French Language + the
  Consumer Protection Act require French for products *marketed to Quebec
  consumers*, especially **paid** ones. For an English-first **free** beta from
  Ontario this is low risk. If/when you charge money or actively market in
  Quebec, localize (a) the App Store listing to fr-CA and (b) the in-app UI.
- [ ] Decision: ship en-CA only for launch; add fr-CA before monetizing/marketing
      in Quebec. See `localization-notes.md`.

## 8. App Review Notes (paste into the "Notes" box at submission)

See `review-notes.txt`.

---

### Order of operations
1. Enroll in Developer Program → create app record → fill banking/tax.
2. Host privacy-policy + support pages; paste URLs.
3. Add safety disclaimer sheet in-app (code) + `ITSAppUsesNonExemptEncryption`.
4. Archive in Xcode → upload → run TestFlight internally.
5. Fill App Privacy, age rating, export compliance, screenshots, metadata.
6. Submit with the review notes. Expect a possible safety back-and-forth.
