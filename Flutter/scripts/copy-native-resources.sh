#!/bin/bash
set -euo pipefail

repository_dir="$(cd -- "$PROJECT_DIR/../.." && pwd)"
resources_dir="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
helpers_dir="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
mkdir -p "$resources_dir" "$helpers_dir"
/bin/cp "$repository_dir/Distribution/DockIcons/SeekDesk-Dock-Cobalt.icns" "$resources_dir/SeekDesk.icns"

for folder in Icons DockIcons Partners; do
  /usr/bin/rsync -a --delete \
    "$repository_dir/Distribution/$folder/" "$resources_dir/$folder/"
done
for image in "$repository_dir"/Distribution/Wordmark*.png "$repository_dir"/Distribution/Logos/*.png; do
  [[ -f "$image" ]] && /bin/cp "$image" "$resources_dir/"
done
/bin/cp "$repository_dir/LICENSE" "$resources_dir/SeekDesk-LICENSE.txt"
/bin/cp "$repository_dir/Distribution/Sparkle-LICENSE.txt" "$resources_dir/"
/bin/cp "$repository_dir/Vendor/Yams/LICENSE" "$resources_dir/Yams-LICENSE.txt"
/bin/cp "$repository_dir/Vendor/Yams/libyaml-LICENSE.txt" "$resources_dir/"
/bin/cp "$repository_dir/Distribution/ProxyCore/Xray-LICENSE.txt" "$resources_dir/"
/bin/cp "$repository_dir/Flutter/THIRD_PARTY_NOTICES" "$resources_dir/Flutter-THIRD_PARTY_NOTICES.txt"

proxy_source="$repository_dir/Distribution/ProxyCore/xray"
proxy_sha="$(/usr/bin/shasum -a 256 "$proxy_source" | /usr/bin/awk '{print $1}')"
if [[ "$proxy_sha" != 1b2d5ebe3a4c332203db24b81a052c6d6688a7f80705090f031b7416013ee1b2 ]]; then
  printf 'Bundled Xray does not match the pinned release.\n' >&2
  exit 1
fi
/bin/cp "$proxy_source" "$helpers_dir/xray"
/bin/chmod 755 "$helpers_dir/xray"
if [[ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]]; then
  /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$helpers_dir/xray"
fi
