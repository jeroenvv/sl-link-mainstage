# Demo concert

`Demo.concert` is an example rig showing how to wire an SL88 MK2 to MainStage through this device
script. Open it in MainStage with the SL88 connected.

It starts from MainStage's own **Keyboard Minimalist** template, so it carries one patch and a plain
layout — the point is the mappings, not the sounds.

## What is already set up

Nothing yet beyond the template. The assignments below have to be made once, in MainStage, and saved.

## Patch switching

The joystick selects patches on its own; no mapping is involved. It needs the concert's patches to
carry **sequential program numbers**: select them in the Patch List, then

- **Reset Program Numbers** — for a concert of up to 128 patches, or
- **Set Bank and Program Numbers** — for a larger one. ⚠️ Deletes existing numbering first.

## Assignments

Every other SL88 control sends a CC on **channel 16**. In Layout mode, add a screen control, then use
**MIDI Learn** and move the matching control on the keyboard.

| CC | Control | Screen control |
|---:|:--|:--|
| 51 | Zone 1 Push | Button |
| 52 | Zone 1 Push (long) | Button |
| 53 | Zone 2 Push | Button |
| 54 | Zone 2 Push (long) | Button |
| 55 | Zone 3 Push | Button |
| 56 | Zone 3 Push (long) | Button |
| 57 | Zone 4 Push | Button |
| 58 | Zone 4 Push (long) | Button |
| 59 | Zone 1 Encoder | Knob |
| 60 | Zone 2 Encoder | Knob |
| 61 | Zone 3 Encoder | Knob |
| 62 | Zone 4 Encoder | Knob |
| 63 | B Encoder | Knob |
| 65 | B Push | Button |
| 66 | B Push (long) | Button |
| 67 | Zone 1 Select | Button |
| 68 | Zone 1 Select (long) | Button |
| 69 | Zone 2 Select | Button |
| 70 | Zone 2 Select (long) | Button |
| 71 | Zone 3 Select | Button |
| 72 | Zone 3 Select (long) | Button |
| 73 | Zone 4 Select | Button |
| 74 | Zone 4 Select (long) | Button |

CC 40-50 are deliberately unused — the joystick drives patch selection in the script instead.

Two attributes on a mapped control drive what the SL88 shows in its popup:

- **Replace Parameter Label** names the control on screen; leave it blank and the popup shows
  MainStage's own parameter name.
- **Custom Color** sets the zone encoder's ring colour. The default is yellow.

## A trap worth knowing

If a mapping appears to do nothing, check the assignment's **value range** — a range collapsed to 0/127
makes a working binding look dead. And when learning, move only the intended control: a gesture that
emits two CCs can be learned to the wrong one.
