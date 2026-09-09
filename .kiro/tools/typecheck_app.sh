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
MODULE_DIR=/tmp/mtcmod
STAGE_DIR=/tmp/mtcapp

# Both directories are recreated and their generated contents cleared file-by-file
# rather than with a recursive delete. `rm -rf` on a variable-expanded path is exactly
# the shape a safety policy should refuse, and it buys nothing here: these two
# directories hold only files this script itself writes, so deleting the extensions it
# produces is sufficient and cannot reach anything else.
mkdir -p "$MODULE_DIR" "$STAGE_DIR"
find "$MODULE_DIR" -maxdepth 1 -type f \
    \( -name '*.swiftmodule' -o -name '*.swiftdoc' -o -name '*.swiftsourceinfo' \
       -o -name '*.abi.json' \) -delete
find "$STAGE_DIR" -maxdepth 1 -type f -name '*.swift' -delete
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
    -swift-version 5 "$STAGE_DIR"/*.swift 2>&1 | tee /tmp/mtc_typecheck.log
STATUS=${PIPESTATUS[0]}
echo "----"
echo "errors:   $(grep -c ': error:' /tmp/mtc_typecheck.log)"
echo "warnings: $(grep -c ': warning:' /tmp/mtc_typecheck.log)"
echo "files:    $(ls "$STAGE_DIR"/*.swift | wc -l | tr -d ' ')"
echo "exit:     $STATUS"
exit $STATUS
