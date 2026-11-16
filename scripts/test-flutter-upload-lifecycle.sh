#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output="$(mktemp -d "${TMPDIR:-/tmp}/seekdesk-upload-lifecycle.XXXXXX")"
trap 'rm -rf "$output"' EXIT
source scripts/test-yaml.sh
case "${1:-upload}" in
    upload) checks=UploadLifecycleChecks ;;
    forum) checks=ForumServiceChecks ;;
    *) echo "Usage: $0 [upload|forum]" >&2; exit 2 ;;
esac
flutter_framework="$PWD/.tools/flutter/bin/cache/artifacts/engine/darwin-x64-profile/FlutterMacOS.xcframework/macos-arm64_x86_64"
swiftc -D SEEKDESK_FLUTTER -parse-as-library -module-cache-path "$PWD/.build/module-cache" "${yaml_args[@]}" \
    -F "$PWD/Flutter/macos/Frameworks" -framework Sparkle \
    -F "$flutter_framework" -framework FlutterMacOS \
    -Xlinker -rpath -Xlinker "$PWD/Flutter/macos/Frameworks" \
    -Xlinker -rpath -Xlinker "$flutter_framework" \
    Sources/SeekDesk/*.swift Flutter/macos/Runner/NativeBridge/*.swift "Tests/FlutterBridge/$checks.swift" \
    -o "$output/SeekDeskUploadLifecycleChecks"
"$output/SeekDeskUploadLifecycleChecks"
