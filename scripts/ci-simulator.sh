#!/usr/bin/env bash
# Prints the UDID of an iOS simulator the SELECTED Xcode can run, preferring
# the named model (default "iPhone 16"). Diagnostics go to stderr.
#
#   SIM_ID="$(scripts/ci-simulator.sh ["iPhone 16"])"
#   xcodebuild test ... -destination "id=$SIM_ID"
#
# Why not `-destination 'platform=iOS Simulator,name=iPhone 16'`: that names a
# model, not a runtime, and an Xcode can only run runtimes up to its own SDK.
# GitHub's macos-15 machines do not all carry the same runtimes, and on one
# that lacked iOS 18.2 every simulator was ineligible for the pinned Xcode 16.2
# — `xcodebuild: error: Unable to find a destination … iOS 18.2 is not
# installed` — when the macos-15 image dropped every iOS runtime below 18.5. So:
# pick a device whose runtime the SDK can run; failing that, download the
# platform the selected Xcode asks for and create a device on what it added.
set -euo pipefail

want="${1:-iPhone 16}"
sdk="$(xcrun --sdk iphonesimulator --show-sdk-version)"
echo "[sim] $(xcodebuild -version | head -1), iphonesimulator SDK $sdk, want \"$want\"" >&2

pick() {
  xcrun simctl list devices available --json | python3 -c '
import json, sys
want, sdk = sys.argv[1], tuple(int(p) for p in sys.argv[2].split("."))
def ver(runtime):
    # com.apple.CoreSimulator.SimRuntime.iOS-18-2 -> (18, 2)
    tail = runtime.rsplit(".", 1)[-1]
    if not tail.startswith("iOS-"): return None
    return tuple(int(p) for p in tail[4:].split("-"))
best = None
for runtime, devices in json.load(sys.stdin)["devices"].items():
    v = ver(runtime)
    if v is None or v > sdk: continue           # not iOS, or newer than this Xcode can run
    for d in devices:
        if not d["name"].startswith("iPhone"): continue
        key = (d["name"] == want, v)            # the wanted model first, then the newest runtime
        if best is None or key > best[0]: best = (key, d["udid"], d["name"], v)
if best:
    version = ".".join(map(str, best[3]))
    print(best[1]); print("[sim] picked %s on iOS %s (%s)" % (best[2], version, best[1]), file=sys.stderr)
' "$want" "$sdk"
}

ios_runtimes() {
  xcrun simctl list runtimes available --json \
    | python3 -c 'import json,sys; print("\n".join(r["identifier"] for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "iOS"))'
}

id="$(pick)"
if [ -z "$id" ]; then
  echo "[sim] no iPhone simulator this Xcode can run; runtimes present:" >&2
  xcrun simctl list runtimes >&2
  before="$(ios_runtimes)"
  echo "[sim] downloading the iOS platform for the selected Xcode (several GB)" >&2
  xcodebuild -downloadPlatform iOS >&2
  # Use what the download ADDED rather than guessing its version: for Xcode 16.2
  # (SDK 18.2) Apple serves the iOS 18.3.1 runtime, which no "<= SDK" rule admits.
  runtime="$(comm -13 <(echo "$before" | sort) <(ios_runtimes | sort) | tail -1)"
  [ -n "$runtime" ] || { echo "[sim] FAIL: downloading the iOS platform added no runtime" >&2; exit 1; }
  echo "[sim] creating \"$want\" on $runtime" >&2
  id="$(xcrun simctl create "$want" "$want" "$runtime")"
fi
echo "$id"
