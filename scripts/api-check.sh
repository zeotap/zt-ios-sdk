#!/usr/bin/env bash
# Fail if ZeotapSDK's public API differs from the committed baseline.
#
# The iOS counterpart of Android's `:sdk:apiCheck` (binary-compatibility-validator
# against `sdk/android/sdk/api/sdk.api`). Until increment 253 iOS had no such gate
# at all: a public method could be removed, renamed, or have a parameter label
# changed, and every check in the repository stayed green — for an SDK, where the
# public surface IS the product and a customer's build is what breaks.
#
# WHAT THIS COVERS
#   The entire public surface of the `ZeotapSDK` module. Verified rather than
#   assumed: no `public` declaration in `Sources/ZeotapSDK` sits behind a
#   `#if canImport(UIKit)` / `canImport(ObjectiveC)` guard, so the Linux build
#   sees all of it. The dump is taken on Linux precisely so this runs in the cheap
#   container job beside the unit tests, on any machine, with no Xcode.
#
# WHAT THIS DOES NOT COVER, and it is a real gap
#   `ZeotapSDKObjC` and `ZeotapSDKAdSupport` are wholly inside `canImport`
#   guards — on Linux they compile to empty modules, so their public API
#   (`ZTAnalytics`, `ZTConfiguration`, `ATTAdvertisingIdProvider`) is invisible
#   here and unguarded. Those two are what the React Native bridge and any
#   Objective-C host actually import. Closing it needs a macOS runner producing a
#   second baseline per module; the compile of both IS covered by the macOS job,
#   so what is missing is the freeze, not the build.
#
# On drift the diff is printed and the fix is one command — that is the point: an
# API change should be a reviewed line in a diff, not a surprise in a release.
set -euo pipefail
cd "$(dirname "$0")/.."

baseline="api/ZeotapSDK.api.txt"
[[ -f "$baseline" ]] || {
  echo "[api-check] no baseline at $baseline — run scripts/api-snapshot.sh" >&2
  exit 1
}

current="$(mktemp)"
trap 'rm -f "$current"' EXIT
"$(dirname "$0")/api-dump.sh" "${SCRATCH:-.build-linux}" > "$current"

if diff -u "$baseline" "$current" > /dev/null; then
  echo "[api-check] public API matches the baseline ($(wc -l < "$baseline" | tr -d ' ') declarations)"
  exit 0
fi

echo "[api-check] ZeotapSDK's public API has CHANGED:" >&2
echo >&2
diff -u --label "committed  $baseline" --label "built      (this tree)" "$baseline" "$current" >&2 || true
cat >&2 <<'EOF'

A line REMOVED is a breaking change for every customer already on the released
version — the SDK is a library, and its callers are other people's apps.
A line ADDED is additive and fine.

If the change is intended:  make sdk-ios-api     (then commit api/ZeotapSDK.api.txt)
EOF
exit 1
