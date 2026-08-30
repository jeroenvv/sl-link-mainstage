#!/bin/bash
# Builds the distributable release zip: dist/sl-link-mainstage-<version>.zip.
#
# Never packages an untested script - runs `luac -p` and the full offline test suite first, and
# refuses to build if config.lua's SCRIPT_VERSION has drifted from the repo-root VERSION file
# (the same drift the run-lua-tests.sh harness checks, caught here again before it ships).
#
# The staged layout deliberately mirrors the repo:
#   README.md
#   VERSION
#   LICENSE
#   NOTICE
#   Scripts/install-mainstage-script.sh
#   MainStageScript/STUDIOLOGIC/SL.device/config.lua
# install-mainstage-script.sh resolves its source as $SCRIPT_DIR/../MainStageScript/..., so
# keeping that relative shape means the same install command works whether it's run from a git
# checkout or from an unzipped copy of this archive. The STUDIOLOGIC/SL.device path segments are
# load-bearing, not cosmetic - they must match controller_info()'s manufacturer/model in
# config.lua, or MainStage's own script matching fails silently (see install-mainstage-script.sh).
#
# Usage:
#   Scripts/build-release.sh [--output-dir <dir>]
#
#   --output-dir <dir>   where to write the zip (default: dist/, already in .gitignore)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION_FILE="$REPO_ROOT/VERSION"
CONFIG_LUA="$REPO_ROOT/MainStageScript/STUDIOLOGIC/SL.device/config.lua"
INSTALL_SCRIPT="$REPO_ROOT/Scripts/install-mainstage-script.sh"
README="$REPO_ROOT/README.md"
LICENSE="$REPO_ROOT/LICENSE"
NOTICE="$REPO_ROOT/NOTICE"

# Overridable so CI can point at Ubuntu's lua5.4 package, which installs its interpreter and
# compiler as `lua5.4`/`luac5.4` rather than `lua`/`luac`.
LUA="${LUA:-lua}"
LUAC="${LUAC:-luac}"

OUTPUT_DIR="$REPO_ROOT/dist"

usage() {
    echo "usage: $(basename "$0") [--output-dir <dir>]" >&2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --output-dir)
            if [ $# -lt 2 ]; then
                echo "error: --output-dir requires an argument" >&2
                usage
                exit 1
            fi
            OUTPUT_DIR="$2"
            shift 2
            ;;
        *)
            echo "error: unrecognized argument '$1'" >&2
            usage
            exit 1
            ;;
    esac
done

if ! command -v "$LUAC" >/dev/null 2>&1 || ! command -v "$LUA" >/dev/null 2>&1; then
    echo "error: $LUA/$LUAC not found on PATH." >&2
    echo "  macOS:          brew install lua" >&2
    echo "  Debian/Ubuntu:  apt-get install lua5.4   (binaries are lua5.4/luac5.4 - set LUA=lua5.4 LUAC=luac5.4)" >&2
    exit 1
fi

if [ ! -f "$VERSION_FILE" ]; then
    echo "error: $VERSION_FILE not found" >&2
    exit 1
fi
VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: $VERSION_FILE does not contain a strict semver version (got '$VERSION')" >&2
    exit 1
fi

CONFIG_VERSION="$(grep -o "^SCRIPT_VERSION = '[0-9.]*'" "$CONFIG_LUA" | sed -E "s/^SCRIPT_VERSION = '(.*)'/\1/")"
if [ -z "$CONFIG_VERSION" ]; then
    echo "error: could not find SCRIPT_VERSION in $CONFIG_LUA" >&2
    exit 1
fi
if [ "$CONFIG_VERSION" != "$VERSION" ]; then
    echo "error: version mismatch - VERSION says $VERSION, config.lua's SCRIPT_VERSION says $CONFIG_VERSION." >&2
    echo "  Run Scripts/bump-version.sh to keep them in step." >&2
    exit 1
fi

echo "== Gate 1: $LUAC -p (syntax) =="
"$LUAC" -p "$CONFIG_LUA"
echo "OK"
echo ""

echo "== Gate 2: full offline test suite =="
LUA="$LUA" LUAC="$LUAC" "$SCRIPT_DIR/run-lua-tests.sh"
echo ""

ARTIFACT_NAME="sl-link-mainstage-$VERSION.zip"
mkdir -p "$OUTPUT_DIR"
# Resolve to an absolute path before we `cd` into the staging tree below.
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
ARTIFACT_PATH="$OUTPUT_DIR/$ARTIFACT_NAME"

STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT

mkdir -p "$STAGE_DIR/Scripts" "$STAGE_DIR/MainStageScript/STUDIOLOGIC/SL.device"
cp "$README" "$STAGE_DIR/README.md"
cp "$VERSION_FILE" "$STAGE_DIR/VERSION"
cp "$LICENSE" "$STAGE_DIR/LICENSE"
cp "$NOTICE" "$STAGE_DIR/NOTICE"
cp "$INSTALL_SCRIPT" "$STAGE_DIR/Scripts/install-mainstage-script.sh"
chmod +x "$STAGE_DIR/Scripts/install-mainstage-script.sh"
cp "$CONFIG_LUA" "$STAGE_DIR/MainStageScript/STUDIOLOGIC/SL.device/config.lua"

rm -f "$ARTIFACT_PATH"
(
    cd "$STAGE_DIR"
    zip -q -X -r "$ARTIFACT_PATH" README.md VERSION LICENSE NOTICE \
        Scripts/install-mainstage-script.sh \
        MainStageScript/STUDIOLOGIC/SL.device/config.lua
)

echo "== Artifact =="
echo "$ARTIFACT_PATH"
ls -lh "$ARTIFACT_PATH" | awk '{print $5}'
