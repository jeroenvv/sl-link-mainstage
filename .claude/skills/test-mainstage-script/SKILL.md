---
name: test-mainstage-script
description: Deploy and verify a change to the MainStage Lua device script (MainStageScript/STUDIOLOGIC/SL.device/config.lua) against the real SL88. Use whenever a config.lua edit needs checking on hardware - installing it, relaunching MainStage, capturing LUA_DEBUG output and MIDI traffic, and judging the result soundly.
---

# Testing a MainStage device script on hardware

Every hardware round-trip costs a MainStage relaunch (slow - the concert loads real orchestral
instruments) plus a request for Jeroen's attention. Treat round-trips as the scarce resource: verify
offline first with the `lua-harness` skill, and make each hardware run answer a single question.

## Before deploying

1. `luac -p "MainStageScript/STUDIOLOGIC/SL.device/config.lua"` — never deploy a file that will not
   parse; a syntax error looks exactly like "the feature does not work".
2. Run the offline harness (`lua-harness` skill) over whatever changed.
3. Change **one variable** per run. Several rounds were wasted here by moving two things at once and
   being unable to attribute the result.

## The loop

```bash
./Scripts/install-mainstage-script.sh          # copies into ~/Music/Audio Music Apps/MainStage Devices/
defaults write com.apple.mainstage3 LUA_DEBUG -bool true
swiftc -o /tmp/sniffer Scripts/sniff-all-sl-ports.swift
rm -f /tmp/lua.log /tmp/sniff.log
nohup /tmp/sniffer 900 > /tmp/sniff.log 2>&1 & disown
./Scripts/restart-mainstage.sh --debug         # quits (answering Don't Save), relaunches, stdout -> /tmp/lua.log
```

Then **ask Jeroen to confirm MainStage has finished loading, and wait for his reply.** Do not infer it
from a sleep, a CPU reading, or a log line. The concert takes a long and variable time to load, and a
result read during loading is worthless — this is a standing correction, see the
`mainstage-hardware-test-pacing` memory. Check in at short intervals (~20s) rather than one long wait.

If the test needs the SL88's own session, ask him to select **MainStage** in the keyboard's APP list.

Afterwards, always:

```bash
defaults write com.apple.mainstage3 LUA_DEBUG -bool false
pkill -f "/tmp/sniffer"
```

`LUA_DEBUG` measurably slows MainStage down; leaving it on is a real cost to him.

## Reading the results

- `print()` from Lua goes to **stdout only** (`/tmp/lua.log`). `log show` / `log stream` show nothing.
- The sniffer sees CoreMIDI **sources** only.

## Two rules that cost this project the most

**1. Establish a positive control before believing any negative.** A dozen rounds concluded "outbound
MIDI never works" from a setup that could not have observed it. Before trusting "nothing happened",
prove the measurement path works end to end by producing the same signal a known-good way — e.g.
`Scripts/probe-sllink.swift` sends a real Identification Request and the SL88 answers in ~2 ms.

**2. `outport` addresses a destination; the sniffer watches sources.** A script sending to `'LINK'`
goes *into* the keyboard, where nothing is listening. To observe it, provoke a **reply** that comes
back on a source (an Identification Query or Request), and watch for that instead.

Design every hardware test around a signal you have already proven you can see.

## Gotchas already paid for — do not rediscover

- `outport` must be the short `kMIDIPropertyName` (`'LINK'`), never the display name (`'SL LINK'`).
  MainStage reports the correct name itself as `controller_midi_in`'s `portName`.
- MainStage loads the script **once per USB-MIDI interface** — two instances, so every `print()`
  appears twice and both instances contend for a DeviceID.
- MainStage tears the script down and re-initialises it repeatedly; `controller_finalize` firing does
  not mean the user quit.
- `settriggertimer` is a one-shot that will **not** re-arm from inside `controller_timer_trigger` —
  only from `controller_midi_in`.
- Quitting MainStage raises a save prompt that must be answered **Don't Save**; unanswered, it silently
  blocks the quit and the next test fails for an unrelated-looking reason. `restart-mainstage.sh`
  handles this — use it rather than a bare `osascript ... to quit`.
- Script matching runs on CoreMIDI device-add events; a full quit + relaunch is enough to force a
  rescan (no unplug/replug needed when the SL88 is already connected).

## Reporting

State what was actually observed, separately from what it implies. If a negative result rests on an
unproven observation path, say so rather than concluding the feature is impossible — see the
`no-declaring-dead-ends` memory. Record anything durable in `docs/mainstage-integration.md`.
