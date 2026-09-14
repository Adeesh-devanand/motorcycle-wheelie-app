# Recording and calibration milestone

New `recording-<time>-<unique-id>.ndjson` files combine raw sensors, diagnostics,
calibration, detector transitions and unsmoothed pipeline outputs. Capture begins
with sensing, before calibration can fail. Stopping sensing seals the file for
immediate upload; legacy session/raw exports remain available unchanged.

The Diagnostics list supports Select All / Deselect All, Share selected and Upload
selected. Closed recordings show duration and maximum valid GPS speed. Negative
speed is unavailable, not stationary. Uploads retain local originals. Automatic
uploads respect the sharing-consent date; explicitly selected older files may be
uploaded with sharing enabled. Coordinates remain redacted in cloud copies;
speed, accuracy, timing and replay state remain intact.

## Replay

`swift run motolog replay recording-....ndjson --stages stages.ndjson`

Version 2 reconstructs the live pipeline from each `pipelineStart` record, preserving
file arrival order (never moving delayed GPS fixes backwards to their fix time).
It handles `speedChanged` and `stop` controls and compares every saved
`pipelineOutput` field with replay, allowing 1e-9 numeric round-off. The JSON report
includes mismatches, speed availability and completeness. A mismatch or incomplete
capture exits with status 2. `--config` intentionally runs an alternative configuration
and reports differences without treating them as a replay failure.

Records:
- Header: file identity, build, device, config, wall time and explicit units.
- Raw `imu` / `gnss`: original samples, including calibration-phase samples.
- `pipelineStart`: actual mount axes, full bias estimate, gravity anchor, config,
  session identity, speed mode and target ranges.
- `pipelineControl` / `settings`: processing boundaries and setting changes.
- `pipelineOutput`: unsmoothed attitude, pitch, pitch rate, roll, bias, uncertainty,
  speed, vibration and flags at sensor rate.
- `detectorTransition`: onset/end/discard, confidence, boundary time and duration.
- Diagnostic rows: full-precision timestamps; event transitions are not coalesced.
- `display`: display timestamp, source sample timestamp, angle and available speed.
- `recordingEnd`: duration, sample count, max valid speed, dropped-record count and
  completeness. Missing footer means open/interrupted, never silently complete.

The reader tolerates only an incomplete final line; malformed complete rows fail.
Cloud-redacted GPS fixes decode with `coordinatesRedacted=true`; zero placeholders
are not valid geographic observations. Pipeline replay does not consume coordinates.
Legacy files still replay approximately, with an explicit missing-state warning.

## Scope and limits

Angle display uses a time-based filter with a faster response during rapid changes,
plus at most 16 ms of visual interpolation. Detection, scoring, audio and raw samples
never consume the display filter. Detection thresholds and steering model remain
unchanged until a labelled motorcycle recording is available.

Recordings flush and sync every 250 ms. Buffer overflow and a 512 MB per-recording
limit mark the file incomplete. File-write errors are exposed in Diagnostics. New
recordings are not automatically pruned; export and explicitly delete old files.
The recording remains bounded in memory; cloud redaction streams chunks off the main
thread. Unclean app termination can lose the buffered tail and leaves no clean footer.
