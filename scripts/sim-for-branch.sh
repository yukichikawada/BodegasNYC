#!/bin/bash
# Give each in-flight branch/worktree its own iOS Simulator so parallel
# live runs (build_run_sim, screenshots, manual QA) never overwrite each
# other's install on a shared device.
#
# This is deliberately NOT for unit tests: scripts/run-tests.sh pins one
# simulator and serializes runs via a lockfile for good reasons (see its
# header). Only use this for launching/driving the app.
#
# Usage: scripts/sim-for-branch.sh <create|udid|name|delete> [branch]
#   create   create (if missing) and boot the branch's simulator; prints UDID
#   udid     print the UDID (creates+boots if missing, same as create)
#   name     print the simulator name only, no side effects
#   delete   shut down and delete the branch's simulator
#   branch   defaults to the current git branch of the working directory
#
# Device type/runtime match run-tests.sh's pinned device ("iPhone 17 Pro",
# latest installed iOS runtime). Names are "BodegasNYC-<branch>" with
# slashes and other unsafe characters replaced by "-"; they never match the
# "Clone N of ..." pattern run-tests.sh sweeps, so the two coexist.
set -euo pipefail

cd "$(dirname "$0")/.."

ACTION="${1:-}"
BRANCH="${2:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo detached)}"
DEVICE_TYPE_NAME="iPhone 17 Pro"
PREFIX="BodegasNYC-"

case "$ACTION" in
  create|udid|name|delete) ;;
  *)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
    ;;
esac

SAFE_BRANCH=$(printf '%s' "$BRANCH" | tr -c 'A-Za-z0-9._-' '-' | sed 's/-\{2,\}/-/g; s/^-//; s/-$//')
SIM_NAME="${PREFIX}${SAFE_BRANCH}"

if [ "$ACTION" = "name" ]; then
  echo "$SIM_NAME"
  exit 0
fi

find_udid() {
  xcrun simctl list devices -j \
    | python3 -c '
import json, sys
name = sys.argv[1]
devices = json.load(sys.stdin)["devices"]
for runtime, devs in devices.items():
    for d in devs:
        if d.get("name") == name and d.get("isAvailable", True):
            print(d["udid"]); sys.exit(0)
' "$SIM_NAME"
}

if [ "$ACTION" = "delete" ]; then
  UDID=$(find_udid || true)
  if [ -z "$UDID" ]; then
    echo "no simulator named '$SIM_NAME'" >&2
    exit 0
  fi
  xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
  xcrun simctl delete "$UDID"
  echo "deleted $SIM_NAME ($UDID)"
  exit 0
fi

UDID=$(find_udid || true)
if [ -z "$UDID" ]; then
  DEVICE_TYPE_ID=$(xcrun simctl list devicetypes -j \
    | python3 -c '
import json, sys
for d in json.load(sys.stdin)["devicetypes"]:
    if d["name"] == sys.argv[1]:
        print(d["identifier"]); sys.exit(0)
sys.exit(1)
' "$DEVICE_TYPE_NAME")
  RUNTIME_ID=$(xcrun simctl list runtimes -j \
    | python3 -c '
import json, sys
rts = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "iOS" and r.get("isAvailable", True)]
rts.sort(key=lambda r: [int(x) for x in r["version"].split(".")])
print(rts[-1]["identifier"])
')
  UDID=$(xcrun simctl create "$SIM_NAME" "$DEVICE_TYPE_ID" "$RUNTIME_ID")
  echo "created $SIM_NAME ($UDID)" >&2
fi

xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
echo "$UDID"
