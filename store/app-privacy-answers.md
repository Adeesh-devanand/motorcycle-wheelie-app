# App Privacy — submission worksheet

_Reviewed: 2026-09-11. This is a conditional worksheet, not a completed submission._

Answer for the **actual distributed app and its enabled services**. A configuration
name alone is insufficient: inspect the archive's compilation settings, embedded
configuration, dependencies, and actual network behaviour. Do not copy beta
answers to a verified local-only Release, or local-only answers to a configured
uploading build.

## Apple's definition

Data processed exclusively on-device does not need a collection declaration.
Transmission with retained off-device access does. The absence of an account does
not establish that data is unlinked when an installation identifier groups it.
Diagnostic purposes still require applicable disclosures. [Apple App Privacy
Details](https://developer.apple.com/app-store/app-privacy-details/).

## Build decision

| Verified distributed behaviour | Collection answer |
| --- | --- |
| Normal Release without BETA, no beta uploader, and no other retained off-device collection by the app or integrated services | **Data Not Collected**, once verified for the submitted archive. Location/motion permission descriptions are still needed. |
| Debug/Beta with empty default endpoint/token and no other collection | Uploads are disabled in this configuration. Verify the distributed build; do not assume a developer override is absent. |
| BETA compiled with valid endpoint/token and the opt-in upload path enabled | **Data Collected.** Complete the inventory below and verify actual server use. |

Current checked-in Debug and Beta app configurations define BETA. Their
BetaUploadDefaults.xcconfig has empty defaults with an optional local override.
Normal Release does not define BETA in the reviewed project. These facts describe
source baseline db40cd2af92a57182993a2c32037c048b4f2e887, not certification of a
previously shipped archive.

## Inventory for the current configured uploader

| Observed information | Questionnaire mapping / action |
| --- | --- |
| Older raw GNSS uploads retained server-side (current candidate redacts coordinate keys) | Verify actual distributed archive and retained legacy data. The current redacted export does not transmit these fields; do not assume older uploads were redacted. |
| Persistent installation UUID used to group uploads | Declare **Device ID**; it functions as an installation-level identifier even without IDFA or an account. |
| Sensor-processing events, errors, raw traces and configuration used for technical investigation | Declare **Other Diagnostic Data**; inspect timing/rate fields and their use for **Performance Data**. Do not label all uploaded logs “not collected.” |
| Motion samples, speed, session/device metadata | Inventory fields and actual uses. Include diagnostic classification where applicable; determine whether any use also requires **Other Data Types**, **Usage Data**, or **Fitness**. Lack of HealthKit is not by itself a classification test. |

**Linkage:** treat installation-grouped uploads as linked in this worksheet. No
pre-upload de-identification that breaks that grouping is implemented. A random
UUID or lack of a named account is insufficient evidence for “not linked.”

**Purpose:** technical diagnosis and support fit **App Functionality**. Confirm
whether the team also evaluates rider behaviour or product usage; declare
**Analytics** if that is an actual use. Do not claim a server-use restriction from
client code alone.

**Tracking:** no advertising/data-broker tracking path was identified in the
reviewed code. Confirm actual partner use before answering “No.” The installation
identifier alone does not establish Apple's advertising-tracking definition.

**Remaining inventory:** verify server/request logs, retained IP information and
any added dependencies. Do not blanket-answer “No” for every other category
without this check. Automated beta uploading does not qualify as an individually
chosen feedback-form submission.

## Before submission

Record archive/build identification, verified endpoint configuration (without
secrets), a synthetic-data network test, the final field/use inventory, and the
maintainer's approved questionnaire answers. Publish an accurate policy with a
real contact. Confirm the applicable privacy-manifest requirements separately;
the questionnaire is not a substitute for a manifest.

The candidate implements opt-in, post-consent eligibility, Wi-Fi-only transfers
and redacted export copies. Cloud deletion/contact operations remain outstanding. See [beta data flow and remaining
decisions](../docs/reviews/beta-data-flow.md).
