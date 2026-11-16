#!/bin/bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
flutter_project_dir="$(cd -- "$script_dir/.." && pwd)"
repository_dir="$(cd -- "$flutter_project_dir/.." && pwd)"
destination="$flutter_project_dir/macos/Frameworks/Sparkle.framework"
sparkle_xcframework="${SEEKDESK_SPARKLE_XCFRAMEWORK:-$repository_dir/.build/local/Sparkle.xcframework}"

if [[ -d "$destination" ]] && \
   [[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$destination/Resources/Info.plist")" == 2.10.1 ]]; then
  exit 0
fi

if [[ ! -d "$sparkle_xcframework" ]]; then
  cache_dir="$flutter_project_dir/build/native-dependencies"
  mkdir -p "$cache_dir"
  archive="$cache_dir/Sparkle-2.10.1.zip"
  /usr/bin/curl --fail --location --retry 2 \
    'https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-for-Swift-Package-Manager.zip' \
    --output "$archive"
  archive_sha="$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')"
  if [[ "$archive_sha" != 4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a ]]; then
    printf 'Sparkle release archive checksum mismatch.\n' >&2
    exit 1
  fi
  /usr/bin/ditto -x -k "$archive" "$cache_dir/Sparkle-2.10.1"
  sparkle_xcframework="$cache_dir/Sparkle-2.10.1/Sparkle.xcframework"
fi

source_framework="$sparkle_xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -d "$source_framework" ]] || \
   [[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$source_framework/Resources/Info.plist")" != 2.10.1 ]]; then
  printf 'Expected the official Sparkle 2.10.1 macOS framework at %s\n' "$source_framework" >&2
  exit 1
fi
mkdir -p "$(dirname -- "$destination")"
/usr/bin/rsync -a --delete "$source_framework/" "$destination/"
printf 'Prepared Sparkle 2.10.1 for the Flutter runner.\n'
