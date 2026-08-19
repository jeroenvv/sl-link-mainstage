---
name: lua-harness
description: Verify MainStage device-script (config.lua) logic offline, before spending a hardware round-trip - drive the callbacks with a stubbed MainStage, assert on the bytes emitted, and cross-check them against the real Swift SLLinkEncoder. Use when changing config.lua's session logic, drawing, flush behaviour or message building.
---

# Offline harness for config.lua

A hardware test costs a MainStage relaunch and Jeroen's attention. Most bugs do not need one: the
script is plain Lua, so drive it directly. This caught the timer re-arm ordering bug and a runaway
repaint loop before either reached the keyboard.

Requires `lua` (`brew install lua`). `luac -p` is the syntax gate — run it first, always.

## The stub

`config.lua` only needs `settriggertimer` and the `MIDI_*` constants MainStage injects:

```lua
MIDI_Wildcard, MIDI_MSB, MIDI_LSB = 0, 0, 0
armed = nil
function settriggertimer(ms) armed = ms end
dofile("MainStageScript/STUDIOLOGIC/SL.device/config.lua")
```

Inbound events are **0-indexed** tables, matching what MainStage passes:

```lua
local function frame(...)
  local a, e = {...}, {}
  for i, v in ipairs(a) do e[i-1] = v end
  return e
end
local function qreply()  -- Identification Query reply: what drives the session clock
  return frame(0xF0,0x00,0x20,0x1A,0x16,0x03,instanceID,0x7F,0x03,0x01,0xF7)
end
local function hex(t)
  local s = {} ; for i = 1, #t do s[#s+1] = string.format("%02X", t[i]) end
  return table.concat(s, " ")
end
```

Globals inside `config.lua` (`state`, `instanceID`, `pendingMessages`, `timerTicks`, …) are readable
and writable from the harness — set up a state directly instead of replaying a whole session.

## What is worth asserting

- **Flush shape and budget.** Every flush `<= FLUSH_BUDGET`, and carries the Identification Query when
  it should. A flush without one cannot re-arm the clock.
- **Queue drains.** Loop `while has_pending() do flush_pending(true) end` and count flushes; assert the
  repaint converges rather than growing.
- **No runaway repaints.** Simulate many tick/reply rounds and count `paint_screen` calls — wrap it to
  count. Express the expectation as a *rate* (`idleTicks / REPAINT_EVERY_IDLE_TICKS`), not a magic
  number, or the assertion breaks whenever the interval changes.
- **Musical MIDI passes through.** `controller_midi_in(frame(0x90,0x40,0x64), "LINK")` must return
  `nil`. Returning a table swallows the event and hangs notes.
- **Timer re-arm interval** via the `armed` stub — fast while draining, keepalive cadence when idle.

## Cross-check bytes against the Swift encoder

`SLLinkProtocol.swift` + `SLLinkEncoder.swift` are pure (`import Foundation` only), so they compile
standalone and are the authority on every byte. Compare rather than eyeball:

```bash
mkdir -p /tmp/xchk && cat > /tmp/xchk/main.swift <<'EOF'
func h(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }
print("IDENT " + h(SLLinkEncoder.identificationRequest(id1: 0x03, id2: 0x6E, name: "MainStage")))
print("TEXT "  + h(SLLinkEncoder.displayWriteText(id1: 0x03, id2: 0x6E, text: "Patch", x: 8, y: 80,
      maxWidth: 304, align: .center, size: .big, foreground: .white, background: .black)))
EOF
swiftc -o /tmp/xchk/chk SL-Link-Mainstage/SLLink/SLLinkProtocol.swift \
                        SL-Link-Mainstage/SLLink/SLLinkEncoder.swift /tmp/xchk/main.swift && /tmp/xchk/chk
```

Then diff against the Lua hex. They must match byte for byte — this is what confirms the Lua
`append_msb_lsb` / `append_rgb` / `append_text` helpers still mirror `msbLsb` / `rgb7` /
`asciiTerminated`.

Note `main.swift` must be named exactly that for top-level code (same reason
`Scripts/run-codec-tests.sh` copies its test file).

## Working style

- Put harnesses in `/tmp`, not the repo — they are throwaway. `Scripts/run-codec-tests.sh` is the
  permanent home for anything worth keeping, and it must keep passing.
- Filter the noise when running: `lua /tmp/t.lua 2>&1 | grep -vE "^\\[sllink\\] (<-|timer)"`.
- Clean up `/tmp/sl-mainstage-bridge-*.bin` afterwards — `write_frame` still attempts file writes, and
  a stale file can confuse a later test.

## What the harness cannot tell you

It proves the script emits the right bytes; it cannot prove the SL88 renders them or that MainStage
delivers them. Everything about MainStage's byte ceiling, the Clear Screen race and the one-shot timer
was only discoverable on hardware. Use this to arrive at the hardware test with the logic already
right — then use the `test-mainstage-script` skill.
