#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output="$(mktemp -d "${TMPDIR:-/tmp}/seekdesk-markdown-editor.XXXXXX")"
trap 'rm -rf "$output"' EXIT
mkdir -p .build/module-cache
swiftc -parse-as-library -swift-version 5 -module-cache-path "$PWD/.build/module-cache" \
    Sources/SeekDesk/MarkdownEdit.swift Sources/SeekDesk/MarkdownTextInput.swift \
    Tests/MarkdownEditor/EditingChecks.swift -o "$output/MarkdownEditingChecks"
"$output/MarkdownEditingChecks"
