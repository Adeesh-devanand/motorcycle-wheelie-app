#!/bin/bash
# Two-stage iOS typecheck of the app target.
#
# `xcodebuild` cannot run from this agent shell (it sandboxes a subprocess and
# nested sandboxes are not permitted), and `swift build` only covers the
# platform-free core. This compiles MotoTelemetryCore as an iOS module, then
# typechecks every MotoTelemetryApp source against it. The user's Xcode GUI build
# is unaffected by any of this.
set -e
cd "$(dirname "$0")/../.."

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
# Must match IPHONEOS_DEPLOYMENT_TARGET in project.pbxproj (17.2). Typechecking at an
# older target fails on every `@Observable` with "only available in iOS 17.0 or newer",
# which looks like a source problem and is not one.
TARGET=arm64-apple-ios17.2
PLUGIN_DIR=$(dirname "$(dirname "$(xcrun -f swiftc)")")/lib/swift/host/plugins

# PER-INVOCATION temp dirs. These were fixed paths (/tmp/mtcmod, /tmp/mtcapp) cleared at
# startup, which is a race as soon as TWO agent sessions run this script on the same
# machine: the second run's cleanup deletes the first run's freshly built module between
# its stage 1 and stage 2, and stage 2 then fails with "no such module
# 'MotoTelemetryCore'" plus "stat error: No such file or directory" — a compiler error
# that looks like broken source and is not. Observed exactly that way: stage 1 reported
# "core module built", stage 2 reported "staged 41 files", and both directories were
# empty by the time the typecheck ran.
#
# `mktemp -d` also removes the need to delete anything on the way in.
MODULE_DIR=$(mktemp -d -t mtcmod)
STAGE_DIR=$(mktemp -d -t mtcapp)
# Scoped cleanup on exit: only the extensions this script writes, then the empty dirs.
# Deliberately not a recursive delete on a variable-expanded path.
cleanup() {
    find "$MODULE_DIR" -maxdepth 1 -type f -delete 2>/dev/null
    find "$STAGE_DIR" -maxdepth 1 -type f -name '*.swift' -delete 2>/dev/null
    rmdir "$MODULE_DIR" "$STAGE_DIR" 2>/dev/null
}
trap cleanup EXIT

# Per-run log for the same reason: a shared /tmp/mtc_typecheck.log would have one
# session counting the OTHER session's errors.
LOG=$(mktemp -t mtc_typecheck)

echo "== stage 1: MotoTelemetryCore as an iOS module =="
xcrun --sdk iphoneos swiftc -emit-module -module-name MotoTelemetryCore \
    -target "$TARGET" -sdk "$SDK" \
    -emit-module-path "$MODULE_DIR/MotoTelemetryCore.swiftmodule" \
    $(find Sources/MotoTelemetryCore -name '*.swift')
echo "core module built"

echo "== stage 2: typecheck MotoTelemetryApp =="
python3 .kiro/tools/stage_app_sources.py Sources/MotoTelemetryApp "$STAGE_DIR"
set +e
# `-load-plugin-library <dylib>` rather than `-load-plugin-path <dir>`: this driver
# parses the latter's space-separated value as an input FILE ("unexpected input file"),
# and the path form also spawns a sandboxed plugin subprocess, which this agent shell
# cannot nest ("sandbox_apply: Operation not permitted"). The library form loads
# in-process, so it works where the other two fail.
xcrun --sdk iphoneos swiftc -typecheck -target "$TARGET" -sdk "$SDK" \
    -I "$MODULE_DIR" \
    -load-plugin-library "$PLUGIN_DIR/libObservationMacros.dylib" \
    -load-plugin-library "$PLUGIN_DIR/libSwiftMacros.dylib" \
    -swift-version 5 "$@" "$STAGE_DIR"/*.swift 2>&1 | tee "$LOG"
STATUS=${PIPESTATUS[0]}
echo "----"
echo "errors:   $(grep -c ': error:' "$LOG")"
echo "warnings: $(grep -c ': warning:' "$LOG")"
echo "files:    $(ls "$STAGE_DIR"/*.swift | wc -l | tr -d ' ')"
echo "exit:     $STATUS"
exit $STATUS
