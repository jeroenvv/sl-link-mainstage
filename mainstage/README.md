# Setting up a concert

How an SL88 MK2 wires itself to MainStage through this device script. Start from any MainStage template
with the SL88 connected; an example concert will be added here later.

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

| CC | Control |
|---:|:--|
| 14 | B Encoder |
| 20–27 | Zone 1–8 Encoder |
| 36–39 | Zone 1–4 Select |
| 40–43 | Zone 5–8 Select |
| 44–51 | Zone 1–8 Push |
| 52 | B Push |
| 102–109 | Zone 1–8 Select (long) |
| 110–117 | Zone 1–8 Push (long) |
| 118 | B Push (long) |

CC 0 and 32 are never used — they are the Bank Select pair patch selection sends.

Two attributes on a mapped control drive what the SL88 shows in its popup:

- **Replace Parameter Label** names the control on screen; leave it blank and the popup shows
  MainStage's own parameter name.
- **Custom Color** sets the zone encoder's ring colour. The default is yellow.

## A trap worth knowing

If a mapping appears to do nothing, check the assignment's **value range** — a range collapsed to 0/127
makes a working binding look dead. And when learning, move only the intended control: a gesture that
emits two CCs can be learned to the wrong one.
