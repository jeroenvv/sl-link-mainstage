---
name: test-mainstage-script
description: Deploy and verify a change to the MainStage Lua device script (MainStageScript/STUDIOLOGIC/SL88.device/config.lua) against the real SL88. Use whenever a config.lua edit needs checking on hardware - installing it, relaunching MainStage, capturing LUA_DEBUG output and MIDI traffic, and judging the result soundly.
---

# Testing a MainStage device script on hardware

Every hardware round-trip costs a MainStage relaunch (slow - the concert loads real orchestral
instruments) plus a request for Jeroen's attention. Treat round-trips as the scarce resource: verify
offline first with the `lua-harness` skill, form hypotheses about host behaviour with the
`probe-mainstage-internals` skill (it can tell you whether a `controller_info()` key or MIDI constant
exists at all, but never use it to conclude — only hardware does that), and make each hardware run
answer a single question.

## Model routing — run this loop on the session model, not in a subagent

**Do not dispatch this skill wholesale to a subagent.** Two reasons:

1. **It has to talk to Jeroen mid-loop.** Waiting for his "MainStage has loaded" confirmation is the
   central rule below, and a subagent cannot ask him. Substituting a timer reintroduces exactly the
   mistake he corrected — see the `mainstage-hardware-test-pacing` memory.
2. **The failures here are failures of interpretation, not execution.** Running install → restart →
   read-log is trivial. Deciding *"is this a real negative, or did I just fail to observe it?"* is
   what cost about ten round-trips. That is judgement work and belongs on the session model.

**The efficient split**, per the standing routing policy:

- **Session model (Opus)** — forming the hypothesis, deciding what the single question is, asking
  Jeroen for readiness, and interpreting the logs.
- **Haiku agent** — the mechanical steps: `install-mainstage-script.sh`, `restart-mainstage.sh`,
  compiling and starting the sniffer, `defaults write` for `LUA_DEBUG`, and cleanup.
- **Sonnet agent** — any edit to `config.lua` the test requires, including one-line diagnostic
  `print()` additions. Do not hand-edit those on the session model.

## Before deploying

1. `luac -p "MainStageScript/STUDIOLOGIC/SL88.device/config.lua"` — never deploy a file that will not
   parse; a syntax error looks exactly like "the feature does not work".
2. Run the offline harness (`lua-harness` skill) over whatever changed.
3. Change **one variable** per run. Several rounds were wasted here by moving two things at once and
   being unable to attribute the result.

## The loop

```bash
pgrep -x MainStage                             # note the pid(s) - compare after restart
./Scripts/install-mainstage-script.sh          # copies into ~/Music/Audio Music Apps/MainStage Devices/
defaults write com.apple.mainstage3 LUA_DEBUG -bool true
swiftc -o /tmp/sniffer Scripts/sniff-all-sl-ports.swift
rm -f /tmp/lua.log /tmp/sniff.log
nohup /tmp/sniffer 900 > /tmp/sniff.log 2>&1 & disown
./Scripts/restart-mainstage.sh --debug         # quits (answering Don't Save), relaunches, stdout -> /tmp/lua.log
```

**Verify the restart actually happened before doing anything else with the result.**
`restart-mainstage.sh --debug` can exit 1 printing `warning: MainStage is still running - a dialog may
still be open on screen`, leaving the OLD process running the OLD script. Twice in one session this
produced a "the feature doesn't work" result that was really a stale process. Confirm all three: the
script exited 0, `pgrep -x MainStage` returns a pid DIFFERENT from the one noted before restart, and
`/tmp/lua.log` was recreated (fresh mtime). Do not proceed until the pid has changed.

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
- **The script logs only SysEx.** `controller_midi_in` prints a line only when `midiEvent[0] == 0xF0`.
  Ordinary CC, note and pitch-bend traffic is not logged, so its absence from `/tmp/lua.log` is not
  evidence it didn't arrive — check the MIDI Message Monitor for that instead. `[sllink] CC batch:
  ... [74=127]` lines are what the script EMITS, and that's what confirms a gesture produced the CC
  number you expected: a false negative came from exactly this gap once, when the gesture performed
  emitted CC 58 while the item under test was learned to CC 74, and nothing in the log revealed the
  mismatch.

## Two rules that cost this project the most

**1. Establish a positive control before believing any negative.** A dozen rounds concluded "outbound
MIDI never works" from a setup that could not have observed it. Before trusting "nothing happened",
prove the measurement path works end to end by producing the same signal a known-good way — e.g.
`Scripts/probe-sllink.swift` sends a real Identification Request and the SL88 answers in ~2 ms.
MainStage's own **Window > MIDI Message Monitor** is the cheapest such control for *inbound* MIDI: it
shows what MainStage is actually receiving, needs no code change and no restart, and proves the MIDI
arrived before concluding that a feature which consumes it is broken.

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
  handles this — use it rather than a bare `osascript ... to quit`. If it needs clearing by hand,
  identify the sheet's buttons first:
  ```bash
  osascript -e 'tell application "System Events" to tell process "MainStage" to get name of every button of every sheet of every window'
  ```
  then click the answer:
  ```bash
  osascript -e 'tell application "System Events" to tell process "MainStage" to click button "Don’t Save" of sheet 1 of window 1'
  ```
  `Don’t Save` uses a CURLY apostrophe (U+2019) — a straight `'` will not match the button name. The
  standing default is Don't Save, but **ask Jeroen first** if he may have made concert changes he
  wants kept — this happened once: deleted MIDI-Learn assignments would otherwise have been discarded.
- Script matching runs on CoreMIDI device-add events; a full quit + relaunch is enough to force a
  rescan (no unplug/replug needed when the SL88 is already connected).

## Reporting

State what was actually observed, separately from what it implies. If a negative result rests on an
unproven observation path, say so rather than concluding the feature is impossible — see the
`no-declaring-dead-ends` memory. Record anything durable in `docs/mainstage-integration.md`.
