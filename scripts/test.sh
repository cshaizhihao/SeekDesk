#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

output="$(mktemp -d "${TMPDIR:-/tmp}/seekdesk-tests.XXXXXX")"
trap 'rm -rf "$output"' EXIT

mkdir -p .build/module-cache
source scripts/test-yaml.sh
sources=()
for source in Sources/SeekDesk/*.swift; do
    case "${source##*/}" in
        SeekDeskApp.swift|WorkspaceView.swift|PreferencesPane.swift|WorkspaceSearchField.swift) ;;
        *) sources+=("$source") ;;
    esac
done
swiftc -module-cache-path "$PWD/.build/module-cache" \
    "${yaml_args[@]}" \
    "${sources[@]}" \
    Tests/Session/{main,WorkspaceChecks,ForumReplyChecks,AccountAndEditorChecks,RemainingValueChecks,DiscussionChecks,ReportSizingChecks,ProxyChecks}.swift \
    -o "$output/SeekDeskTests"
"$output/SeekDeskTests"
