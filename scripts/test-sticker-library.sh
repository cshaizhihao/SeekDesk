#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output="$(mktemp -d "${TMPDIR:-/tmp}/seekdesk-sticker-library.XXXXXX")"
trap 'rm -rf "$output"' EXIT
swiftc -swift-version 5 -parse-as-library -module-cache-path "$PWD/.build/module-cache" \
    Sources/SeekDesk/ImageRequestCoordinator.swift Sources/SeekDesk/ForumStickers.swift \
    Sources/SeekDesk/ForumImageAnimation.swift Sources/SeekDesk/StickerLibrary.swift Tests/StickerLibrary/LibraryChecks.swift \
    -o "$output/SeekDeskStickerLibraryChecks"
"$output/SeekDeskStickerLibraryChecks"
