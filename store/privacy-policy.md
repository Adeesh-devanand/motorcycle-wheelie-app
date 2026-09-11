# Loftmeter — Privacy Policy

_Last updated: 2026-09-11_

**Publication status:** this is a draft describing the implementation reviewed on
2026-09-11. The maintainer must supply a verified privacy contact before publishing
it. Beta upload controls described as absent below have not been implemented by
this documentation change.

Loftmeter is a motorcycle attitude-telemetry app. Its normal Release build stores
telemetry on your device. **Configured beta builds can automatically upload
sensor and diagnostic logs, including GPS coordinates, to the developer's AWS
service.** The distinction matters even if you do not have an account.

## Information used on your device

- **Location:** when location measurement is enabled and permission is granted,
  GPS readings provide speed. Raw diagnostic traces can contain latitude,
  longitude, speed, accuracy information, and timestamps. Completed run records
  store derived telemetry; they are separate from these raw traces.
- **Motion:** accelerometer and gyroscope readings support calibration and angle
  measurement. Raw traces can retain these readings for debugging.
- **Runs and settings:** the app stores attempts, target ranges, settings, and
  diagnostic information locally. Logs can include app version, device model,
  session identifiers, configuration, and sensor-processing events.

Sensor availability in the background depends on iOS permissions and execution
conditions; the app does not promise uninterrupted background recording.

## Normal Release builds

In the reviewed normal Release configuration, the beta uploader is excluded.
There is no developer-operated cloud synchronisation of your completed runs in
this configuration. This does not describe a build that has been customised to
enable beta uploading. Device backups and information you choose to share outside
the app are governed by the services you use.

## Configured beta builds

The reviewed Debug and Beta configurations include the beta uploader. A clean
checkout leaves its endpoint and token empty, disabling uploading. When valid
upload configuration is supplied, the app attempts uploads at launch and when it
moves to the background. **There is currently no in-app upload consent screen,
upload opt-out, Wi-Fi-only control, or coordinate-redaction mode.** Uploads can use
cellular data.

Eligible diagnostic files include raw sensor traces. Uploaded information can
therefore include precise location and motion readings as well as diagnostic
metadata. A randomly generated installation identifier persists in app settings
and groups uploads from that installation. Session identifiers and file timestamps
also accompany requests. These uploads are not anonymous merely because no name
or account is requested.

The developer can access uploaded logs for investigating sensor behaviour and app
reliability. The upload service uses Amazon Web Services. The deployment inspected
on **2026-09-11** was in **us-east-1 (United States)**, with public bucket access
blocked and encryption at rest enabled. That dated inspection is not a guarantee
about future deployments.

No advertising or cross-app advertising tracking integration was identified in
the reviewed app. The app does not request your name, email, or contacts. Its
installation identifier is used for diagnostics, not an advertising identifier.

## Retention and deletion

Completed runs stay in local storage until removed. The app provides individual
run deletion and a Delete All runs action. **These actions do not delete raw
diagnostic logs or previously uploaded server copies.** Local diagnostic files
are subject to a storage-budget cleanup, and successfully uploaded files may be
removed locally. This is not a fixed retention period for every local file.

The AWS inspection on 2026-09-11 found a 90-day lifecycle expiration rule for beta
diagnostic objects and 14-day retention for the Lambda log group. Lifecycle
expiration is asynchronous; this is not a promise of deletion at an exact hour.
There is no in-app server deletion request mechanism in the reviewed build.
Uninstalling removes the app's local container; it does not remove existing cloud
uploads or copies retained in device backups.

## Controls available today

You can manage sensor permissions in iOS Settings and use the app's run-deletion
actions. Revoking location permission does not erase location already captured in
pending logs, and does not prevent other diagnostic uploads. Turning off speed
measurement is not an upload opt-out. To avoid this beta upload path, use a build
with uploading disabled; the distributor must identify which build you received.

## Changes and contact

This policy must be updated when data practices change. **Maintainer action before
publication:** provide an actual support/privacy contact and a process for handling
questions and requests about previously uploaded beta data. No contact address or
cloud deletion service is asserted here.
