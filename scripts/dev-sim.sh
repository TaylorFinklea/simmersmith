#!/usr/bin/env bash
#
# dev-sim.sh — create (idempotently) the simulator that this repo's verify
# commands target, and boot it.
#
# Why this exists: bead verify_cmds used to bake a simulator UDID
# (id=386E369A-…). UDIDs are per-machine, so moving to a new Mac silently
# invalidated 28 of them at once — every Conductor/Arena/ralph dispatch failed
# at its verify step with "Unable to find a destination". A UDID is the wrong
# thing to pin.
#
# The fix is to pin a NAME instead, and make the name reproducible. The name has
# no spaces, so it survives `bd --set-metadata` and Conductor's shell quoting,
# which is why we don't just use a stock name like "iPhone 17 Pro".
#
# Canonical verify destinations (see bd memory `verify-cmd-worktree-safe`):
#
#   build → -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO
#           (needs no simulator at all — prefer this when you only need a compile)
#
#   test  → -destination name=SimmerSmithSim
#           NEVER with CODE_SIGNING_ALLOWED=NO: that strips the iCloud
#           entitlement, CKContainer refuses to init, the test host dies at
#           launch, and xcodebuild prints a bare "** TEST FAILED **" with no
#           test-level error. See bd memory `app-target-tests`.
#
# Run this once per machine. Safe to re-run.

set -euo pipefail

SIM_NAME="SimmerSmithSim"
DEVICE_TYPE="${SM_SIM_DEVICE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}"

if xcrun simctl list devices | grep -q "$SIM_NAME ("; then
    echo "dev-sim: $SIM_NAME already exists"
else
    # Newest installed iOS runtime, so this keeps working across Xcode upgrades.
    RUNTIME="$(xcrun simctl list runtimes --json \
        | python3 -c 'import json,sys; rs=[r for r in json.load(sys.stdin)["runtimes"] if r["isAvailable"] and r["platform"]=="iOS"]; print(sorted(rs, key=lambda r: [int(p) for p in r["version"].split(".")])[-1]["identifier"])')"

    if [[ -z "$RUNTIME" ]]; then
        echo "dev-sim: no available iOS runtime — install one via Xcode → Settings → Components" >&2
        exit 1
    fi

    echo "dev-sim: creating $SIM_NAME ($DEVICE_TYPE on $RUNTIME)"
    xcrun simctl create "$SIM_NAME" "$DEVICE_TYPE" "$RUNTIME" >/dev/null
fi

xcrun simctl boot "$SIM_NAME" 2>/dev/null || true
echo "dev-sim: $SIM_NAME ready"
echo
echo "  build verify:  xcodebuild build -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO"
echo "  test verify:   xcodebuild test  -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination name=$SIM_NAME -only-testing:SimmerSmithTests"
