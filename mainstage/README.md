# Demo concert

`Demo.concert` is a worked example: **every mappable SL88 control is already assigned**, across two sets
and six patches. Open it in MainStage with the SL88 connected and the keyboard is live — no MIDI Learn,
no Layout-mode work.

Use it as a reference for how a rig is wired, or as a starting point to replace the sounds in.

## Two banks of encoders

The four zone encoders, their push buttons and the four zone select buttons exist **twice**:

| Bank | Controls | DAW lamp |
|:--|:--|:--|
| A | Zones 1–4 | dark |
| B | Zones 5–8 | lit |

**The DAW button toggles between them**, latched — press once to switch, again to return. Its lamp is the
only indication of which bank is live, since the same four knobs move either way. The keyboard's popup
also names the active bank's control: `ENC 1` in bank A, `ENC 5` in bank B.

The B encoder, the B push and the joystick do **not** bank — they mean the same thing in both.

## Master volume and its mute

The **A encoder** drives the audio board's own master volume directly. It is not a MIDI control and
cannot be mapped: the script owns the value and writes it to the keyboard, and the popup shows it as
`AUDIO MASTER`, the board's own term.

Its **push button** mutes:

- **Short press** — toggle mute on and off.
- **Long press** — reset the volume to its default and unmute.

## Short and long press

Every button sends **two different CCs**: one on a short press, another on a long one. They are separate
assignments in MainStage, so one button can do two unrelated things.

The long presses are deliberately declared last in the device script, so MainStage's automap never
consumes one — they are always left free for you to assign.

## What is not mappable

These are the script's own controls and send no MIDI:

| Control | Does |
|:--|:--|
| Joystick — tilt | Previous/next patch (up/down), previous/next set (left/right); long up/down jump to the first/last patch |
| Joystick — ring | Browses the patch list |
| Joystick — press | Selects the browsed patch |
| DAW | Toggles the encoder bank |
| ZOOM | Switches between the patch list and the zoomed single patch; long press forces a repaint |
| SETTINGS | Opens the config screen, which lists this CC map on the keyboard itself |
| CANCEL | Logs out of SL Link; long press forces it |
| A encoder and its button | Master volume and mute, as above |

## Mappable controls

All on **MIDI channel 16**. Forty-three in total.

| CC | Control | Type |
|---:|:--|:--|
| 14 | B Encoder | Knob |
| 20–23 | Zone 1–4 Encoder | Knob |
| 24–27 | Zone 5–8 Encoder (bank B) | Knob |
| 36–39 | Zone 1–4 Select | Button |
| 40–43 | Zone 5–8 Select (bank B) | Button |
| 44–47 | Zone 1–4 Push | Button |
| 48–51 | Zone 5–8 Push (bank B) | Button |
| 52 | B Push | Button |
| 102–105 | Zone 1–4 Select (long) | Button |
| 106–109 | Zone 5–8 Select (long) | Button |
| 110–113 | Zone 1–4 Push (long) | Button |
| 114–117 | Zone 5–8 Push (long) | Button |
| 118 | B Push (long) | Button |

CC 0 and 32 are never used — they are the Bank Select pair patch selection sends.

The encoders send **Relative2C**, so an assignment must be set to that rather than an absolute range. A
range collapsed to 0/127 makes a working binding look dead.

## Patch switching

The joystick selects patches on its own. It needs the concert's patches to carry **sequential program
numbers**: select them in the Patch List, then

- **Reset Program Numbers** — for a concert of up to 128 patches, or
- **Set Bank and Program Numbers** — for a larger one. ⚠️ Deletes existing numbering first.

## What the SL88 shows

Two attributes on a mapped control drive the keyboard's popup:

- **Replace Parameter Label** names the control on screen; leave it blank and the popup shows MainStage's
  own parameter name.
- **Custom Color** sets that zone encoder's ring colour. The default is yellow.

A parameter name only reaches the keyboard if the **screen control itself** is mapped. A Smart Control
mapped underneath an unmapped screen control is invisible to the device script — MainStage reports it as
`Unmapped`, and the popup falls back to the encoder's own label and CC number.
