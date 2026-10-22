#!/usr/bin/env bash
# Regenerate the committed public-API baseline for ZeotapSDK.
#
#   docker run … zeotap-ios-sdk-test:local scripts/api-snapshot.sh
#   make sdk-ios-api            # the same, wrapped
#
# Run this deliberately, as part of a change that adds or removes public API, and
# review the diff — that review IS the check. `scripts/api-check.sh` runs the same
# generation and fails when the result differs from what is committed.
#
# See api-check.sh for what this covers and, more importantly, what it does not.
set -euo pipefail
cd "$(dirname "$0")/.."

scratch="${SCRATCH:-.build-linux}"
out="api/ZeotapSDK.api.txt"

mkdir -p api
"$(dirname "$0")/api-dump.sh" "$scratch" > "$out"
echo "[api-snapshot] wrote $out ($(wc -l < "$out" | tr -d ' ') declarations)"
