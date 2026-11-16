#!/bin/bash
set -euo pipefail

repository_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
app="${1:-$repository_dir/dist/SeekDesk.app}"
output="${2:-$repository_dir/dist}"
key_file="${SEEKDESK_UPDATE_SIGNING_KEY_FILE:-$HOME/.config/seekdesk/update-signing.key}"
plist="$app/Contents/Info.plist"
read_info() { /usr/bin/plutil -extract "$1" raw "$plist"; }

[[ "$(read_info CFBundleIdentifier)" == com.seekdesk.client ]]
[[ "$(read_info SUFeedURL)" == https://github.com/cshaizhihao/SeekDesk/releases/latest/download/appcast.xml ]]
/usr/bin/codesign --verify --deep --strict "$app"
version="$(read_info CFBundleShortVersionString)"
build="$(read_info CFBundleVersion)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build" =~ ^[1-9][0-9]*$ ]]
[[ -f "$key_file" && ! -L "$key_file" && "$(/usr/bin/stat -f '%Lp' "$key_file")" == 600 ]] || {
  printf 'Expected a private update-signing key file with permissions 600.\n' >&2
  exit 1
}

mkdir -p "$output"
stage="$(/usr/bin/mktemp -d "$output/.sparkle-update.XXXXXX")"
trap '/bin/rm -rf -- "$stage"' EXIT
archive="SeekDesk-$version-macOS-update.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$stage/$archive"
/usr/bin/swift "$repository_dir/Flutter/scripts/sign-update.swift" \
  "$key_file" "$(read_info SUPublicEDKey)" "$stage/$archive" "$version" "$build" \
  "$(read_info LSMinimumSystemVersion)" "$stage/appcast.xml"
/usr/bin/xmllint --noout "$stage/appcast.xml"
/bin/mv "$stage/$archive" "$output/$archive"
/bin/mv "$stage/appcast.xml" "$output/appcast.xml"
printf 'Prepared signed archive and appcast in %s\n' "$output"
