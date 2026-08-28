#!/usr/bin/env bash
# Extract the console log from an Xcode .xcresult launch bundle into readable slices.
#
# Usage:
#   ./extract-xcresult-log.sh <path-to-.xcresult> [outdir]
#
# Xcode writes run logs to:
#   ~/Library/Developer/Xcode/DerivedData/<App>-<hash>/Logs/Launch/Run-<App>-<timestamp>.xcresult
#
# Verified against Xcode 15.2 (build 15C500b). Newer xcresulttool deprecates
# `get --format json` in favour of `get log`; if that happens, adapt step 2.
set -euo pipefail

BUNDLE="${1:?usage: extract-xcresult-log.sh <path-to-.xcresult> [outdir]}"
OUT="${2:-.}"
mkdir -p "$OUT"

# 1. Root object -> find the consoleLogRef id.
xcrun xcresulttool get --path "$BUNDLE" --format json > "$OUT/_root.json"
REF=$(python3 - "$OUT/_root.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(d["actions"]["_values"][0]["actionResult"]["consoleLogRef"]["id"]["_value"])
PY
)

# 2. Console log object -> concatenate item payloads in order.
xcrun xcresulttool get --path "$BUNDLE" --id "$REF" --format json > "$OUT/_console.json"
python3 - "$OUT/_console.json" "$OUT/console-full.txt" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
parts = []
for item in d["items"]["_values"]:
    c = item.get("content", {})
    if isinstance(c, dict) and "_value" in c:
        parts.append(c["_value"])
open(sys.argv[2], "w").write("".join(parts))
PY

cd "$OUT"

# 3. App lines only, with the OS/process prefix stripped down to a timestamp.
grep 'MotoTelemetryApp\[' console-full.txt \
  | sed -E 's/^[0-9-]+ ([0-9:.]+) [^ ]+ MotoTelemetryApp\[[0-9:]+\] /\1 /' > app.txt

# 4. Signal only: drop the two known high-volume offenders.
#    (Remove this step once the log-volume defect is fixed — it should be a no-op.)
grep -vE 'autostart status|\[cal\] gate reason' app.txt > signal-only.txt

# 5. Focused slices.
grep -E '\[(cal|bias|CalibrationService|caltrack)\]' app.txt \
  | grep -vE 'autostart status|gate reason|bias collecting' > calibration-sequence.txt
grep -E '\[(rec|live|sensor|RunRecorder|MotionService|RunRepository|app)\]' app.txt \
  | grep -v heartbeat > session-lifecycle.txt

rm -f _root.json _console.json

echo "wrote: console-full.txt signal-only.txt calibration-sequence.txt session-lifecycle.txt"
wc -l console-full.txt app.txt signal-only.txt calibration-sequence.txt session-lifecycle.txt
