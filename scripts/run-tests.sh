#!/bin/bash
# Run the BodegasNYC test suite against a pinned, reused simulator.
#
# This is the only supported way to run tests in this repo (see CLAUDE.md).
# It exists to fix recurring problems observed running `xcodebuild test`
# ad hoc: an ambiguous destination spinning up "Clone N of <device>"
# simulators, and -- specifically for the UI test target -- xcodebuild
# reliably cloning the destination and then hanging indefinitely trying to
# launch the test runner onto the fresh clone (no internal xcodebuild
# timeout covers that phase). Unit tests alone do not clone and run in
# seconds, so they're the default; UI tests are opt-in.
#
# Usage: scripts/run-tests.sh [--ui] [timeout_seconds]
#   --ui                  also run BodegasNYCUITests (slower, may spin up
#                          a clone simulator -- cleaned up automatically,
#                          but subject to the same timeout, which it will
#                          likely hit: the one observed UI-test run never
#                          completed organically even given 900s)
#   TEST_TIMEOUT_SECONDS env var overrides the default (180s / 3min) too.
#
# DerivedData goes to build/dd inside this checkout (gitignored) rather than
# ~/Library/Developer/Xcode/DerivedData. Xcode keys the default location by
# project path, so every builder worktree used to leave a ~550 MB folder
# there that outlived the worktree; in-tree it dies with the worktree, and
# scripts/cleanup-worktrees.sh sweeps any older strays.
set -uo pipefail

cd "$(dirname "$0")/.."

DEVICE_NAME="iPhone 17 Pro"

PROJECT="BodegasNYC.xcodeproj"
SCHEME="BodegasNYC"
DERIVED_DATA="build/dd"

INCLUDE_UI_TESTS=0
TIMEOUT_ARG=""
for arg in "$@"; do
  case "$arg" in
    --ui|--include-ui-tests) INCLUDE_UI_TESTS=1 ;;
    *) TIMEOUT_ARG="$arg" ;;
  esac
done
TIMEOUT_SECONDS="${TEST_TIMEOUT_SECONDS:-${TIMEOUT_ARG:-180}}"

TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
else
  echo "error: neither 'timeout' nor 'gtimeout' found on PATH (brew install coreutils)" >&2
  exit 1
fi

# Serialize concurrent invocations (e.g. from other worktrees of this same
# project) so two test runs never contend for the pinned device at once --
# that contention is what makes xcodebuild fall back to cloning a device.
LOCK_DIR="/tmp/bodega-run-tests.lock"
cleanup_lock() { rmdir "$LOCK_DIR" 2>/dev/null || true; }
trap cleanup_lock EXIT

WAITED=0
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
  if [ "$WAITED" -eq 0 ]; then
    echo "another run-tests.sh is in progress, waiting for lock..." >&2
  fi
  sleep 2
  WAITED=$((WAITED + 2))
  if [ "$WAITED" -ge "$TIMEOUT_SECONDS" ]; then
    echo "error: timed out after ${TIMEOUT_SECONDS}s waiting for lock ${LOCK_DIR}" >&2
    exit 1
  fi
done

sweep_clones() {
  xcrun simctl list devices \
    | grep -E "Clone [0-9]+ of " \
    | grep -oE "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}" \
    | while read -r udid; do
        xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
        xcrun simctl delete "$udid" >/dev/null 2>&1 || true
      done
}

sweep_clones

DEVICE_UDID=$(xcrun simctl list devices \
  | grep -F "${DEVICE_NAME} (" \
  | grep -oE "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}" \
  | head -1)

if [ -z "$DEVICE_UDID" ]; then
  echo "error: could not find simulator '${DEVICE_NAME}' via simctl" >&2
  exit 1
fi

xcrun simctl boot "$DEVICE_UDID" >/dev/null 2>&1 || true

TEST_ARGS=()
if [ "$INCLUDE_UI_TESTS" -eq 0 ]; then
  TEST_ARGS+=(-only-testing:BodegasNYCTests)
fi

"$TIMEOUT_BIN" "$TIMEOUT_SECONDS" xcodebuild test \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,id=${DEVICE_UDID}" \
  -destination-timeout 60 \
  -derivedDataPath "$DERIVED_DATA" \
  -skipPackagePluginValidation \
  "${TEST_ARGS[@]}"
EXIT_CODE=$?

sweep_clones

if [ "$EXIT_CODE" -eq 124 ]; then
  echo "error: test run killed after ${TIMEOUT_SECONDS}s timeout" >&2
fi

exit "$EXIT_CODE"
