# Current K13 implementation update

The current candidate implements persistent off-by-default consent, Wi-Fi-only
transfers, post-consent file creation cutoff, recursive coordinate-key redaction
in export copies, fail-closed malformed-log handling, and revocation cancellation.
Presign callbacks re-check the exact consent date before PUT; old consent epochs
cannot release work after opt-out/re-opt-in. Local originals remain subject to
storage budgets. Synthetic transport scheduling/redaction tests accompany this.

No cloud deletion service or privacy contact is invented; publishing the policy
still requires a real contact. No existing AWS objects were modified. The dated
baseline audit below is retained as historical evidence and superseded for client
behavior by this update.

# K13 — beta data flow and publication decisions

Documentation-only phase; reviewed source baseline
`db40cd2af92a57182993a2c32037c048b4f2e887` on 2026-09-11. No application control,
server deployment, or production archive certification is delivered by this
change. AWS observations below come from the dated review, not a new inspection.

## Implemented flow

| Stage | Current behaviour and evidence |
| --- | --- |
| Capture | [SpeedService](../../Sources/MotoTelemetryApp/Services/SpeedService.swift) supplies coordinates, speed and accuracy to GNSSFix. [Sample](../../Sources/MotoTelemetryCore/Sample.swift) retains latitude and longitude. MotionService supplies IMU samples. |
| Local raw logs | [RawSampleRecorder](../../Sources/MotoTelemetryApp/Services/Diagnostics/RawSampleRecorder.swift) writes encoded samples into Documents/logs/raw-*.ndjson. Headers include session ID, start date, device model, app version, configuration and a bike-profile reference. RunRecorder starts raw recording when enabled; it is distinct from completed-run storage. |
| Local diagnostic logs | [DiagnosticLog](../../Sources/MotoTelemetryApp/Services/Diagnostics/DiagnosticLog.swift) writes session logs in the same directory. Its size cleanup starts above 100 MiB and aims for 50 MiB while protecting recent files. Raw files have a separate 64 MiB cap. These are size controls, not fixed per-file expiry promises. |
| Build gate | [WheelieTrackerApp](../../Sources/MotoTelemetryApp/App/WheelieTrackerApp.swift) instantiates the uploader only under BETA. Debug/Beta define BETA; ordinary Release does not. [Default configuration](../../MotoTelemetryApp/MotoTelemetryApp/BetaUploadDefaults.xcconfig) supplies empty endpoint/token with an optional local override. |
| Configuration gate | [BetaDiagnosticUploader](../../Sources/MotoTelemetryApp/Services/Diagnostics/BetaDiagnosticUploader.swift), makeUploader, returns nil for missing/unexpanded credentials or an invalid HTTPS base. Empty defaults therefore disable uploads. |
| Trigger | The configured app starts upload cycles at launch and background transitions. No user consent/opt-out is checked. Network sessions allow cellular access. |
| Selection | pendingFiles selects eligible NDJSON files from the shared directory, skipping the current diagnostic file, uploaded/in-flight files and recently modified files. It does not restrict selection to summary logs or redact raw coordinates. |
| Request | GET /presign sends installation ID, sanitised session/file identifier and modification timestamp, with a shared token in X-Beta-Key. Installation ID is a UUID retained in UserDefaults. No identifiers or credentials are reproduced in this document. |
| Transfer | The file is uploaded directly to a presigned S3 URL. Upload bytes are the source file; no redacted export copy is created. |
| Success/failure | Success records the filename and attempts local-file deletion. Failure releases the in-flight claim for a later cycle. Local cleanup is not server deletion. |

Saved [WheelieRun](../../Sources/MotoTelemetryApp/Models/WheelieRun.swift) records
contain derived TelemetrySample values. Do not confuse them with raw GNSS files:
the verified coordinate-transmission path is the raw diagnostic uploader, not a
cloud run repository.

## Previously observed deployment — 2026-09-11

The [app and AWS review](2026-09-11-app-and-aws-review.md) records an inspection
around 19:37 UTC of loftmeter-beta-diag in us-east-1. It found:

- HTTP API → presigning Lambda → S3 uploads; eight raw-named files among 81 objects.
- Latitude/longitude fields in a sampled raw object and persistent installation
  prefixes. Prefix count is not a count of people.
- All S3 public-access blocks enabled, AES256 encryption, a 90-day expiration rule
  under beta/, no versioning, and Lambda log retention of 14 days.
- A shared-token check, 15-minute presigned URLs and API throttling. These do not
  make data anonymous or constitute an installation-owned deletion mechanism.
- No API stage access-log configuration or CloudWatch alarms in that inspection.
  Separately drafted K14 changes must not be described as deployed until verified.

The 90-day rule covers those diagnostic objects, not every possible downloaded
copy, local file, backup or operational log. S3 expiry is asynchronous. No new live
AWS access or deletion was performed for this documentation phase.

## Current controls and limits

Run deletion affects the local run repository. It does not clear the diagnostic
queue or request server deletion. Permission revocation prevents relevant future
sensor access but does not remove pending raw files. The speed switch is not an
upload switch. There is no implemented upload opt-in, coordinate-sharing mode,
Wi-Fi-only preference, cloud deletion UI, or user-visible installation identifier
for requesting deletion. Do not promise any of these in published copy yet.

## Decisions required for the second K13 phase

| Owner decision | Proposed implementation/acceptance contract |
| --- | --- |
| Who is the privacy contact and who handles requests? | Maintainer supplies verified contact details, operational ownership and a process for identifying and deleting eligible cloud data. Do not invent an address or promise unsupported deletion. |
| Should diagnostics be off by default? | Recommended: explicit persisted opt-in before scheduling upload, clear included-field disclosure, and revocation that stops future scheduling. Define cancellation of queued/in-flight transfers explicitly. |
| Are coordinates needed for normal diagnosis? | Recommended: redact coordinates from an export copy by default; retain local raw originals only under a stated local policy. If sharing coordinates is offered, require a separately explained choice. |
| What happens to logs recorded before consent? | Choose whether to exclude them or allow a clearly disclosed retrospective selection. Consent must not silently release the existing queue. |
| What is the retention/deletion contract? | Confirm retention of S3 objects, operational logs and downloaded copies; provide an implementable request path and avoid claiming instant expiry. |
| Is cellular upload appropriate? | Choose the default and a clear control; current implementation permits it. |
| What uses does the team make of uploaded data? | Confirm technical support versus behavioural/product analytics so questionnaire purposes reflect actual use. |

The planned app phase must prove with synthetic files and a fake transport:
no-consent schedules no uploads; redacted upload bytes contain no coordinate
fields; choices persist; revocation follows its stated queue contract; ordinary
Release does not instantiate the uploader. Add the corresponding app tests after
K02 is available. No real rider trace should enter fixtures or commits.

## Documentation validation

The policy and submission worksheet were compared against the source paths above
and the dated AWS review. Apple's primary [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/)
was checked for on-device collection, linkage, purposes and data-type definitions.
The questionnaire remains conditional on the actual submitted archive and server
uses. This documentation phase requires maintainer content review; it does not
need an app rebuild and does not complete K13's implementation phase.
