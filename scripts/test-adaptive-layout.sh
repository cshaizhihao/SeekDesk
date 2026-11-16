#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

output="$(mktemp -d "${TMPDIR:-/tmp}/seekdesk-adaptive-layout.XXXXXX")"
trap 'rm -rf "$output"' EXIT
mkdir -p .build/module-cache
swiftc -parse-as-library -module-cache-path "$PWD/.build/module-cache" \
    Sources/SeekDesk/DeskAdaptiveLayout.swift Tests/Layout/AdaptiveLayoutChecks.swift \
    -o "$output/AdaptiveLayoutChecks"
"$output/AdaptiveLayoutChecks"
