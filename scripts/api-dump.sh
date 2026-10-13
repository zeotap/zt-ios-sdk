#!/usr/bin/env bash
# Print ZeotapSDK's public API, one declaration per line. Shared by api-snapshot.sh
# (which commits it) and api-check.sh (which diffs it). Not called directly.
#
# Usage: api-dump.sh [scratch-path]
set -euo pipefail
cd "$(dirname "$0")/.."

scratch="${1:-.build-linux}"

# Reuses the test suite's scratch path by default, so running this after
# `test-linux.sh` costs one no-op build rather than a second full compile.
swift build --scratch-path "$scratch" >/dev/null

bin="$(swift build --scratch-path "$scratch" --show-bin-path)"

# `-I Sources/CSQLite` is load-bearing and not obvious: the digester takes no
# `-Xcc`, so the only way to hand it the CSQLite Clang module map is an include
# path containing a `module.modulemap`. Without it the module fails to load and,
# without `-abort-on-module-fail`, the tool would cheerfully emit an EMPTY dump —
# which a diff against a stale baseline reads as "you deleted the entire API".
#
# `-avoid-location` / `-avoid-tool-args` keep absolute paths and compiler
# invocations out of the JSON, so the output does not depend on where the
# checkout lives or how the build was invoked.
dump="$(mktemp)"
trap 'rm -f "$dump"' EXIT
swift-api-digester -dump-sdk -module ZeotapSDK \
  -I "$bin" -I "$bin/Modules" -I Sources/CSQLite \
  -o "$dump" -abort-on-module-fail -avoid-location -avoid-tool-args

python3 "$(dirname "$0")/api-flatten.py" "$dump" ZeotapSDK
