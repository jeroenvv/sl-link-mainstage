---
name: probe-mainstage-internals
description: Discover what MainStage's Lua device-script host actually supports by reading the shipped application, instead of guessing or trial-and-erroring on hardware. Use when you need to know whether a controller_info() key, action, or MIDI constant exists and is implemented, before spending a hardware round-trip on it.
---

# Reading MainStage's Lua host statically

**Check which MainStage is actually running before probing anything.** More than one version can be
installed side by side, and probing the wrong one silently yields findings that do not describe the
running app — nothing errors, the strings are just for a different binary:

```bash
ps -eo pid,comm | grep -i mainstage
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "<bundle>/Contents/Info.plist"
```

Confirm the bundle path matches the one that process is actually running from, then use that bundle
for everything below. Concretely: this project once had both `MainStage.app` (4.3.1, the one that
runs) and `MainStage 3.7.1.app` (an old copy) installed, and a probing session read the 3.7.1 bundle
by mistake. The framework was even renamed between the two versions —
`LogicPro.framework` in 3.7.1, `LogicMainStage.framework` in 4.3.1 — so a path copied from memory or
from an old note can point at a bundle, or a framework inside it, that no longer exists or that
belongs to the wrong version. Always re-derive the path from the running app; never hardcode one from
a prior session.

`controller_info()` is parsed by `LogicMainStage.framework`, not by MainStage's own binary — MainStage
and Logic Pro share the control-surface code (this framework was named `LogicPro.framework` in older
MainStage versions such as 3.7.1):

```
/Applications/MainStage.app/Contents/Frameworks/LogicMainStage.framework/Versions/A/LogicMainStage
```

## Two frameworks, and the trap between them

`LogicMainStage.framework` holds the `controller_info` parser and the table of **injected globals** —
the names the script may *call* (`settriggertimer`, `get_host_version`) plus the `MIDI_*` constants.

**The callbacks the host calls ON the script are NOT there.** They live in
`MainStageCore.framework/Versions/A/MainStageCore` — `controller_midi_out`, `controller_midi_out_clear`,
`controller_select_patch_done`, `update_layer`. `controller_midi_in` is in neither framework's string
table despite plainly working.

This cost this project a wrong conclusion: probing LogicMainStage for a way to read a mapped
parameter's value found only two callables and the search was reported as "no such API exists". The API
did exist — `controller_midi_out(midiEvent, name, valueString, color)` — as a callback, in the other
framework, and used by 14 shipped scripts. **So a negative from the injected-globals table says nothing
about callbacks.** Search both frameworks, and search the bundled scripts for `function controller_`
before concluding anything is absent.

## Finding the key vocabulary

The parser's recognised keys sit in one contiguous string table, interleaved with its own error
strings. Anchor on those errors — that's what proves the keys belong to the Lua parser rather than
some unrelated plist schema:

```bash
LP="/Applications/MainStage.app/Contents/Frameworks/LogicMainStage.framework/Versions/A/LogicMainStage"
strings -a -t d "$LP" | grep -n "LUA: controller_info"
strings -a -t d "$LP" | awk '$1>=11871264 && $1<=11871767 {print}'
```

Offsets shift between MainStage versions — re-locate via the `LUA: controller_info` anchor rather
than reusing the numbers above (verified on 4.3.1; do not reuse the 3.7.1 offsets from older notes,
which land in a different, unrelated region of that binary). The table appears twice in the binary.

## Command IDs for actions/key commands

Live in a readable plist:

```bash
plutil -p "/Applications/MainStage.app/Contents/Resources/en.lproj/WsCommands.plist"
```

~127 commands across 11 groups, each with an ID, a localised name and an ObjC selector.

## The 98 bundled scripts are a usage corpus

The best evidence for what is actually load-bearing:

```bash
MS="/Applications/MainStage.app/Contents/Frameworks/MACore.framework/Versions/A/Resources/MIDI Device Scripts"
grep -rl --binary-files=text "<key>" "$MS" | wc -l
```

A key used by many bundled scripts is safe; one used by none is unproven.

## Whether the host implements a key at all

```bash
grep -rl --binary-files=text "<token>" "/Applications/MainStage.app" 2>/dev/null
```

A hit in `MainStageCore` or `LogicMainStage` means the string exists somewhere in the app; no hit
anywhere means it is very likely inert.

## The two traps — these are the point of this skill

**1. A key can be composed at runtime, so a literal grep finds nothing.** `action_mainstage` appears
nowhere in the binaries, yet the bare prefix `action_` sits in the key table beside
`logicpro`/`logicprox`, and MainStage passes `applicationName = "MainStage"` to
`controller_initialize`. The key is built as `action_` .. the lowercased app name. A negative grep
for a full key name is NOT evidence of absence — check for prefixes and for the app-name components
separately.

**2. Presence in the key table does NOT mean the feature works.** This is the big one, and it has a
worked example. `action_<app>` is read by the parser, is used by Arturia's shipped KeyLab mk3
script, and maps to genuine `WsCommands.plist` IDs — and it is completely inert under MainStage
4.3.1 (the version actually running). It was tested across six configurations (script-injected CCs on
channel 16 and channel 1, real hardware CC 1 and CC 16, both the `action_<app>` and bare `action`
spellings, with and without `objectType`) and never fired. The key table lives in
*LogicMainStage*.framework, so a key found there may be a Logic Pro feature MainStage simply does not
implement.

**The rule:** static probing of the binary generates *hypotheses*, never conclusions. Every finding
must be confirmed on hardware via the `test-mainstage-script` skill before it is written down as fact
or built on. Reference `docs/mainstage-device-scripts.md` §2, which holds the extracted vocabulary and
the `action_<app>` negative in full — record new findings there.

## Runtime beats static reading

`MIDI_LSB`, `MIDI_MSB` and `MIDI_Wildcard` are not numbers — they are the strings `'aa'`, `'bb'` and
`'??'`, and `MIDI_CtrChange` is `176`. That was found by simply printing them from
`controller_initialize`, after the project had assumed they were numeric for months. Sometimes one
`print()` beats an afternoon of disassembly.
