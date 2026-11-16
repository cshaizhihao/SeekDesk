#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output="$(mktemp -d "${TMPDIR:-/tmp}/seekdesk-reader-wheel.XXXXXX")"
trap 'rm -rf "$output"' EXIT
flutter_framework="$PWD/.tools/flutter/bin/cache/artifacts/engine/darwin-x64-profile/FlutterMacOS.xcframework/macos-arm64_x86_64"
swiftc -parse-as-library -module-cache-path "$output/module-cache" \
    -F "$flutter_framework" -framework FlutterMacOS \
    -Xlinker -rpath -Xlinker "$flutter_framework" \
    Flutter/macos/Runner/ReaderWheelInput.swift scripts/ReaderWheelInputChecks.swift \
    -o "$output/SeekDeskReaderWheelChecks"
"$output/SeekDeskReaderWheelChecks"
