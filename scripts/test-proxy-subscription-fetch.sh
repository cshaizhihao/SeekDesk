#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output="$(mktemp -d "${TMPDIR:-/tmp}/seekdesk-subscription-fetch-tests.XXXXXX")"
trap 'rm -rf "$output"' EXIT
source scripts/test-yaml.sh
swiftc -parse-as-library -module-cache-path "$PWD/.build/module-cache" "${yaml_args[@]}" \
    Sources/SeekDesk/{DeskProxyNode,DeskClashNode,DeskProxySubscription,DeskProxyNetwork}.swift \
    Tests/Regression/ProxySubscriptionFetchChecks.swift -o "$output/SeekDeskSubscriptionFetchChecks"
python3 Tests/Regression/subscription_fixture.py "$output/SeekDeskSubscriptionFetchChecks"
