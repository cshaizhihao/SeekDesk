#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output="$(mktemp -d "${TMPDIR:-/tmp}/seekdesk-node-probe-tests.XXXXXX")"
trap 'rm -rf "$output"' EXIT
mkdir -p .build/module-cache
swiftc -parse-as-library -module-cache-path "$PWD/.build/module-cache" \
    Sources/SeekDesk/{DeskProxyNode,DeskProxyNetwork,DeskProxyNodeProbe}.swift \
    Tests/Regression/ProxyNodeProbeChecks.swift -o "$output/SeekDeskNodeProbeChecks"
python3 Tests/Regression/node_probe_fixture.py "$output/SeekDeskNodeProbeChecks" "$PWD/Distribution/ProxyCore/xray"
