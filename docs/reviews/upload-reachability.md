# Diagnostic upload reachability

In Loftmeter Beta, open Settings > Diagnostics. **Test connection** requests a
presigned URL through the configured authenticated API, then PUTs one tiny,
synthetic NDJSON record. It uses Wi-Fi only, the same API key and content type as
log uploads, and never includes ride data. “Reachable” means both steps succeeded
at the displayed check time. API authorization failure, invalid responses, DNS,
TLS, timeouts and S3 rejection are reported separately. The API key and signed
URL query are never shown.

**Upload pending logs** retries eligible files immediately. The status explains
sharing being off, active/recent logs, pre-consent files, queued files and HTTP
errors. Logs remain subject to existing opt-in and recursive coordinate redaction;
files created before consent are not retroactively uploaded. A recently closed
file must be unchanged for 60 seconds. Uploads also retry when the app becomes
active or consent is enabled. Originals remain on the phone after a transfer.

Fixes include accepting either an API base URL or full /presign route without
duplicating the path, releasing failed presign claims, exposing preparation errors,
and using the injected defaults consistently for upload bookkeeping.

Remote check on 2026-09-13: the deployed API responds 403 without credentials,
and its API Gateway route and Lambda invoke permission exist. The checked-in
CloudFormation template lacked that permission; it now matches the deployed
resource. No live infrastructure changes were made. An authenticated backend
probe/token read and private S3 metadata inspection were blocked by automatic
approval review, citing the earlier instruction to skip S3. Therefore the exact
failure on the user's phone is not yet established; the new phone-side check
provides that evidence without retrieving server credentials.

Tests use mocked URLSession responses for the real probe method: GET authentication,
PUT content type, both-step success, S3 403, API 403, malformed JSON, offline, DNS,
timeout and retry eligibility. Core tests cover URL normalization/configuration,
response validation and safe error messages. Debug includes BETA code in this
project, so the CI simulator tests exercise the uploader.
