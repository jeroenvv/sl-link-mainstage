#!/bin/bash
# Bumps the project version and keeps VERSION and config.lua's SCRIPT_VERSION in step.
#
# Versioning rule: the version changes ONLY when the shipped Lua device script
# (MainStageScript/STUDIOLOGIC/SL.device/config.lua) changes. Docs, shell scripts, CI config and
# the test harness do not move it. Minor for new features, patch for fixes, major only for a
# change that breaks an existing MainStage MIDI-Learn mapping or the install layout.
#
# Writes both copies of the version in one place so they can't drift, then re-runs
# run-lua-tests.sh so its drift assertion (see Tests/lua/harness.lua, "SCRIPT_VERSION matches
# the repo-root VERSION file") proves the two agree.
#
# Usage:
#   Scripts/bump-version.sh <major|minor|patch> [--dry-run]
#
#   --dry-run   print old -> new and exit; touches nothing (used by CI to decide whether to
#               commit a bump before actually making one).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION_FILE="$REPO_ROOT/VERSION"
CONFIG_LUA="$REPO_ROOT/MainStageScript/STUDIOLOGIC/SL.device/config.lua"

usage() {
    echo "usage: $(basename "$0") <major|minor|patch> [--dry-run]" >&2
}

PART=""
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run)
            DRY_RUN=1
            ;;
        major|minor|patch)
            PART="$arg"
            ;;
        *)
            echo "error: unrecognized argument '$arg'" >&2
            usage
            exit 1
            ;;
    esac
done

if [ -z "$PART" ]; then
    echo "error: missing version part (major, minor or patch)" >&2
    usage
    exit 1
fi

if [ ! -f "$VERSION_FILE" ]; then
    echo "error: $VERSION_FILE not found" >&2
    exit 1
fi

OLD_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
if ! [[ "$OLD_VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    echo "error: $VERSION_FILE does not contain a strict semver version (got '$OLD_VERSION')" >&2
    exit 1
fi
MAJOR="${BASH_REMATCH[1]}"
MINOR="${BASH_REMATCH[2]}"
PATCH="${BASH_REMATCH[3]}"

case "$PART" in
    major)
        MAJOR=$((MAJOR + 1))
        MINOR=0
        PATCH=0
        ;;
    minor)
        MINOR=$((MINOR + 1))
        PATCH=0
        ;;
    patch)
        PATCH=$((PATCH + 1))
        ;;
esac

NEW_VERSION="$MAJOR.$MINOR.$PATCH"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "$OLD_VERSION -> $NEW_VERSION (dry run, nothing changed)"
    exit 0
fi

printf '%s' "$NEW_VERSION" > "$VERSION_FILE"

# Only the SCRIPT_VERSION line's quoted literal is replaced. `sed -i.bak` + `rm` (rather than
# `sed -i ''`) because the in-place flag's syntax differs between BSD sed (macOS) and GNU sed
# (CI's Ubuntu) - this form works on both.
if ! grep -q "^SCRIPT_VERSION = '$OLD_VERSION'\$" "$CONFIG_LUA"; then
    echo "error: could not find \"SCRIPT_VERSION = '$OLD_VERSION'\" in $CONFIG_LUA" >&2
    exit 1
fi
sed -i.bak "s/^SCRIPT_VERSION = '$OLD_VERSION'/SCRIPT_VERSION = '$NEW_VERSION'/" "$CONFIG_LUA"
rm -f "$CONFIG_LUA.bak"

echo "$OLD_VERSION -> $NEW_VERSION"

"$SCRIPT_DIR/run-lua-tests.sh"
