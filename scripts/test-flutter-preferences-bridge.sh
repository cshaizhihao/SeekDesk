#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output="$(mktemp -d "${TMPDIR:-/tmp}/seekdesk-preferences-bridge.XXXXXX")"
trap 'rm -rf "$output"' EXIT
source scripts/test-yaml.sh
sources=()
for source in Sources/SeekDesk/*.swift; do
    case "${source##*/}" in
        SeekDeskApp.swift|WorkspaceView.swift|PreferencesPane.swift|WorkspaceSearchField.swift) ;;
        *) sources+=("$source") ;;
    esac
done
swiftc -parse-as-library -module-cache-path "$PWD/.build/module-cache" "${yaml_args[@]}" \
    "${sources[@]}" Flutter/macos/Runner/NativeBridge/NativePreferencesServices.swift \
    Tests/FlutterBridge/PreferencesContextFixture.swift Tests/FlutterBridge/PreferencesServiceChecks.swift \
    -o "$output/SeekDeskPreferencesBridgeChecks"
"$output/SeekDeskPreferencesBridgeChecks"
