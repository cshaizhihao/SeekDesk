#!/bin/bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
flutter_project_dir="$(cd -- "$script_dir/.." && pwd)"
mode="${1:-debug}"
case "$mode" in
  debug) configuration=Debug ;;
  profile) configuration=Profile ;;
  release) configuration=Release ;;
  *) printf 'Usage: %s [debug|profile|release] [Flutter build options]\n' "$0" >&2; exit 2 ;;
esac

expected_bundle_id=com.seekdesk.flutter-preview
product_name='SeekDesk Flutter'
build_arguments=(--no-pub "${@:2}")
if [[ "${SEEKDESK_PROFILE_FIXTURE:-0}" == 1 ]]; then
  if [[ "$mode" != profile || "${SEEKDESK_LOCAL_DELIVERY:-0}" == 1 ]]; then
    printf 'The isolated reader fixture is restricted to Profile, without local delivery.\n' >&2
    exit 2
  fi
  for argument in "${build_arguments[@]}"; do
    case "$argument" in
      --target*|-t|-t?*|*SEEKDESK_PROFILE_FIXTURE*|--dart-define-from-file*|--release|--debug|--profile)
        printf 'The isolated fixture fixes its entry point and isolation define; do not override them.\n' >&2
        exit 2 ;;
    esac
  done
  export XCODE_XCCONFIG_FILE="$flutter_project_dir/macos/Runner/Configs/ProfileFixture.xcconfig"
  expected_bundle_id=com.seekdesk.flutter-benchmark
  product_name='SeekDesk Benchmark'
  build_arguments+=(--target=tool/profile_reader.dart --dart-define=SEEKDESK_PROFILE_FIXTURE=true)
else
  for argument in "${build_arguments[@]}"; do
    case "$argument" in
      *profile_reader.dart*|*SEEKDESK_PROFILE_FIXTURE*)
        printf 'Use SEEKDESK_PROFILE_FIXTURE=1 for the isolated reader benchmark.\n' >&2
        exit 2 ;;
    esac
  done
fi
if [[ "${SEEKDESK_LOCAL_DELIVERY:-0}" == 1 ]]; then
  if [[ "$mode" != release ]]; then
    printf 'The preserved local installation identity is restricted to Release builds.\n' >&2
    exit 2
  fi
  export XCODE_XCCONFIG_FILE="$flutter_project_dir/macos/Runner/Configs/LocalDelivery.xcconfig"
  expected_bundle_id=com.seekdesk.client
  product_name=SeekDesk
fi

flutter_command=(bash "$script_dir/flutter.sh")
if ! xcodebuild -version >/dev/null 2>&1; then
  printf 'The standard Flutter macOS runner requires a selected full Xcode installation.\n' >&2
  exit 2
fi

bash "$script_dir/prepare-native.sh"
cd -- "$flutter_project_dir"
if [[ "${SEEKDESK_PUB_OFFLINE:-0}" == 1 ]]; then
  "${flutter_command[@]}" pub get --offline
else
  "${flutter_command[@]}" pub get
fi
"${flutter_command[@]}" build macos "--$mode" "${build_arguments[@]}"
application_dir="$flutter_project_dir/build/macos/Build/Products/$configuration/$product_name.app"
if [[ ! -d "$application_dir" ]]; then
  printf 'Expected built application is missing: %s\n' "$application_dir" >&2
  exit 1
fi
/usr/bin/plutil -lint "$application_dir/Contents/Info.plist"
bundle_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$application_dir/Contents/Info.plist")"
if [[ "$bundle_id" != "$expected_bundle_id" ]]; then
  printf 'Expected application identifier %s, got %s\n' "$expected_bundle_id" "$bundle_id" >&2
  exit 1
fi
python3 "$script_dir/verify-local-signature.py" "$application_dir" "$expected_bundle_id"
