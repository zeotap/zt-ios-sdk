#!/usr/bin/env bash
# Asserts VERSION, the generated Version.swift and the podspec agree, and — when
# run on a release tag (sdk-ios-vX.Y.Z) — that the tag matches. Used by CI.
set -euo pipefail
cd "$(dirname "$0")/.."
version="$(tr -d '[:space:]' < VERSION)"
generated="$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' Sources/ZeotapSDK/Generated/Version.swift)"
[[ "$generated" == "$version" ]] || { echo "Version.swift ($generated) != VERSION ($version); run scripts/stamp-version.sh" >&2; exit 1; }
podspec="$(sed -n "s/.*s.version *= *['\"]\(.*\)['\"].*/\1/p" ZeotapSDK.podspec | head -1)"
if [[ -n "$podspec" && "$podspec" != "$version" ]]; then
  echo "ZeotapSDK.podspec version ($podspec) != VERSION ($version)" >&2; exit 1
fi
if [[ -n "${GITHUB_REF_NAME:-}" && "${GITHUB_REF_NAME}" == sdk-ios-v* ]]; then
  tag="${GITHUB_REF_NAME#sdk-ios-v}"
  [[ "$tag" == "$version" ]] || { echo "tag $GITHUB_REF_NAME != VERSION $version" >&2; exit 1; }
fi
echo "[check-version] $version OK"
