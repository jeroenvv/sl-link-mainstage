# Demo concert

`Demo.concert` is an example rig showing how to wire an SL88 MK2 to MainStage through this device
script. Open it in MainStage with the SL88 connected.

It starts from MainStage's own **Keyboard Minimalist** template, so it carries one patch and a plain
layout — the point is the mappings, not the sounds.

## What is already set up

**Nothing needs mapping by hand.** With the SL88 connected, MainStage assigns a fresh concert's screen
controls from the items this device script declares, and the script declares them in an order chosen to
produce a working rig:

| SL88 control | Screen control | What it does |
|:--|:--|:--|
| B Encoder | Vertical Fader 1 | Output volume |
| Zone 1–4 Encoders | Smart Knob 1–4 | The loaded patch's Smart Controls |
| Zone 1–4 Select | Button 1–4 | Prev Set, Next Set, Prev Patch, Next Patch |

The mappings behind Smart Knob 1–4 follow the patch — Compressor Threshold in one, E-Piano Tremolo in
another — while the assignment stays put. Long presses are deliberately declared last so the automap
never consumes one; they are free for you to assign.

The joystick needs no assignment at all: it selects patches in the script.

## Patch switching

The joystick selects patches on its own; no mapping is involved. It needs the concert's patches to
carry **sequential program numbers**: select them in the Patch List, then

- **Reset Program Numbers** — for a concert of up to 128 patches, or
- **Set Bank and Program Numbers** — for a larger one. ⚠️ Deletes existing numbering first.

## The full CC map

Everything the SL88 sends, on **channel 16**. Anything the automap did not claim is yours to MIDI Learn.

| CC | Control | Type |
|---:|:--|:--|
| 85 | B Encoder | Knob |
| 86–89 | Zone 1–4 Encoder | Knob |
| 102–105 | Zone 1–4 Select | Button |
| 106–109 | Zone 1–4 Push | Button |
| 110 | B Push | Button |
| 111–114 | Zone 1–4 Select (long) | Button |
| 115–118 | Zone 1–4 Push (long) | Button |
| 119 | B Push (long) | Button |

These numbers avoid MainStage's own channel-strip controllers (Insert Bypass 56–71, Send Mute 72–79) and
the MIDI spec's defined range, so nothing else claims them.

Two attributes on a mapped control drive what the SL88 shows in its popup:

- **Replace Parameter Label** names the control on screen; leave it blank and the popup shows
  MainStage's own parameter name.
- **Custom Color** sets the zone encoder's ring colour. The default is yellow.

## A trap worth knowing

If a mapping appears to do nothing, check the assignment's **value range** — a range collapsed to 0/127
makes a working binding look dead. And when learning, move only the intended control: a gesture that
emits two CCs can be learned to the wrong one.
