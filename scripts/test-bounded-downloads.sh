#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output="$(mktemp -d "${TMPDIR:-/tmp}/seekdesk-bounded-downloads.XXXXXX")"
trap 'rm -rf "$output"' EXIT
mkdir -p .build/module-cache
swiftc -parse-as-library -module-cache-path "$PWD/.build/module-cache" \
    Sources/SeekDesk/DeskProxyNetwork.swift Tests/Regression/BoundedDownloadChecks.swift \
    -o "$output/SeekDeskBoundedDownloadChecks"
python3 Tests/Regression/bounded_download_fixture.py "$output/SeekDeskBoundedDownloadChecks"
