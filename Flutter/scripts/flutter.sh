#!/bin/bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
flutter_project_dir="$(cd -- "$script_dir/.." && pwd)"
repository_dir="$(cd -- "$flutter_project_dir/.." && pwd)"
tools_dir="$repository_dir/.tools"
flutter_sdk="${SEEKDESK_FLUTTER_SDK:-$tools_dir/flutter}"
if [[ ! -x "$flutter_sdk/bin/flutter" ]]; then
  printf 'Flutter SDK missing at %s. Set SEEKDESK_FLUTTER_SDK to another Flutter 3.50+ SDK.\n' "$flutter_sdk" >&2
  exit 2
fi

export PUB_CACHE="$tools_dir/pub-cache"
export XDG_CONFIG_HOME="$tools_dir/config"
export XDG_CACHE_HOME="$tools_dir/cache"
export FLUTTER_SUPPRESS_ANALYTICS=true
export DART_SUPPRESS_ANALYTICS=true
export PATH="$flutter_sdk/bin:$PATH"
mkdir -p "$PUB_CACHE" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"
cd -- "$flutter_project_dir"
exec "$flutter_sdk/bin/flutter" "$@"
