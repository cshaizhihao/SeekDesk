#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output="$(mktemp -d "${TMPDIR:-/tmp}/seekdesk-edit-menu.XXXXXX")"
trap 'rm -rf "$output"' EXIT
swiftc -parse-as-library -module-cache-path "$PWD/.build/module-cache" \
    Flutter/macos/Runner/NativeBridge/NativeEditMenuBridge.swift \
    Tests/FlutterBridge/EditMenuBridgeChecks.swift \
    -o "$output/SeekDeskEditMenuChecks"
"$output/SeekDeskEditMenuChecks"
