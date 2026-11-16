#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output="$(mktemp -d "${TMPDIR:-/tmp}/seekdesk-discussion-readiness.XXXXXX")"
trap 'rm -rf "$output"' EXIT
swiftc -parse-as-library -module-cache-path "$PWD/.build/module-cache" \
    Sources/SeekDesk/NewDiscussion.swift Tests/DiscussionOptions/ReadinessChecks.swift \
    -o "$output/SeekDeskDiscussionReadinessChecks"
"$output/SeekDeskDiscussionReadinessChecks"
