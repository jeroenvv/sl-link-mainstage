#!/bin/bash
# Compiles and runs the pure codec golden-vector tests: the SL Link codec
# and the MainStage bridge's "SM" SysEx dialect codec.
#
# There is no Xcode test target for this project (see CLAUDE.md): the app
# target uses a PBXFileSystemSynchronizedRootGroup, so every .swift file
# under SL-Link-Mainstage/ is compiled into the app automatically. Keeping
# the codec files (SLLinkProtocol/Encoder/Decoder, MainStageProtocol)
# import-Foundation-only and free of CoreMIDI/SwiftUI lets us compile them
# standalone here, alongside Tests/SLLinkCodecTests.swift (which lives
# outside SL-Link-Mainstage/ so it is never compiled into the app), with
# plain swiftc. MainStageEndpoint.swift is deliberately NOT in this list -
# it's CoreMIDI transport, not pure codec, and isn't part of this suite.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SLLINK_DIR="$REPO_ROOT/SL-Link-Mainstage/SLLink"
MAINSTAGE_DIR="$REPO_ROOT/SL-Link-Mainstage/MainStage"
TESTS_DIR="$REPO_ROOT/Tests"
OUT_BIN="${TMPDIR:-/tmp}/slllink-codec-tests"

# swiftc only allows top-level statements in a file literally named
# main.swift. Tests/SLLinkCodecTests.swift keeps its descriptive name on
# disk, so copy it to a scratch main.swift just for this compile.
SCRATCH_DIR="$(mktemp -d)"
trap 'rm -rf "$SCRATCH_DIR"' EXIT
cp "$TESTS_DIR/SLLinkCodecTests.swift" "$SCRATCH_DIR/main.swift"

swiftc -O \
    "$SLLINK_DIR/SLLinkProtocol.swift" \
    "$SLLINK_DIR/SLLinkEncoder.swift" \
    "$SLLINK_DIR/SLLinkDecoder.swift" \
    "$MAINSTAGE_DIR/MainStageProtocol.swift" \
    "$SCRATCH_DIR/main.swift" \
    -o "$OUT_BIN"

"$OUT_BIN"
