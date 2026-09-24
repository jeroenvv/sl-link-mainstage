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
| Zone 1–4 Encoders, bank A | Smart Knob 1–4 | The loaded patch's Smart Controls |
| Zone 1–4 Encoders, bank B | Smart Knob 5–8 | Four more of them |
| Zone 1–4 Select | Button 1–4 | Prev Set, Next Set, Prev Patch, Next Patch |

**The DAW button toggles the encoder bank**, and its lamp shows which is live. The four encoders, their
pushes and the four select buttons all switch; the B encoder and the joystick do not.

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

| CC | Control | MainStage calls it |
|---:|:--|:--|
| 3, 9 | Zone 1–2 Select | Solo, Mute |
| 14 | B Encoder | — |
| 15, 20 | Zone 3–4 Select | — |
| 28–31 | Zone 1–4 Encoder | Send 1–4 |
| 56–59 | Zone 5–8 Encoder | Insert #1–4 Bypass |
| 60–63 | Zone 5–8 Select | Insert #5–8 Bypass |
| 72–79 | Zone 1–8 Push | Send Mute 1–8 |
| 80 | B Push | — |
| 102–118 | the 17 long presses | — |

These numbers deliberately land on MainStage's own channel-strip names, so a gesture carries its meaning
where one fits. CC 0 and 32 are never used — they are the Bank Select pair patch selection sends.

Two attributes on a mapped control drive what the SL88 shows in its popup:

- **Replace Parameter Label** names the control on screen; leave it blank and the popup shows
  MainStage's own parameter name.
- **Custom Color** sets the zone encoder's ring colour. The default is yellow.

## A trap worth knowing

If a mapping appears to do nothing, check the assignment's **value range** — a range collapsed to 0/127
makes a working binding look dead. And when learning, move only the intended control: a gesture that
emits two CCs can be learned to the wrong one.
