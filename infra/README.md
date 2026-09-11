# Beta diagnostic-log upload backend (infra)

**BETA-ONLY.** This stack exists so beta testers' iOS clients can upload
NDJSON diagnostic logs, including raw traces that can contain precise location.
Installation IDs group files by installation; these logs are not anonymous. The **production app does not upload** — this
backend is only wired into beta builds.

## Architecture

```
iOS app  --GET /presign (X-Beta-Key)-->  API Gateway HTTP API
                                              |
                                              v
                                         Lambda (presign)  --generate_presigned_url-->
                                              |
iOS app  --PUT NDJSON body (presigned URL)-->  private S3 bucket (beta/<installID>/...)
```

No user auth. A shared static `X-Beta-Key` token is a simple abuse gate on the
presign call. The Lambda never touches the log body — it only mints a
presigned S3 `PUT` URL and the client uploads directly to S3.

## Shared client contract

The iOS client is built to this exact contract; do not change it without
updating the client in lockstep.

- **Endpoint:** `GET /presign?installID=<uuid>&session=<sessionID>&ts=<unixMillis>`
- **Required header:** `X-Beta-Key: <BetaUploadToken>`
- **Response JSON:**
  ```json
  {"uploadURL":"<presigned PUT url>","key":"beta/<installID>/<session>-<ts>.ndjson","expiresIn":900}
  ```
- **S3 key layout:** `beta/<installID>/<session>-<ts>.ndjson`

  `session` is opaque to the backend (only constraint: `^[A-Za-z0-9_\-]{1,64}$`), and
  the iOS client fills it with the **source log file's own name**, minus the
  extension — `session-20260910-204842`, `raw-20260910-211100`. That makes each
  object self-describing: you can tell a diagnostic log from a raw sample trace, and
  which device session produced it, from the key alone. `ts` is the source file's
  modification time, not upload time, so the key is deterministic per file and a
  retry overwrites rather than creating a near-duplicate. Objects written before
  2026-09-10 use a random UUID for `session` and carry no such information.
- **Presigned PUT:** requires `Content-Type: application/x-ndjson`, expires in **900s**.

The client must send the PUT with `Content-Type: application/x-ndjson` (it is
part of the signature — a mismatched or missing content type will be rejected
by S3 with `SignatureDoesNotMatch`).

## Deploy

Region assumed: **us-east-1** (presigned URLs are signed with SigV4 for this
region; deploy elsewhere only if you also point the client base URL there).

```sh
aws cloudformation deploy \
  --template-file infra/diagnostic-upload.yaml \
  --stack-name loftmeter-beta-diag \
  --parameter-overrides BetaUploadToken=<choose-a-long-random-token> \
  --capabilities CAPABILITY_IAM \
  --region us-east-1
```

Optional parameter overrides:

- `BucketName=<name>` — otherwise derived as `<stack>-<accountId>-diag`.
- `RetentionDays=90` — objects under `beta/` auto-expire after this many days (default 90).

Read the outputs after deploy:

```sh
aws cloudformation describe-stacks \
  --stack-name loftmeter-beta-diag --region us-east-1 \
  --query 'Stacks[0].Outputs' --output table
```

## Wire the app

Set the beta build's config from the stack outputs:

- **API base URL** → the `ApiEndpoint` output (call `<ApiEndpoint>/presign`).
- **Beta upload token** → the same value you passed as `BetaUploadToken`.

## IAM scope

The Lambda execution role is least-privilege: `AWSLambdaBasicExecutionRole`
(CloudWatch Logs) plus a single inline statement allowing **`s3:PutObject` only
on `arn:aws:s3:::<bucket>/beta/*`** in this one bucket. No `s3:*`, no other
buckets, no read/list/delete. (The role must hold `PutObject` because a
presigned PUT inherits the signer's permissions.)

## Retention & cost

- Objects expire after `RetentionDays` (default **90**) via an S3 lifecycle rule.
- Bucket is fully private (all four public-access blocks on) with SSE-S3
  (AES256) default encryption.
- API Gateway is throttled (burst 20 / rate 10). This limits request rate,
  not upload size, total storage, or spending. Review storage growth and costs;
  the shared token does not provide per-installation quotas.

## Teardown

The bucket has `DeletionPolicy: Retain`, so deleting the stack leaves the
bucket (and any logs) in place. To fully remove: empty the bucket, then
`aws cloudformation delete-stack --stack-name loftmeter-beta-diag`, then delete
the retained bucket manually.

## Reviewed K14 safeguards (deployment required)

The template denies non-TLS S3 access for both the bucket and its objects.
Existing encryption, object retention, presign expiry and client protocol remain
unchanged. Updating this template does not itself change the deployed stack.

HTTP API access logs retain only request ID, HTTP status and response latency
for 14 days. They deliberately omit source IP, installation/session identifiers,
headers, query strings, URLs, signed URLs and bodies. This does **not** redact
raw diagnostic objects already uploaded to S3 or solve client consent (K13).

Four CloudWatch alarms use five-minute sums:

| Alarm | Threshold | Purpose |
|---|---:|---|
| API `5xx` | 1 | Includes a handled presigner failure returning HTTP 500 |
| API `4xx` | 20 | Invalid requests, rejected tokens or request throttling |
| Lambda `Errors` | 1 | Unhandled execution failures |
| Lambda `Throttles` | 1 | Rejected Lambda invocations |

Missing data is treated as not breaching because an idle beta is normal.
These alarms do not detect an entirely silent client or measure upload success
at S3. Start with these thresholds and adjust using actual beta traffic.

`AlarmTopicArn=<existing-SNS-topic-ARN>` optionally routes alarm transitions to
SNS. **The default is alarm state in CloudWatch only; nobody is notified.**
Before relying on notifications, configure a same-region topic, its publish
permissions (and KMS policy if encrypted), confirmed subscriptions and a delivery
test. No topic, subscription, email recipient or deployment is created by this
change. Review the CloudFormation change set before deployment; API access-log
creation also requires the deployer's CloudWatch Logs delivery permissions.

Offline checks (Python with PyYAML available):

```sh
python -m unittest discover -s infra/tests -v
```

Tests check TLS policy scope, logging allowlist and metric dimensions/actions,
and deliberately mutate controls to prove regressions are rejected. They do
not replace CloudFormation validation or an approved deployment/delivery test.

AWS references: [HTTP API metrics](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-metrics.html),
[HTTP API logging](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-logging.html),
[access log variables](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-logging-variables.html),
and [S3 transport security](https://docs.aws.amazon.com/AmazonS3/latest/userguide/security-best-practices.html).
