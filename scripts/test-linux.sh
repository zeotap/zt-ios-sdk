#!/usr/bin/env bash
# Runs the ZeotapSDK unit + conformance suites on the Linux test host, one test CLASS per process.
#
# Why not plain `swift test`: swift-corelibs-xctest (observed on Swift 6.0.3 and 6.1.3) intermittently
# loses a wake-up in XCTWaiter.wait and a run stalls forever with every dispatch worker idle. It is not
# tied to any test — the same class passes on the next attempt — so each class gets its own process
# with a timeout and is retried on exit 124. Test content is unaffected; failures are reported as usual.
#
# Usage (inside the container; see ci/Dockerfile.linux):
#   scripts/test-linux.sh [--scratch-path DIR] [--timeout SECONDS] [--retries N] [--filter REGEX]
set -uo pipefail
cd "$(dirname "$0")/.."

# A stall shows no output at all within seconds (the test Task never starts), so a short timeout
# and many retries beat a long timeout: a real slow class still gets timeout_s per attempt.
scratch=".build-linux"; timeout_s=45; retries=20; filter=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scratch-path) scratch="$2"; shift 2 ;;
    --timeout) timeout_s="$2"; shift 2 ;;
    --retries) retries="$2"; shift 2 ;;
    --filter) filter="$2"; shift 2 ;;
    *) echo "unknown arg $1" >&2; exit 2 ;;
  esac
done

echo "[test-linux] building tests (scratch: $scratch)"
if ! swift build --build-tests --scratch-path "$scratch" 2>&1 | grep -E "error:|Build complete|warning: unre"; then
  swift build --build-tests --scratch-path "$scratch" 2>&1 | tail -20
fi
bin="$(find "$scratch" -name 'ZeotapSDKPackageTests.xctest' -type f | head -1)"
[[ -n "$bin" ]] || { echo "[test-linux] test bundle not found under $scratch" >&2; exit 1; }

# Discover Module.Class pairs (list-tests prints Module.Class/testName).
mapfile -t classes < <(swift test --list-tests --scratch-path "$scratch" 2>/dev/null | sed -E 's#/.*$##' | sort -u)
[[ ${#classes[@]} -gt 0 ]] || { echo "[test-linux] no test classes discovered" >&2; exit 1; }
if [[ -n "$filter" ]]; then mapfile -t classes < <(printf '%s\n' "${classes[@]}" | grep -E "$filter"); fi

total=0; failures=0; stalled=0; broken=()
logdir="$(mktemp -d)"
for cls in "${classes[@]}"; do
  rc=0; attempt=0
  while (( attempt < retries )); do
    attempt=$((attempt + 1))
    # `--kill-after` is not belt-and-braces: a stalled swift-corelibs-xctest process
    # does NOT die on the SIGTERM plain `timeout` sends — it sits in the lost wake-up
    # with every dispatch worker idle and no signal handler running. Without this,
    # `timeout` itself blocks and the per-attempt budget becomes unbounded: observed
    # at 5+ minutes for a "45 second" attempt, which turns a 20-retry class into a
    # hang. On a GitHub runner that is the six-hour job limit, reported as a timeout
    # with no failing test named.
    SWIFT_BACKTRACE=enable=no timeout --kill-after=5 "$timeout_s" stdbuf -oL -eL "$bin" "$cls" > "$logdir/$cls.log" 2>&1
    rc=$?
    # 124 = terminated at the deadline; 137 = SIGKILL from --kill-after, i.e. the
    # same stall, one escalation later. Treating 137 as a real failure would report
    # a green class as broken.
    [[ $rc -eq 124 || $rc -eq 137 ]] || break
    stalled=$((stalled + 1))
  done
  summary="$(grep -E 'Executed [0-9]+ tests?' "$logdir/$cls.log" | tail -1 | sed 's/^[[:space:]]*//')"
  n="$(sed -nE 's/.*Executed ([0-9]+) tests?.*/\1/p' <<<"$summary" | head -1)"
  f="$(sed -nE 's/.*with ([0-9]+) failures?.*/\1/p' <<<"$summary" | head -1)"
  total=$((total + ${n:-0})); failures=$((failures + ${f:-0}))
  status="ok"
  if [[ $rc -eq 124 || $rc -eq 137 ]]; then status="STALLED x$retries"; broken+=("$cls"); fi
  if [[ $rc -ne 0 && $rc -ne 124 && $rc -ne 137 ]]; then status="rc=$rc"; broken+=("$cls"); fi
  printf '%-60s %-14s %s%s\n' "$cls" "$status" "${summary:-<no summary>}" "$([[ $attempt -gt 1 ]] && echo " (attempt $attempt)")"
  grep -E "error:|failed \(" "$logdir/$cls.log" | head -20
done

echo
echo "[test-linux] classes=${#classes[@]} tests=$total failures=$failures stalled-runs-retried=$stalled"
if (( failures > 0 || ${#broken[@]} > 0 )); then
  echo "[test-linux] FAILED: ${broken[*]}" >&2
  exit 1
fi
echo "[test-linux] OK"
