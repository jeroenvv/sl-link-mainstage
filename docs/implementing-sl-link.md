# Implementing SL Link — a reusable guide (Lua or Swift)

How to build an SL Link host from the published spec, for the Studiologic SL88 MK2 / SLMK2 family.
Written from a working implementation in both languages, so it covers the parts the spec does not: the
places real hardware disagrees with it, and the constraints each host environment adds.

**Sources.** The protocol is published at <https://github.com/fatarsrl/sl-link> (this guide is written
against commit `4c0824d`), with byte-level tables under `docs/` and reference JUCE implementations
under `examples/`. Start from the spec, not from anyone's code — but read §7 before trusting it.

**How to read this guide.** Three kinds of statement, kept deliberately separate:

- **Protocol** — what the spec says. True regardless of language or host.
- **Hardware** — what an SL88 MK2 (firmware 1.1.2) actually does, where it differs.
- **Host** — a constraint imposed by *your* environment (CoreMIDI app vs. MainStage script), not by
  SL Link. Do not carry these across.

---

## 1. Message anatomy

Every message, both directions:

```
F0 00 20 1A 16 <ID#1> <ID#2> <ItemType> [Function] [payload...] F7
   └── 00 20 1A = Fatar/Studiologic manufacturer ID
                └── 16 = SL Link protocol ID
```

`ID#1`/`ID#2` are the DeviceID pair identifying *your host* (§4). All bytes between `F0` and `F7` are
7-bit — MSB clear — as MIDI requires.

| ItemType | Meaning | Direction |
|:---|:---|:---|
| `0x00` | System | ↔ |
| `0x01` | Button | Host ← SL |
| `0x02` | White LED | Host → SL |
| `0x03` | Encoder | Host ← SL |
| `0x04` | Display | Host → SL |
| `0x05` | RGB LED | Host → SL |
| `0x06` | Hardware/Pedal settings | ↔ |
| `0x07` | Master Volume | ↔ |
| `0x7F` | Identification | ↔ |

## 2. Encoding primitives

Four rules cover almost everything. Get these right once and most messages assemble themselves.

**14-bit values split MSB-then-LSB.** Anything that can exceed 127 (coordinates, widths):

```
msb = value >> 7      lsb = value & 0x7F
```

**Colours are 7-bit per channel.** Drop the low bit of each 8-bit channel: `r >> 1`. Applies to every
colour field — display *and* RGB LEDs.

**Strings are ASCII, `0x00`-terminated.** The SLMK2 font covers `0x20`–`0x80` only; every other byte is
rendered as a space, so clamp before sending. Handle Unicode/extended ASCII on the host side.

**Encoder ticks are 64-centred and relative.** `delta = tick - 0x40`. Above `0x40` is clockwise,
below is counter-clockwise, and the *magnitude grows with rotation speed* (§6).

Lua and Swift, side by side:

```lua
local function msb_lsb(v) return math.floor(v / 128) % 128, v % 128 end
local function rgb7(r, g, b) return math.floor(r/2), math.floor(g/2), math.floor(b/2) end
local function ascii(s)                    -- returns bytes incl. terminator
  local out = {}
  for i = 1, #s do
    local b = string.byte(s, i)
    out[#out+1] = (b >= 0x20 and b <= 0x80) and b or 0x20
  end
  out[#out+1] = 0x00
  return out
end
```

```swift
func msbLsb(_ v: Int) -> (UInt8, UInt8) {
    let c = UInt16(clamping: max(0, v));  return (UInt8((c >> 7) & 0x7F), UInt8(c & 0x7F))
}
func rgb7(_ c: SLColor) -> (UInt8, UInt8, UInt8) { (c.r >> 1, c.g >> 1, c.b >> 1) }
```

## 3. Identification

```
Request   F0 ... 7F 00 <ASCII name> 00 F7
Approved  F0 ... 7F 01 F7                     (see §7 — hardware appends firmware/model)
Rejected  F0 ... 7F 02 <RSN> F7               RSN 0x00 = ID taken/reserved, 0x01 = list full
Query     F0 ... 7F 03 F7   → replies 7F 03 <0x00 not identified | 0x01 identified>
```

**Choosing a DeviceID.** The spec says generate two random 7-bit numbers, excluding the reserved pairs
`(0x00, 0x00)` and `(0x01, 0x00)`. **Both reference implementations instead use
`(HOST_ID = 0x03, random instance byte)`** — follow them; the SL88 accepts it, and a stable pair is
what makes Login Recall work later. Persist the pair across runs.

**Handle rejection properly.** `RSN 0x00` means the ID is taken — which happens routinely if two
instances of your host run, or a previous session has not timed out. Recover by changing the instance
byte and re-requesting. A deterministic walk (`id + 1`) is easier to reason about than fresh randomness
and needs no entropy source.

The **Identification Query** is underrated: it is the cheapest way to ask "am I still logged in?"
without disturbing anything, and its reply doubles as a liveness probe.

## 4. Session lifecycle

```
idle ──Identification Request──▶ identifying
                                   │ Approved            │ Rejected → new instance byte, retry
                                   ▼
                                 listed ◀── keepalive every 3–4s ──┐
                                   │ user selects your app on the SL88
                                   ▼
                                 active ◀──▶ standby (user left SL-Link mode)
                                   │            └─ restart → REPAINT EVERYTHING
                                   ▼
                                 logout (either side may initiate)
```

**Keepalive is mandatory and unforgiving.** After approval, send a System Device Notification
(`00 00`) *at a rate faster than one per 5 seconds* — 3 s is the usual choice. Miss it and the SLMK2
drops you from the App Menu. This continues after login, not just before it.

**Standby/Restart bracket the user leaving and returning to SL-Link mode.** The SLMK2 retains **no
display state** across standby, so restart must trigger a complete repaint. Design your drawing layer
with a "invalidate everything and redraw" entry point from day one.

**Logout is a request/confirm pair** and either side can start it. Answer a Logout Request (`00 02`)
with a Logout Confirmation (`00 03`).

## 5. Display

Screen is **320 × 240**, origin top-left, `(319, 239)` bottom-right.

| Function | Bytes after ItemType `0x04` |
|:---|:---|
| Write Text `0x00` | `X(2) Y(2) MaxWidth(2) ALIGN SIZE FG(3) BG(3) <string> 00` |
| Clear Screen `0x01` | `R G B` |
| Draw Rectangle `0x02` | `X(2) Y(2) W(2) H(2) R G B` |
| Plot Bitmap `0x03` | `X(2) Y(2) GroupIdx IconIdx FG(3) BG(3)` |

ALIGN: `0x00` left, `0x01` centre, `0x02` right. SIZE: `0x00` small (21 px), `0x01` medium,
`0x02` big (33 px).

**Medium (`0x01`) works**, confirmed on hardware 2026-08-20 — it renders visibly larger than small.
The spec gives no pixel height for it; treat ~27 px as an estimate. `ALIGN_RIGHT` (`0x02`) is also
confirmed working.

**Max Width does the truncating.** It is a *pixel* width; the SLMK2 truncates the string to fit and
appends `...` itself. Do not pre-truncate strings by character count — you will cut correct text
short and still not control the pixel result. `0` means "print it all".

**...but Max Width truncation is unreliable at `SIZE_BIG`.** Confirmed 2026-08-20: a long patch name
at `SIZE_BIG` with `maxWidth = 304` rendered as a *single letter* followed by an ellipsis. At big
size, pass `maxWidth = 0` and control the length in your own code instead — wrapping across two
lines works well. The advice above still holds at `SIZE_SMALL`.

**The SLMK2 font is proportional — do not "fix" `maxWidth = 0` by padding to a character count.**
With `maxWidth = 0`, Write Text's opaque background box is only as wide as the glyphs it actually
draws (see the next point), so a shorter string can leave the tail of a longer previous string on
screen. Padding every string out to a constant *character* count looks like a fix but fails for two
independent reasons, both confirmed on hardware: the font is proportional, so N characters of space
are pixel-narrower than N characters of the letters they replaced, and still leave a stale tail; and
padding is symmetric in characters, not pixels, so it also throws off `ALIGN_CENTER`'s actual
centring. The correct fix is an explicit erase: draw a black `Draw Rectangle` over the full text
band, on a separate message/tick before the text, sized independently of the string's glyph width.
This costs one extra message (and a brief visible blank band, at whatever your pacing is) per string
change — accept it as the price of `maxWidth = 0`.

**The text background fills the whole Max Width box, not just the glyph run.** Confirmed twice on
hardware: an empty string drawn with a coloured background still painted a visible full-width bar,
and a calibration screen's bands spanned the full screen width. This is what makes inverse-video
highlighting cost one message per row, with no backing rectangle needed.

**Text is opaque.** Write Text "will completely overwrite any existing content on the screen pixels
within the area where the text is printed". Two consequences worth designing around:

- Redrawing the same region is self-cleaning — you rarely need Clear Screen at all.
- There are **no layers**; the device paints in message order. If you compose a panel by stacking
  draws, a partial redraw will paint over whatever sat on top.

**Draw only what changed.** A full repaint is dozens of messages. Memoize per region id and skip
unchanged regions. Give each id a region that does **not overlap** any other id's — otherwise
redrawing a lower one silently covers the unchanged ones above it. Where overlap is unavoidable (a
pop-up), force every id sharing that area to be resent together.

**Plot Bitmap draws from the SL88's internal bitmap library, not uploaded pixels.** `GroupIdx`/
`IconIdx` (both 7-bit) select a black-and-white source icon that the device colours on-device using
the message's own FG/BG as a gradient — you send indices, not pixel data. Like Write Text, the icon
**completely replaces the pixels beneath it**: no alpha channel, so it is self-clearing the same way
a redraw is.

| Group | GIDX | Icons | Size |
|:---|:---|:---|:---|
| Knob | `0x00` | `0x00`-`0x0C`, 13 fill levels | 61x54 px |
| Knob Center | `0x01` | `0x00`-`0x0C`, 13 levels, centre-detent variant | 61x54 px |
| Toggle | `0x02` | on/off | 35x35 px |
| Navigation | `0x03` | left, right, left-right, up-down, rotate, push, apply, cancel | 20x20 px |
| Arrow | `0x04` | up, down, left, right, left-right | 10-20 px |
| General | `0x05` | download, edit, back, keyboard, volume-off, volume-on | 16-20 px |
| Daw | `0x06` | play, pause, stop, rec, loop, next, prev — whole-icon or circle+glyph at a 5px offset | 10-20 px |

(Groups per the spec's Appendix A.) `GIDX = 0x7F` is a different form entirely — "plot this Device's
stored 32x32 logo" — and ignores IconIdx and both colour fields. That form depends on the icon-upload
mechanism this project keeps out of scope; the Groups above do not.

**Why it matters:** the Knob group is a native 13-step dial in one ~17-byte message. `config.lua`'s
encoder-value popup currently draws its ring as 20 separate Draw Rectangle messages — 20 of the
popup's 30 — so a Knob icon would cut the popup to ~11 messages and roughly quarter its paint time.

**Unverified on hardware.** No Plot Bitmap has ever been sent by this project; `config.lua` has no
bitmap builder at all. First experiment, before any popup rework: plot all 13 Knob icons in a row on
a cleared screen, in one hardware run, and see whether they render, how the gradient colouring
behaves, and what they actually look like.

## 6. Buttons, encoders, LEDs, volume

**Buttons** (`0x01`, Host ← SL): `<BID> <EVT>`. `EVT` `0x01` = SHORT (fires on *release*, if held under
a second), `0x02` = LONG (fires immediately at one second). 21 buttons; IDs `0x00`–`0x15` with `0x08`
and `0x0D` absent from the spec's table.

**Encoders** (`0x03`, Host ← SL): `<EID> <TK>`, 7 encoders, `TK` 64-centred (§2). **Speed sensitivity is
a feature** — the magnitude grows when turned fast (±2, ±3 per spec; ±8 observed). Add the delta
straight to your value: you get fine control when turned slowly and coarse jumps when fast, free. Do
not add an acceleration curve on top; it fights the hardware.

**White LEDs** (`0x02`, Host → SL): `<WLID> <state 0|1>`. 12 of them, **on/off only** — including the A
and B encoder LEDs, so those can never show a level.

**RGB LEDs** (`0x05`, Host → SL): `<LID 0-3> <R> <G> <B> <BR 0-127>`. Only the four zone encoders. Each
is **a single lamp, not a segmented ring** — it can express state through colour and brightness, never
a value.

**Master Volume** (`0x07`, ↔): `<R/W> <VOL> <MUTE>`. This is the SLMK2's **USB audio board** volume, not
your application's. `R/W = 1` writes; `VOL` is **0–100 as a percentage** (>100 ignored); any non-zero
`MUTE` mutes. `R/W = 0` with `VOL` omitted reads — the SLMK2 replies with current volume and mute, so
call it at startup to sync. `MUTE` may be omitted for backwards compatibility.

## 7. Where hardware disagrees with the spec

All confirmed on an SL88 MK2, firmware 1.1.2, model byte `0x01`. **Read this before trusting a message
length or a "reserved" claim.**

| Spec says | Hardware does |
|:---|:---|
| Identification Approved is a bare 10 bytes; Login Confirmation carries `MAJ MIN REV SL` | **The opposite.** Approved arrives 14 bytes *with* the firmware/model payload; Login Confirmation arrives bare |
| Host never receives A Encoder (`EID 0x05`) / A Encoder Button (`BID 0x0B`) — reserved for USB audio | They **do** arrive, as ordinary messages, with no accompanying volume traffic |
| (silent on whether LONG_PRESSION reaches the host) | LONG **is** delivered for ordinary buttons |
| DeviceID is one 14-bit random value | Reference implementations use `(HOST_ID, instance)` — and the SL88 accepts it |

**Generalise from this: trailing bytes are optional more often than documented.** The spec itself marks
some as optional (Master Volume's `MUTE`, Hardware Settings' `HST`). Accept known variant lengths
explicitly rather than writing `guard bytes.count == N`, or real traffic will fail to decode.

Practical decoder rule: validate the header, validate 7-bit-ness, then accept *a set of* lengths per
function, treating late fields as optional. Latch firmware/model from whichever message actually
carries them and carry the values forward.

## 8. Host environment: a CoreMIDI app (Swift)

**Use the CoreMIDI 1.0 byte-oriented API** (`MIDIClientCreate`, `MIDIInputPortCreate`, `MIDIPacketList`,
`MIDIReadProc`), not `MIDIEventList`/UMP. The protocol is entirely SysEx, so packet handling stays
uniform and you avoid UMP's SysEx framing.

**Find the endpoint by name.** Match case-insensitively on `kMIDIPropertyDisplayName` *containing*
`LINK` — on macOS the SL88's ports appear as `SL CTRL` / `SL DAW` / `SL LINK`. Require both a source
and a destination to match before connecting, and handle hot-plug.

**Respect the real-time thread.** The `MIDIReadProc` runs on CoreMIDI's RT thread: do nothing there but
copy bytes into a lock-free ring buffer — no allocation, no ARC traffic, no logging, no dispatch. Drain
and reassemble `F0…F7` frames on your own serial queue.

**Pace outbound messages.** ~1 message/ms is proven to sustain long bursts (1366 messages, no loss).
Size `MIDIPacketList` buffers correctly for the payload rather than assuming a fixed struct size.

**Sniffing gotcha.** `MIDIInputPortCreateWithBlock` works; the C-function-pointer
`MIDIInputPortCreate` has been observed to silently receive nothing for *input* ports in this context.
That has produced at least one false negative — if a passive listener sees nothing, suspect this first.

## 9. Host environment: a MainStage Lua device script

Everything here is a **MainStage** constraint, not SL Link. It is included because it is invisible in
any documentation and cost a great deal to discover.

- **`outport` must be the short `kMIDIPropertyName`** (`'LINK'`), *not* the display name (`'SL LINK'`).
  Wrong name = every message silently dropped, no error anywhere. MainStage tells you the right one:
  it is the `portName` argument passed to `controller_midi_in`.
- **You can only send by returning from a callback.** There is no send function. Queue outbound work
  and flush it from whichever callback fires next.
- **`settriggertimer` is a one-shot that cannot re-arm itself** from inside `controller_timer_trigger`
  — only from `controller_midi_in`. So a script has no free-running clock. Workaround: have every
  flush carry an Identification Query; its reply arrives at `controller_midi_in` and schedules the next
  tick. That request/response chain becomes your clock.
- **There is a byte ceiling on a returned array** — measured between 78 and 87 bytes, and exceeding it
  discards the **whole** array, not the overflow. Send one message per flush.
- **`io` does not exist** in the sandbox (`attempt to index global 'io'`), so no file-based side
  channel. Wrap any attempt in `pcall`.
- **The script can be loaded once per USB-MIDI interface** — expect up to two instances, contending
  for a DeviceID (hence §3's rejection recovery) and both driving the display. The one hardware run
  measured so far loaded a single instance instead (see
  `docs/config-lua-history.md#single-instance-confirmed-on-hardware-2026-08-28`).
- **MainStage tears the script down and re-initialises it repeatedly.** Do not treat
  `controller_finalize` as "the user quit" and do not send a Logout Request there, or every churn
  removes you from the App Menu.
- **Never swallow musical MIDI.** Returning a table from `controller_midi_in` *replaces* the event;
  return `nil` for notes, pitch bend and sustain or notes hang. Returning MIDI **without** `outport`
  substitutes what MainStage receives — the mechanism for injecting events into the host.
- **Clear Screen was unusable on this path.** Including it at the head of a repaint reliably lost
  exactly one later text, non-deterministically which one. Overdraw instead (§5). Note the Swift
  implementation uses Clear Screen without trouble at ~1 msg/ms, so this is likely an interaction with
  how MainStage emits returned arrays rather than a device fault — cause unproven.

## 10. Verifying an implementation

**Golden vectors from the tables, not from examples.** Derive test vectors from the spec's `docs/*.md`
byte tables. Do not trust worked examples: the one at `docs/basics.md:29`
(`F0 00 20 1A 16 15 E3 04 01 00 F7`) is malformed twice over — `E3` has its MSB set, illegal for a MIDI
data byte, and Clear Screen needs three colour bytes, not one. It makes an excellent *negative* test.

**Keep the codec pure.** Constants, encoder and decoder should depend on nothing but the standard
library — no MIDI framework, no UI. Then they compile standalone and can be tested without hardware or
a test host.

**Cross-check a second implementation byte-for-byte.** If you have both a Lua and a Swift side, compare
their output on identical inputs; it catches a drifting `msbLsb`/`rgb7`/ASCII helper instantly.

**Prove your observation path before believing a negative.** This is the single most valuable habit.
Before concluding "the device ignores X", produce the same signal a known-good way and confirm you can
see it. Two specific traps:

- Watching CoreMIDI **sources** while testing something that addresses a **destination** — the send is
  invisible by construction, not absent.
- Testing anything one-directional. Prefer a request/response probe: an **Identification Request** or
  **Query** makes the SL88 answer within milliseconds on a source you *can* watch, turning an
  unobservable send into an observable round trip.

**Timing hygiene when a host application is involved.** If your test needs a host (a DAW, MainStage)
to be fully loaded, confirm that it is rather than assuming a fixed wait — results captured during
startup are indistinguishable from failures.

## 11. Pitfall checklist

- [ ] Every data byte 7-bit; validate on decode as well as encode
- [ ] Decoder accepts variant lengths — do not hard-`==` a message length (§7)
- [ ] DeviceID persisted; rejection triggers a retry with a new instance byte
- [ ] Keepalive faster than one per 5 s, *continuing* after login
- [ ] Restart triggers a complete repaint (device retains no display state)
- [ ] Logout Request answered with Logout Confirmation
- [ ] Strings clamped to `0x20`–`0x80`, `0x00`-terminated, not pre-truncated
- [ ] Colours right-shifted to 7-bit — display *and* LEDs
- [ ] Encoder delta = `tick - 0x40`, added directly, no added acceleration
- [ ] LONG press handled, never dropped; A encoder/button never discarded
- [ ] Drawing memoized per non-overlapping region
- [ ] Master Volume understood as the *audio board's*, 0–100 percent
