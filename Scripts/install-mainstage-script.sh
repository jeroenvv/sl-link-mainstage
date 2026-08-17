#!/bin/bash
# Installs the "SL MainStage" MainStage MIDI Device Script.
#
# The app is sandboxed (ENABLE_APP_SANDBOX = YES, see CLAUDE.md) and can
# never write outside its container, so it cannot place this file itself -
# this script has to be run by hand (or by whatever install flow ends up
# wrapping it) whenever the script changes, and again after any MainStage
# update that might reset or re-scan its script folders.
#
# Destination confirmed by the Phase 0 v2 spike (see docs/mainstage-integration.md):
# MainStage actually loads from
#   ~/Music/Audio Music Apps/MainStage Devices/<Manufacturer>/<Model>.device/
# NOT "MIDI Device Scripts", which is Logic Pro's folder of the same shape -
# an earlier version of this comment got that wrong and cost several rounds
# of the script silently never matching. No admin rights required and no
# modification of MainStage.app itself, so the install survives app updates.
#
# Idempotent: safe to re-run any time (e.g. after editing config.lua, or
# after a MainStage update) - it just re-copies the current source over
# whatever is already installed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DEVICE_NAME="SL MainStage.device"
SOURCE_DIR="$REPO_ROOT/MainStageScript/$DEVICE_NAME"

# Must match controller_info()'s `manufacturer` field in config.lua.
MANUFACTURER_DIR="SL Link Bridge"

DEST_ROOT="$HOME/Music/Audio Music Apps/MainStage Devices"
DEST_DIR="$DEST_ROOT/$MANUFACTURER_DIR/$DEVICE_NAME"

if [ ! -f "$SOURCE_DIR/config.lua" ]; then
    echo "error: $SOURCE_DIR/config.lua not found (run this script from a checkout of the repo)." >&2
    exit 1
fi

mkdir -p "$DEST_ROOT/$MANUFACTURER_DIR"
rm -rf "$DEST_DIR"
cp -R "$SOURCE_DIR" "$DEST_DIR"

echo "Installed $DEVICE_NAME to:"
echo "  $DEST_DIR"
echo
echo "Quit and relaunch MainStage (or select a different MIDI device and back)"
echo "for it to re-scan MIDI Device Scripts and pick this up."
echo
echo "Note: a MainStage update can reset or move this folder - re-run this"
echo "script if the bridge stops showing up after updating MainStage."
