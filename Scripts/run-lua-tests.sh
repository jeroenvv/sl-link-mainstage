#!/bin/bash
# Offline regression suite for MainStageScript/STUDIOLOGIC/SL.device/config.lua.
#
# config.lua is a 2,900-line single-file MainStage device script with no
# CoreMIDI, no Xcode target, and (per .claude/skills/lua-harness/SKILL.md)
# previously no checked-in test - every session that needed to verify it
# wrote a throwaway harness in /tmp. That made refactoring it unsafe: a
# rewrite could regress the flush pacing, the scroll math or a message
# builder with nothing to catch it before a hardware round-trip. This suite
# is the permanent replacement - see Tests/lua/harness.lua's own header for
# what it drives. (This project once had an equivalent standalone suite,
# run-codec-tests.sh, for a Swift companion app; that app and script now
# live only on the archive/swift-app branch.)
#
# Two gates, syntax first:
#   1. `luac -p` on config.lua - fails fast on anything that would not even
#      load inside MainStage's own Lua host.
#   2. Tests/lua/harness.lua under `lua`, driving config.lua's callbacks
#      directly and asserting on the bytes/state they produce. Its golden
#      byte vectors are derived from the spec's message tables
#      (docs/implementing-sl-link.md, the upstream spec pinned at 4c0824d) -
#      see the lua-harness skill for the general recipe if a vector needs
#      re-deriving. They were also originally cross-checked by hand against
#      this project's own Swift SLLinkEncoder.swift; that encoder is
#      preserved on the archive/swift-app branch if a byte-for-byte second
#      opinion is ever wanted again (checkout that branch and run
#      `swiftc -o /tmp/xchk SL-Link-Mainstage/SLLink/SLLinkProtocol.swift
#      SL-Link-Mainstage/SLLink/SLLinkEncoder.swift /tmp/xchk/main.swift`,
#      with main.swift printing hex for id1=SL_HOST_ID, id2=SL_INSTANCE_START).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_LUA="$REPO_ROOT/MainStageScript/STUDIOLOGIC/SL.device/config.lua"
HARNESS="$REPO_ROOT/Tests/lua/harness.lua"

# Overridable so CI can point at Ubuntu's lua5.4 package, which installs its interpreter and
# compiler as `lua5.4`/`luac5.4` rather than `lua`/`luac`.
LUA="${LUA:-lua}"
LUAC="${LUAC:-luac}"

if ! command -v "$LUAC" >/dev/null 2>&1 || ! command -v "$LUA" >/dev/null 2>&1; then
    echo "error: $LUA/$LUAC not found on PATH." >&2
    echo "  macOS:          brew install lua" >&2
    echo "  Debian/Ubuntu:  apt-get install lua5.4   (binaries are lua5.4/luac5.4 - set LUA=lua5.4 LUAC=luac5.4)" >&2
    exit 1
fi

echo "== Gate 1: $LUAC -p (syntax) =="
"$LUAC" -p "$CONFIG_LUA"
echo "OK"

echo ""
echo "== Gate 2: Tests/lua/harness.lua =="
"$LUA" "$HARNESS" "$CONFIG_LUA"
