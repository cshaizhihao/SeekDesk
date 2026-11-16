#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output="$(mktemp -d "${TMPDIR:-/tmp}/seekdesk-subscription-tests.XXXXXX")"
trap 'rm -rf "$output"' EXIT
source scripts/test-yaml.sh
swiftc -parse-as-library -module-cache-path "$PWD/.build/module-cache" "${yaml_args[@]}" \
    Sources/SeekDesk/{DeskProxyNode,DeskClashNode,DeskProxySubscription,DeskProxyNetwork,DeskProxyNodeProbe,DeskProxyVault,DeskProxyController}.swift \
    Tests/Regression/ProxySubscriptionChecks.swift -o "$output/SeekDeskProxySubscriptionChecks"
"$output/SeekDeskProxySubscriptionChecks"
