#!/bin/bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
flutter_project_dir="$(cd -- "$script_dir/.." && pwd)"
repository_dir="$(cd -- "$flutter_project_dir/.." && pwd)"

build_arguments=(release)
if (( $# != 0 )); then
  if (( $# != 2 )) || [[ "$1" != --diagnostics-output || "$2" != /* ]]; then
    printf 'Usage: %s [--diagnostics-output /absolute/new-trace.jsonl]\n' "$0" >&2
    exit 2
  fi
  if [[ -e "$2" || -L "$2" ]]; then
    printf 'Use a new trace path for each diagnostic application launch.\n' >&2
    exit 2
  fi
  build_arguments+=(
    --dart-define=SEEKDESK_PROFILE_FRAMES=true
    --dart-define=SEEKDESK_PROFILE_RAW_FRAMES=true
    "--dart-define=SEEKDESK_PROFILE_OUTPUT=$2"
  )
fi

# This prepares an installable bundle only. The established repository installer
# remains responsible for quitting/replacing the single /Applications copy.
# The diagnostic option keeps the normal entry point, account and services.
# Rebuild without the option for everyday delivery; its default is compiled out.
SEEKDESK_LOCAL_DELIVERY=1 bash "$script_dir/build-macos.sh" "${build_arguments[@]}"
application_dir="$flutter_project_dir/build/macos/Build/Products/Release/SeekDesk.app"
plist="$application_dir/Contents/Info.plist"
read_info() { /usr/bin/plutil -extract "$1" raw "$plist"; }
[[ "$(read_info CFBundleIdentifier)" == com.seekdesk.client ]]
[[ "$(read_info CFBundleExecutable)" == SeekDesk ]]
[[ "$(read_info CFBundleShortVersionString)" == "$(cat "$repository_dir/VERSION")" ]]
[[ "$(read_info CFBundleVersion)" == "$(cat "$repository_dir/BUILD_NUMBER")" ]]
[[ "$(read_info CFBundleIconFile)" == SeekDesk.icns ]]
/usr/bin/cmp "$application_dir/Contents/Resources/SeekDesk.icns" \
  "$repository_dir/Distribution/DockIcons/SeekDesk-Dock-Cobalt.icns"
/usr/bin/codesign --verify --deep --strict "$application_dir"

mkdir -p "$repository_dir/dist"
stage="$(/usr/bin/mktemp -d "$repository_dir/dist/.flutter-local.XXXXXX")"
trap '/bin/rm -rf -- "$stage"' EXIT
/usr/bin/ditto "$application_dir" "$stage/SeekDesk.app"
/usr/bin/codesign --verify --deep --strict "$stage/SeekDesk.app"
destination="$repository_dir/dist/SeekDesk.app"
if [[ -L "$destination" ]]; then
  printf 'Refusing to replace a linked distribution bundle.\n' >&2
  exit 1
fi
if [[ -e "$destination" ]]; then
  [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$destination/Contents/Info.plist")" == com.seekdesk.client ]]
  /bin/mv "$destination" "$stage/previous.app"
fi
if ! /bin/mv "$stage/SeekDesk.app" "$destination"; then
  if [[ -d "$stage/previous.app" ]]; then /bin/mv "$stage/previous.app" "$destination"; fi
  exit 1
fi
printf 'Prepared local bundle: %s\nInstall separately with the repository scripts/install-local.sh after normal application quit.\n' "$destination"
