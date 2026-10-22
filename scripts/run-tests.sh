#!/bin/bash
# Run the BodegasNYC test suite against a pinned, reused simulator.
#
# This is the only supported way to run tests in this repo (see CLAUDE.md).
# It exists to fix recurring problems observed running `xcodebuild test`
# ad hoc: an ambiguous destination spinning up "Clone N of <device>"
# simulators, and slow or hung UI-test runs on those clones.
#
# Usage: scripts/run-tests.sh [--ui] [timeout_seconds]
#   --ui                  also run BodegasNYCUITests. Passes
#                          `-parallel-testing-enabled NO`, so every test
#                          runs on the pinned device itself and xcodebuild
#                          never clones it (#101). With parallel testing on,
#                          xcodebuild fanned the run out to three fresh
#                          "Clone N of iPhone 17 Pro" devices, the first UI
#                          launch on a fresh clone took ~60s, and the run hit
#                          the cap. Measured with the flag: ~45-55s of
#                          testing after a warm build, no clones.
#   TEST_TIMEOUT_SECONDS env var overrides the default (180s / 3min) too.
#
# Clones live in xcodebuild's own device set
# (~/Library/Developer/XCTestDevices), not the default one, so the sweep
# below lists and deletes them with `simctl --set testing` (shut-down
# leftovers only; that set is shared machine-wide). Unit-only runs
# keep xcodebuild's default parallel testing, so they can still boot one
# "Clone 1 of" device for the duration of the run; xcodebuild deletes it
# afterwards and the sweep catches any it leaves behind.
#
# The pinned device is shut down after the run if it was shut down before
# it (machine rule in ~/.claude/CLAUDE.md: a simulator stays booted only
# while it is in use); one that was already booted is left booted.
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

# Only shut-down leftovers: the testing device set is shared by every
# project's xcodebuild on this Mac, so a booted clone is someone's live run.
sweep_clones() {
  xcrun simctl --set testing list devices 2>/dev/null \
    | grep -E "Clone [0-9]+ of " \
    | grep -F "(Shutdown)" \
    | grep -oE "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}" \
    | while read -r udid; do
        xcrun simctl --set testing delete "$udid" >/dev/null 2>&1 || true
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

# Recorded inside the lock, before this run boots it: only a device that
# was shut down beforehand gets shut down again afterwards.
WAS_SHUTDOWN=0
if xcrun simctl list devices | grep -F "$DEVICE_UDID" | grep -qF "(Shutdown)"; then
  WAS_SHUTDOWN=1
fi

xcrun simctl boot "$DEVICE_UDID" >/dev/null 2>&1 || true

TEST_ARGS=()
if [ "$INCLUDE_UI_TESTS" -eq 0 ]; then
  TEST_ARGS+=(-only-testing:BodegasNYCTests)
else
  # No parallel testing, so no clones: see the header (#101).
  TEST_ARGS+=(-parallel-testing-enabled NO)
fi

"$TIMEOUT_BIN" "$TIMEOUT_SECONDS" xcodebuild test \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,id=${DEVICE_UDID}" \
  -destination-timeout 60 \
  -derivedDataPath "$DERIVED_DATA" \
  -skipPackagePluginValidation \
  ${TEST_ARGS[@]+"${TEST_ARGS[@]}"} # guarded: macOS bash 3.2 + `set -u` treats an empty array as unbound
EXIT_CODE=$?

# Machine rule (~/.claude/CLAUDE.md): a simulator stays booted only while
# its lane is building or testing. Only if this run booted it (a device
# someone booted on purpose stays as it was), and inside the lock, so it
# can never shut down a device another lane's run has just booted.
if [ "$WAS_SHUTDOWN" -eq 1 ]; then
  xcrun simctl shutdown "$DEVICE_UDID" >/dev/null 2>&1 || true
fi

sweep_clones

if [ "$EXIT_CODE" -eq 124 ]; then
  echo "error: test run killed after ${TIMEOUT_SECONDS}s timeout" >&2
fi

exit "$EXIT_CODE"
