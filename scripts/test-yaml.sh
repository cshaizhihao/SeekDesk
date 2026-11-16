#!/bin/bash
# Sourced by offline test runners; keep compiler dependencies inside the workspace.
yaml_build="$PWD/.build/test-yaml"
mkdir -p "$yaml_build" .build/module-cache
yaml_fingerprint="$(find Vendor/Yams/Sources -type f -exec shasum -a 256 {} \; | shasum -a 256)"
if [[ ! -f "$yaml_build/fingerprint" || "$(cat "$yaml_build/fingerprint")" != "$yaml_fingerprint" ]]; then
    for source in Vendor/Yams/Sources/CYaml/src/*.c; do
        clang -O2 -DYAML_DECLARE_STATIC -I Vendor/Yams/Sources/CYaml/include -c "$source" -o "$yaml_build/$(basename "$source" .c).o"
    done
    swiftc -O -D SWIFT_PACKAGE -parse-as-library -module-cache-path "$PWD/.build/module-cache" \
        -I Vendor/Yams/Sources/CYaml/include -module-name Yams -emit-module \
        -emit-module-path "$yaml_build/Yams.swiftmodule" -emit-library -static \
        Vendor/Yams/Sources/Yams/*.swift "$yaml_build"/*.o -o "$yaml_build/libYams.a"
    printf '%s' "$yaml_fingerprint" > "$yaml_build/fingerprint"
fi
yaml_args=(-I "$yaml_build" -I "$PWD/Vendor/Yams/Sources/CYaml/include" -L "$yaml_build" -lYams)
