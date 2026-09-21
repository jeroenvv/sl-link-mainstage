-- SL MainStage - MainStage MIDI Device Script for the Studiologic SL88 MK2
--
-- Speaks SL Link directly from Lua, with no helper application: identifies to the keyboard, holds
-- the session alive, and draws the current MainStage patch on the SL88's screen.
--
-- Background is in docs/, not here:
--   docs/mainstage-device-scripts.md  writing MainStage Lua device scripts
--   docs/implementing-sl-link.md      the SL Link protocol, and where hardware
--                                     disagrees with the published spec
--   docs/mainstage-integration.md     status, and the historical record
--   docs/config-lua-history.md        the reasoning behind THIS file's display
--                                     pacing / session clock / flush constraints
-- The byte-level authority every message here is checked against is docs/implementing-sl-link.md
-- plus the upstream spec (github.com/fatarsrl/sl-link, pinned at 4c0824d). This project's own Swift
-- implementation, once the checkable cross-check, now lives on the archive/swift-app branch.
--
-- MainStage's Lua sandbox has NO `io` and NO `os` - no file access, no clock, no environment. Never
-- add a call to either; it errors immediately (`attempt to index global 'io'`/`'os'`), and there is
-- no way to catch it usefully at load time. (Tests/lua/harness.lua, which drives this file with
-- plain `lua`, is the one place `os` is legitimate - it is not part of the MainStage sandbox this
-- file itself runs in.)
--
-- =========================================================================
-- SIX RULES YOU MUST NOT BREAK. Each was found the hard way; each fails
-- SILENTLY, which is why they are repeated here rather than left in docs.
--
--  1. outport is the SHORT kMIDIPropertyName ('LINK'), never the display
--     name ('SL LINK'). Wrong name = every message discarded, no error.
--     MainStage reports the right one as controller_midi_in's portName.
--  2. One message per flush, <= FLUSH_BUDGET bytes. Over MainStage's ceiling
--     (~78-87) the ENTIRE returned array is dropped, not just the overflow.
--  3. Never send Clear Screen INSIDE AN ORDINARY REPAINT. It used to race
--     with the draws that follow it and lose a line - a different one each
--     run - but that was the display-pacing bug displayFlushReady fixed (see
--     its declaration), not a property of Clear Screen itself. Write Text
--     overwrites the pixels it covers, so redrawing is self-cleaning, which
--     is still why ordinary repaints never need one. The one deliberate
--     exception is set_display_mode's mode switch (see that function's
--     comment) - queued alone, never bundled with a Write Text, paired with
--     its own settle guard. See docs/config-lua-history.md#the-clear-screen-ban-and-its-lift.
--  4. Never truncate strings. Max Width truncates visually in pixels and
--     appends '...' itself.
--  5. Queued messages must be paced to at most ONE per timer tick - ALL of
--     them, not just display. The Identification Query's reply is itself an
--     inbound SL frame, so an ungated flush_pending() re-enters
--     controller_midi_in and drains the queue at the ~2ms round-trip rate
--     instead of the timer's rate - FLUSH_SOON_MS looks like it paces this
--     but does not. The SL88 silently drops a message that arrives while it
--     is still handling the previous one. Pacing only display and MVOL_WRITE
--     is what made one-shot LED/mute/READ messages vanish and forced a 3x
--     repeat workaround. See slFlushReady (shared permit) and
--     displayFlushReady (display's extra settle guard).
--  6. Never call settriggertimer unconditionally from a handler that runs on
--     EVERY inbound MIDI event. controller_midi_in calls rearm_timer() for
--     every note on/off, not just SL frames, and settriggertimer is a
--     ONE-SHOT: each call cancels and restarts whatever is already pending.
--     While the user plays, notes arrive far faster than the timer period,
--     so an ungated rearm_timer() pushes the deadline back forever and
--     controller_timer_trigger NEVER FIRES - no tick means no keepalive,
--     and the SL88 drops a host that goes quiet for ~5s, deselecting it and
--     discarding its draws. This is why the display dropped out WHILE
--     PLAYING and recovered once playing stopped. Fails completely
--     silently - nothing errors, nothing logs, the app just vanishes from
--     the APP list - which is why it is called out here rather than left to
--     be rediscovered. Fix: gate every settriggertimer call behind a
--     `timerPending` flag so only the first call arms it; the one-shot
--     firing (controller_timer_trigger) is what clears the flag again. See
--     rearm_timer() and timerPending's declaration.
-- =========================================================================

-- MARK: - Protocol constants (mirror the spec's ID tables exactly)

SL_PORT = 'LINK' -- see the banner above; NOT 'SL LINK'

SL_HEADER = { 0xF0, 0x00, 0x20, 0x1A, 0x16 }
SL_END = 0xF7

SL_HOST_ID = 0x03 -- SLLinkHeader.defaultHostID

-- Legal range for the instance byte (a MIDI data byte, so also < 0x80): both the per-instance
-- starting value (derive_instance_start) and the rejection bump (handle_identification_rejected)
-- must stay inside it.
SL_INSTANCE_MIN = 0x10
SL_INSTANCE_MAX = 0x7E

-- Item types
IT_SYSTEM = 0x00
IT_BUTTON = 0x01 -- handled for BID_HOME, BID_A_ENC (see handle_home_button/handle_a_encoder_button) and every BID in BUTTON_CC; other BIDs are logged only
IT_LED = 0x02 -- White LED, Host -> SL only: <WLID> <state 0|1> - see docs/implementing-sl-link.md §6
IT_ENCODER = 0x03 -- handled for every EID in ENCODER_CC, plus EID_A (drives Master Volume directly)
IT_DISPLAY = 0x04
IT_RGB_LED = 0x05 -- RGB LED, Host -> SL only: <LID 0-3> <R> <G> <B> <BR>; the four zone encoder rings
	-- only, one lamp each (colour and brightness, never a value) - see docs/implementing-sl-link.md §6
IT_MASTER_VOLUME = 0x07
IT_IDENTIFICATION = 0x7F

-- Master Volume R/W flag (item type IT_MASTER_VOLUME's own function byte).
MVOL_READ = 0
MVOL_WRITE = 1
-- Any VOL > 0x64 makes the write ignore the volume byte, so MUTE alone can be changed - see
-- docs/implementing-sl-link.md §6.
MVOL_IGNORE_VOL = 0x7F

-- FAST-TURN BUDGET: an EID_A delta at or above this magnitude marks its queued write 'fast' (see
-- mvolFastWritesThisTick), letting it bypass the ordinary one-per-tick pace. SL88 ticks run +-1 for a
-- slow turn up to +-8 observed for a fast one, so 3 sits clearly above a single detent. See
-- docs/config-lua-history.md#fast-turn-master-volume-write-budget-2026-09-16.
MVOL_FAST_DELTA_THRESHOLD = 3
-- Total MVOL_WRITE emissions allowed per tick window while fast turning (the base tick grant plus up
-- to this many extra fast-path writes) - a ~4x speed-up over the base 1/tick pace, bounded so a fast
-- sweep can't flood the wire. See the anchor above for the trade-off against the anti-jitter pacing.
MVOL_FAST_WRITES_PER_TICK = 4

-- Button IDs, matching the spec's button ID table (see docs/implementing-sl-link.md).
BID_HOME = 0x10 -- confirmed on hardware; toggles set_display_mode('list'/'zoom')
BID_CANCEL = 0x0F -- spec's Cancel button; NOT YET confirmed on hardware, see docs/implementing-sl-link.md
BID_GLOBAL = 0x09 -- spec's Global Button, confirmed on hardware 2026-09-20; toggles the config
	-- screen. The SL88 MK2's panel silk-screens it SETTINGS - spec names win here, see
	-- docs/implementing-sl-link.md section 6.
	-- MUST stay out of BUTTON_CC: it is the script's own UI button, not a mappable control (the
	-- harness asserts this). See docs/config-lua-history.md#the-config-screen-2026-09-20
BID_JOY_UP = 0x11
BID_JOY_LEFT = 0x12
BID_JOY_DOWN = 0x13
BID_JOY_RIGHT = 0x14
BID_JOY_MAIN = 0x15
BID_ZONE1_SEL = 0x04 -- SLButtonID.zone1SelectButton .. zone4SelectButton
BID_ZONE2_SEL = 0x05
BID_ZONE3_SEL = 0x06
BID_ZONE4_SEL = 0x07
BID_ZONE1_ENC = 0x00 -- SLButtonID.zone1EncoderButton .. zone4EncoderButton (the zone
BID_ZONE2_ENC = 0x01 -- encoders' PUSH buttons - a different namespace from the EID_ZONE*
BID_ZONE3_ENC = 0x02 -- rotation IDs below, which share the same 0x00-0x03 numbering
BID_ZONE4_ENC = 0x03 -- under a different itemType (IT_BUTTON vs IT_ENCODER)
BID_B_ENC = 0x0C -- SLButtonID.bEncoderButton
BID_A_ENC = 0x0B -- SLButtonID.aEncoderButton; toggles Master Volume mute (handle_a_encoder_button) -
	-- spec calls this reserved for USB audio, but A traffic reaches the host, see
	-- docs/implementing-sl-link.md §7

-- White LED ids (IT_LED), spec-named. Confirmed on hardware 2026-09-17 by sweeping every id; the full
-- table is in docs/implementing-sl-link.md §6. Only A and B have a ring LED - Zone 1-4 and the
-- joystick have none.
WLID_HOME = 0x07 -- Home button lamp (panel: ZOOM); see docs/implementing-sl-link.md section 6
WLID_GLOBAL = 0x08 -- Global button lamp (panel: SETTINGS); lit only while the config screen shows
WLID_A_ENC = 0x0A
WLID_B_ENC = 0x0B

-- Button press-event byte, e[9] of an IT_BUTTON frame
PRESS_SHORT = 0x01
PRESS_LONG = 0x02

-- Encoder IDs, matching the spec's encoder ID table.
EID_ZONE1 = 0x00
EID_ZONE2 = 0x01
EID_ZONE3 = 0x02
EID_ZONE4 = 0x03
EID_JOYSTICK = 0x04
EID_A = 0x05 -- drives the SL88's Master Volume directly (IT_MASTER_VOLUME), not a CC - see
	-- handle_sl_frame's IT_ENCODER branch. Deliberately absent from ENCODER_CC/CC_MAP.
EID_B = 0x06

-- MARK: - Phase 2 CC dispatch (every SL88 control emits a mappable CC)
--
-- One dedicated MIDI channel carries every gesture below (23 total, CC 51-74 skipping 64) so
-- MainStage can MIDI-Learn each one directly - no in-script patch-selection logic, which is dead:
-- MainStage's patchselector parser only runs when controller_midi_in returns falsy, so injected
-- MIDI (the old Q1a spike's approach) can never reach it. See docs/mainstage-integration.md for the
-- full table and the one-time mapping procedure.
CC_CHANNEL = 0x0F -- channel 16; nothing else is expected to be routed here
CC_STATUS = 0xB0 + CC_CHANNEL -- our CC channel's Control Change status byte - controller_midi_out's filter

CC_MAP = {
	ENC1_PRESS_SHORT = 51, ENC1_PRESS_LONG = 52,
	ENC2_PRESS_SHORT = 53, ENC2_PRESS_LONG = 54,
	ENC3_PRESS_SHORT = 55, ENC3_PRESS_LONG = 56,
	ENC4_PRESS_SHORT = 57, ENC4_PRESS_LONG = 58,

	ENC1_TURN = 59, ENC2_TURN = 60, ENC3_TURN = 61, ENC4_TURN = 62,

	ENCB_TURN = 63,
	-- 40-50 are unused: the whole joystick (tilts 40-47, press 48/49, ring 50) now drives patch
	-- selection with Bank Select + Program Change, which is not a CC at all. Left as gaps rather than
	-- reassigned: renumbering would break every learned mapping below them.
	-- 64 deliberately skipped (sustain CC; harmless on a channel nothing listens to, but not worth the
	-- ambiguity if it's ever routed anywhere).
	ENCB_PRESS_SHORT = 65, ENCB_PRESS_LONG = 66,

	SEL1_SHORT = 67, SEL1_LONG = 68,
	SEL2_SHORT = 69, SEL2_LONG = 70,
	SEL3_SHORT = 71, SEL3_LONG = 72,
	SEL4_SHORT = 73, SEL4_LONG = 74,
}

-- Human-readable name per CC_MAP key, for the controller_info() items generated below - shown in
-- MainStage's Layout mode. One entry per CC_MAP key, no more, no less (asserted by the harness).
CC_LABEL = {
	ENC1_PRESS_SHORT = 'Zone 1 Push', ENC1_PRESS_LONG = 'Zone 1 Push (long)',
	ENC2_PRESS_SHORT = 'Zone 2 Push', ENC2_PRESS_LONG = 'Zone 2 Push (long)',
	ENC3_PRESS_SHORT = 'Zone 3 Push', ENC3_PRESS_LONG = 'Zone 3 Push (long)',
	ENC4_PRESS_SHORT = 'Zone 4 Push', ENC4_PRESS_LONG = 'Zone 4 Push (long)',

	ENC1_TURN = 'Zone 1 Encoder', ENC2_TURN = 'Zone 2 Encoder',
	ENC3_TURN = 'Zone 3 Encoder', ENC4_TURN = 'Zone 4 Encoder',

	ENCB_TURN = 'B Encoder',
	ENCB_PRESS_SHORT = 'B Push', ENCB_PRESS_LONG = 'B Push (long)',

	SEL1_SHORT = 'Zone 1 Select', SEL1_LONG = 'Zone 1 Select (long)',
	SEL2_SHORT = 'Zone 2 Select', SEL2_LONG = 'Zone 2 Select (long)',
	SEL3_SHORT = 'Zone 3 Select', SEL3_LONG = 'Zone 3 Select (long)',
	SEL4_SHORT = 'Zone 4 Select', SEL4_LONG = 'Zone 4 Select (long)',
}

-- The continuous (Knob) gestures; every other CC_MAP key is a momentary Button.
CC_TURN = {
	ENC1_TURN = true, ENC2_TURN = true, ENC3_TURN = true, ENC4_TURN = true, ENCB_TURN = true,
}

-- BID -> { short, long } CC_MAP keys, for every button wired to a CC. The joystick is deliberately
-- absent: its tilts and press select patches directly (see JOYSTICK_NAV).
BUTTON_CC = {
	[BID_ZONE1_SEL] = { short = 'SEL1_SHORT', long = 'SEL1_LONG' },
	[BID_ZONE2_SEL] = { short = 'SEL2_SHORT', long = 'SEL2_LONG' },
	[BID_ZONE3_SEL] = { short = 'SEL3_SHORT', long = 'SEL3_LONG' },
	[BID_ZONE4_SEL] = { short = 'SEL4_SHORT', long = 'SEL4_LONG' },
	[BID_ZONE1_ENC] = { short = 'ENC1_PRESS_SHORT', long = 'ENC1_PRESS_LONG' },
	[BID_ZONE2_ENC] = { short = 'ENC2_PRESS_SHORT', long = 'ENC2_PRESS_LONG' },
	[BID_ZONE3_ENC] = { short = 'ENC3_PRESS_SHORT', long = 'ENC3_PRESS_LONG' },
	[BID_ZONE4_ENC] = { short = 'ENC4_PRESS_SHORT', long = 'ENC4_PRESS_LONG' },
	[BID_B_ENC]     = { short = 'ENCB_PRESS_SHORT', long = 'ENCB_PRESS_LONG' },
}

-- EID -> CC_MAP key, for every encoder wired to a CC. A is deliberately absent (see EID_A's comment
-- above).
ENCODER_CC = {
	[EID_ZONE1] = 'ENC1_TURN',
	[EID_ZONE2] = 'ENC2_TURN',
	[EID_ZONE3] = 'ENC3_TURN',
	[EID_ZONE4] = 'ENC4_TURN',
	[EID_B] = 'ENCB_TURN',
}

-- EID -> short display name, for the encoder value popup's label (see "MARK: - Encoder value
-- popup"). Same key set as ENCODER_CC, since only encoders wired to a CC ever show a popup.
ENCODER_NAME = {
	[EID_ZONE1] = 'ENC 1',
	[EID_ZONE2] = 'ENC 2',
	[EID_ZONE3] = 'ENC 3',
	[EID_ZONE4] = 'ENC 4',
	[EID_B] = 'ENC B',
}

-- Batch cap for one controller_midi_in return: 16 CCs (48 bytes, 3 bytes each) - well under
-- MainStage's measured ~78-byte injection ceiling, where an oversized array is discarded WHOLE
-- rather than truncated (rule 2 in the banner above). A fast encoder sweep or many simultaneous
-- button events would otherwise risk that ceiling; anything past the cap is left queued for the
-- next round rather than truncated into the array or dropped - see flush_pending_cc().
CC_BATCH_CAP = 16

-- Identification functions
ID_REQUEST = 0x00
ID_APPROVED = 0x01
ID_REJECTED = 0x02
ID_QUERY = 0x03

-- System functions
SYS_DEVICE_NOTIFICATION = 0x00 -- keepalive
SYS_LOGIN_CONFIRMATION = 0x01
SYS_LOGOUT_REQUEST = 0x02
SYS_LOGOUT_CONFIRMATION = 0x03
SYS_STANDBY = 0x04
SYS_RESTART = 0x05
SYS_LOGIN_RECALL = 0x06

-- Display functions
DISP_WRITE_TEXT = 0x00
DISP_CLEAR_SCREEN = 0x01
DISP_DRAW_RECT = 0x02
DISP_PLOT_BITMAP = 0x03

-- Internal bitmap library (Plot Bitmap draws a device-stored black-and-white icon, coloured
-- on-device from the message's own FG/BG - see docs/implementing-sl-link.md §5's Group/Icon
-- table for the rest of the library). Only the Knob group is used by this project; kept minimal
-- here rather than transcribing the whole appendix.
BMP_GROUP_KNOB = 0x00
BMP_KNOB_LEVELS = 13 -- icons 0x00-0x0C, a filling ring gauge: 0x00 empty, 0x0C full
BMP_ICON_W = 61
BMP_ICON_H = 54

-- Navigation group, 20x20 px. Icon order confirmed on hardware 2026-09-20 - exactly as the spec
-- states it: 0x00 left, 0x01 right, 0x02 left-right, 0x03 up-down, 0x04 rotate (round arrow),
-- 0x05 push, 0x06 apply, 0x07 cancel.
BMP_GROUP_NAV = 0x03
BMP_ICON_LEFTRIGHT = 0x02
BMP_ICON_UPDOWN = 0x03
BMP_ICON_ROTATE = 0x04
BMP_ICON_PUSH = 0x05
BMP_NAV_ICON_W = 20
BMP_NAV_ICON_H = 20

-- Text align / size
ALIGN_LEFT, ALIGN_CENTER, ALIGN_RIGHT = 0x00, 0x01, 0x02
SIZE_SMALL, SIZE_MEDIUM, SIZE_BIG = 0x00, 0x01, 0x02

-- Height of Write Text's opaque background box at each size, MEASURED on hardware 2026-09-20 with
-- Scripts/probe-text-metrics.swift. Every figure the spec gives (21/22/27/33) is too large; it
-- contradicts itself on medium besides. Re-measure with that probe if the font ever changes - see
-- docs/config-lua-history.md#write-text-box-heights-measured-2026-09-20.
TEXT_H_SMALL, TEXT_H_MEDIUM, TEXT_H_BIG = 18, 23, 27

-- The keyboard drops a host that goes quiet for ~5s; the app uses 3s.
KEEPALIVE_MS = 3000

-- MainStage tears the script down and re-initialises it mid-session, which re-derives instanceID via
-- derive_instance_start(instanceTag) (see docs/config-lua-history.md, "Per-instance starting id").
-- controller_finalize now sends a Logout Request to release the old id (see that function), but
-- delivery isn't guaranteed, so this wait/retry stays as the fallback for a stale registration
-- surviving anyway. Bumping the instance byte immediately on rejection would 'solve' it by
-- registering as a DIFFERENT app, silently losing the user's APP-list selection - do not do that
-- here. Wait comfortably longer than
-- the keyboard's ~5s host timeout so the stale registration expires, then retry the SAME id. NEVER
-- shorten this below that margin - rearm_timer()/request_quick_rearm() both special-case
-- STATE_REIDENTIFY_WAIT so nothing overwrites it early. See
-- docs/config-lua-history.md#reidentify_wait_ms-derivation.
REIDENTIFY_WAIT_MS = 6000

-- Retries of the SAME instanceID before falling back to bumping the instance byte. Bounded so a
-- GENUINE collision (the other script instance, loaded for the other USB-MIDI interface, alive and
-- rejecting us every time) doesn't wait forever.
MAX_SAME_ID_RETRIES = 2

-- Identification Request resends per identifying attempt, one per KEEPALIVE_MS tick, so a request
-- sent before MainStage's inbound path is live gets a later resend that actually gets its reply
-- delivered. 3 spans ~9s beyond the initial send - well past the SL88's ~5s host timeout - without
-- resending forever. See
-- docs/config-lua-history.md#identification-approval-and-rejection-are-lost-in-mainstages-init-window-2026-09-10.
MAX_IDENTIFY_RESENDS = 3

-- Recovers a STATE_ACTIVE session the SL88 has silently dropped from its APP list - observed on
-- hardware as Identification Query replies simply stopping while other traffic (encoder frames)
-- keeps arriving, with no logout/standby. Comfortably beyond the SL88's ~5s host timeout, since one
-- missed reply at KEEPALIVE_MS cadence is normal jitter, not a drop. See
-- docs/config-lua-history.md#recovering-a-silently-dropped-active-session-bounded-2026-09-13.
ACTIVE_QUERY_DROP_MS = 10000

-- Inbound-path equivalent of ACTIVE_QUERY_DROP_MS above, counting inbound FRAMES instead of elapsed
-- ms - see framesSinceQueryReply's declaration for why (ticks, and so ms accumulation, can be dead).
-- Deliberately higher than TIMER_WATCHDOG_FORCE_FRAMES so the cheaper local timer restart gets a
-- chance to fix a merely-dead clock before this drastic step (drop + re-identify) runs - see
-- docs/config-lua-history.md#dead-clock-instrumentation-and-two-recovery-backstops-2026-09-14.
ACTIVE_QUERY_DROP_FRAMES = 1200

-- Minimum quiet period between recovery attempts, so a recovery that does not stick cannot
-- re-trigger immediately and hammer the device - the suspected mechanism behind the freeze that got
-- the previous, unbounded version of this detector removed. Longer than the worst-case identify
-- cycle (MAX_IDENTIFY_RESENDS resends at KEEPALIVE_MS cadence, ~9s) so a fresh attempt is never cut
-- short by another trigger mid-cycle.
RECOVERY_COOLDOWN_MS = 15000

-- Consecutive recovery attempts allowed before giving up and logging it, rather than retrying
-- forever - a silent script is recoverable by hand; a script hammering the device is not.
MAX_RECOVERY_ATTEMPTS = 3

APP_NAME = 'MainStage'

-- Must be kept in step with the repo-root VERSION file; Tests/lua/harness.lua asserts the two
-- match, since /tmp/lua.log's controller_initialize line is the only way to tell which build
-- MainStage actually has loaded, and the installed copy has repeatedly drifted from the working
-- tree during development.
SCRIPT_VERSION = '2.7.0'

-- MARK: - Session state

STATE_IDLE = 'idle'
STATE_IDENTIFYING = 'identifying'
STATE_LISTED = 'listed' -- approved, waiting for the user to pick us on the SL88
STATE_ACTIVE = 'active'
STATE_STANDBY = 'standby'
STATE_REIDENTIFY_WAIT = 'reidentify_wait' -- rejected; waiting out REIDENTIFY_WAIT_MS before retrying the same id
STATE_LOGGED_OUT = 'logged_out' -- host-initiated logout; withholding the keepalive so the SL88 drops us, see request_logout()

state = STATE_IDLE

-- Silent keepalive-cadence ticks to sit out in STATE_LOGGED_OUT before resuming identification: at
-- KEEPALIVE_MS (~3s) per tick this comfortably clears the SL88's ~5s no-keepalive drop timeout.
LOGOUT_SILENT_TICKS = 3
logoutTicksLeft = 0

-- Two script instances (one per matched USB-MIDI interface) share one stdout; this tag lets log
-- lines tell them apart, and (below) seeds each instance's own starting instanceID. Mixes several
-- per-state values (object addresses, heap size) rather than one - lowers collision odds, does not
-- rule them out. See docs/config-lua-history.md.
local function addr_num(v)
	local hex = tostring(v):match('(%x+)$') or '0'
	return tonumber(hex:sub(-8), 16) or 0
end

function compute_instance_tag(a, b, c, d, memKB)
	local mixed = a + b * 31 + c * 97 + d * 193 + math.floor((memKB or 0) * 1000)
	return string.format('%06x', mixed % 0x1000000)
end

local coroutineAddr = 0
if coroutine and coroutine.create then
	coroutineAddr = addr_num(coroutine.create(function() end))
end

instanceTag = compute_instance_tag(addr_num({}), addr_num({}), addr_num(function() end),
	coroutineAddr, collectgarbage('count'))

-- Seeds this instance's starting instanceID from instanceTag so two concurrently-loaded instances,
-- or a re-initialised incarnation vs. its own still-registered ghost, don't both start at the same
-- id - see docs/config-lua-history.md, "Per-instance starting id". Collision odds are lowered, not
-- eliminated (instanceTag isn't collision-proof either); handle_identification_rejected's
-- retry/bump path is the backstop if two instances still land on the same id.
function derive_instance_start(tag)
	local n = tonumber(tag, 16) or 0
	return SL_INSTANCE_MIN + (n % (SL_INSTANCE_MAX - SL_INSTANCE_MIN + 1))
end

instanceID = derive_instance_start(instanceTag)
pendingMessages = {}

-- Phase 2 CC dispatch state - see the CC_MAP block above and queue_cc()/ flush_pending_cc() below.
pendingCC = {} -- control name (a CC_MAP key) -> pending value, coalesced
pendingDelta = {} -- control name -> accumulated SIGNED relative delta, for CC_TURN/JOY_ROTATE (see queue_relative_cc())
pendingCCOrder = {} -- insertion order of pendingCC's/pendingDelta's keys, for a deterministic batch
pendingReleases = {} -- controls whose 127 press already went out; queue their 0 release the NEXT
	-- round (see queue_momentary_cc())
encoderValue = { -- absolute 0-127 tracked value per encoder wired to a CC
	[EID_ZONE1] = 64, [EID_ZONE2] = 64, [EID_ZONE3] = 64, [EID_ZONE4] = 64,
	[EID_JOYSTICK] = 64, [EID_B] = 64,
}

-- Safe mid-scale starting point for masterVolume: not 0, and not 100 where a single click could
-- slam the audio board to full output. See
-- docs/config-lua-history.md#master-volume-read-reply-does-not-track-writes-2026-09-12.
MVOL_SEED_DEFAULT = 60

masterVolume = MVOL_SEED_DEFAULT -- 0-100 percentage: the value being SENT, changed ONLY by
	-- accumulated EID_A deltas (clamped 0-100) - never reseeded from masterVolumeRead. See
	-- docs/config-lua-history.md#master-volume-writes-take-effect-without-a-paired-read-probe-four-phase-result-2026-09-13.
masterVolumeRead = nil -- last VOL from an actual READ reply (07 00); diagnostic/logging only, never
	-- feeds masterVolume - see the anchor above.

-- A encoder button mute state. Not persisted (no io/os in the sandbox) - re-established each session
-- from the login READ reply's MUTE byte, falling back to this default (unmuted) if none arrives. See
-- docs/config-lua-history.md#a-encoder-button-mute-2026-09-14.
masterMuted = false

-- Idle ticks of A-encoder quiet before a gesture counts as settled - see check_mvol_settle(). Distinct
-- from the gesture-start reseed mechanism removed in the 2026-09-12 history entry; this one guarantees
-- the LAST write of a gesture lands, not the first. See
-- docs/config-lua-history.md#settle-resend-of-the-final-master-volume-write-2026-09-16.
MVOL_SETTLE_IDLE_TICKS = 2

-- idleTicks at the last EID_A tick, and whether a settle re-send/read is still owed for the gesture in
-- progress - set true by every EID_A tick, cleared by check_mvol_settle() once it fires.
mvolLastActivityIdleTick = 0
mvolSettlePending = false

-- Rate-limits the diagnostic READ a settle issues - a timerTicks gap (idleTicks freezes while messages
-- are queued, so it can't measure this). nil means none has been sent yet.
MVOL_SETTLE_READ_MIN_TICKS = 2
mvolLastSettleReadTick = nil

-- True from the moment a settle's diagnostic READ is queued until its reply is seen - lets the
-- MVOL_READ handler in handle_sl_frame log a match/mismatch against masterVolume for THIS read only.
awaitingSettleRead = false

-- Gates EVERY settriggertimer call (rule 6 in the banner above): true whenever a one-shot is
-- currently outstanding. rearm_timer() only calls settriggertimer when this is false, and sets it
-- true when it does; controller_timer_trigger() clears it at its own start (the one-shot has just
-- fired). Without this, controller_midi_in's per-note rearm_timer() call keeps cancelling and
-- restarting the pending timer while the user plays, so controller_timer_trigger never fires and
-- the SL88 drops the host after ~5s of silence. See
-- docs/config-lua-history.md#rule-6-notes-starve-the-clock.
--
-- Every OTHER direct settriggertimer call site must keep this flag honest: controller_initialize
-- (true - first arm), controller_timer_trigger's own top-of-function call (does NOT set this true -
-- confirmed on hardware to be a no-op from inside itself, see the SESSION CLOCK note above
-- controller_midi_in), and handle_identification_rejected's REIDENTIFY_WAIT_MS arm (true -
-- genuinely arms a timer).
timerPending = false

-- Inbound events seen since the last tick. Feeds the rearm_timer() watchdog that recovers from a
-- lost one-shot - see docs/config-lua-history.md#timer-watchdog-a-lost-one-shot-latches-timerpending-forever-2026-09-07.
framesSinceTick = 0

-- framesSinceTick value at which the rearm_timer() diagnostic last logged - lets it rate-limit itself
-- to once at first crossing plus once per TIMER_WATCHDOG_DIAG_EVERY_FRAMES after, instead of once per
-- frame. Reset to 0 wherever framesSinceTick itself resets.
watchdogDiagLastFrames = 0

-- Which interval the CURRENTLY OUTSTANDING one-shot (if timerPending is true) was armed at -
-- KEEPALIVE_MS, FLUSH_SOON_MS, POPUP_TICK_MS, or REIDENTIFY_WAIT_MS. Set at every settriggertimer
-- call site alongside timerPending. Read by request_quick_rearm() (below) to decide whether an
-- outstanding LONG interval should be shortened to FLUSH_SOON_MS. See
-- docs/config-lua-history.md#quick-rearm-2026-08-21.
timerArmedInterval = KEEPALIVE_MS

-- Retries left for the CURRENT instanceID - see handle_identification_rejected. Reset to
-- MAX_SAME_ID_RETRIES whenever a FRESH instanceID is adopted (controller_initialize, and the bump
-- fallback itself) or an identification succeeds; decremented on every same-id retry.
reidentifyRetriesLeft = MAX_SAME_ID_RETRIES

-- Resends left for the CURRENT identifying attempt - see start_identification() (which resets this)
-- and controller_timer_trigger's STATE_IDENTIFYING branch (which spends it).
identifyResendsLeft = MAX_IDENTIFY_RESENDS

-- True once the resend budget above is spent with no explicit APPROVED ever seen - the fallback
-- floor that reverts to pre-fix query-reply promotion rather than leaving the session silent
-- forever. See docs/config-lua-history.md#identification-approval-and-rejection-are-lost-in-mainstages-init-window-2026-09-10.
identifyFallback = false

-- Ms elapsed since the last Identification Query reply while STATE_ACTIVE - see
-- ACTIVE_QUERY_DROP_MS above. Accumulated from timerArmedInterval each tick (real elapsed time, not
-- a tick COUNT - tick pacing is not constant, see timerArmedInterval's own comment above). Reset to
-- 0 by any ID_QUERY reply (handle_sl_frame) and by entering STATE_ACTIVE (enter_active_session).
activeMsSinceQueryReply = 0

-- Frames elapsed since the last ID_QUERY reply while STATE_ACTIVE - the inbound-path counterpart to
-- activeMsSinceQueryReply, reset at the same three sites (that ID_QUERY reply, enter_active_session,
-- and a fired recovery attempt). A frame count is a coarse stand-in for elapsed time - it depends on
-- how much else is arriving, not a clock - but it is the only thing check_inbound_recovery() can
-- measure without a running tick. See ACTIVE_QUERY_DROP_FRAMES above.
framesSinceQueryReply = 0

-- Ms remaining before another recovery attempt is permitted (RECOVERY_COOLDOWN_MS above), and the
-- count of consecutive attempts made with no intervening return to STATE_ACTIVE. recoveryGivenUp
-- latches true once MAX_RECOVERY_ATTEMPTS is exhausted; the detector then stays silent for the rest
-- of this script instance. See controller_timer_trigger's recovery watchdog.
recoveryCooldownMs = 0
recoveryAttempts = 0
recoveryGivenUp = false

-- The one-display-message-per-tick pacing gate (rule 5 in the banner above). Set TRUE once per
-- timer tick, by controller_timer_trigger. flush_pending() may dequeue and emit a display message
-- (itemType IT_DISPLAY - this includes queue_sacrificial_redraw's trailing duplicate, which has no
-- regionId but is still IT_DISPLAY) only while this is true, and clears it the instant it does.
-- Protocol messages (identification, keepalive, logout - regionId nil, itemType
-- IT_SYSTEM/IT_IDENTIFICATION) and the trailing Identification Query are NEVER gated by this flag:
-- they go out on every flush regardless, because the query's reply is the only thing that re-arms
-- the one-shot timer (see the SESSION CLOCK note above controller_timer_trigger) - gating it too
-- would stall the session clock the moment any display work was queued.
--
-- Starts true so a display message queued before the very first timer tick can still go out on the
-- next available flush rather than waiting up to KEEPALIVE_MS. Without this gate, the SL88 silently
-- drops a display message that arrives while it is still painting the previous one - see
-- docs/config-lua-history.md#defect-a-the-ungated-flush-drained-at-round-trip-speed-not-timer-speed
-- for the hardware finding this fixes.
displayFlushReady = true

-- Same shape as displayFlushReady, but for the Master Volume WRITE only (never the READ, and never
-- other protocol messages) - granted once per tick by controller_timer_trigger, consumed by
-- flush_pending the moment it emits an MVOL_WRITE. Fixes bursty writes (several leaving in one tick,
-- then a gap) sounding stepped even though the device handles a dense, EVENLY SPACED stream fine -
-- see docs/config-lua-history.md#master-volume-write-pacing-one-per-tick-2026-09-13. Starts true for
-- the same reason displayFlushReady does.
mvolFlushReady = true

-- Count of MVOL_WRITE emissions THIS tick window that went out via the fast-turn bypass (not via
-- mvolFlushReady's own one grant) - reset to 0 each tick alongside mvolFlushReady. flush_pending()
-- lets a write tagged .fast (handle_sl_frame, a delta >= MVOL_FAST_DELTA_THRESHOLD) through once
-- mvolFlushReady itself is spent, as long as this is still below MVOL_FAST_WRITES_PER_TICK - 1; a
-- slow turn's write is never tagged, so it stays at exactly the pre-existing one-per-tick pace.
mvolFastWritesThisTick = 0

-- The per-tick permit EVERY queued message needs, on top of any class-specific flag above - granted
-- once per tick by controller_timer_trigger, consumed by flush_pending the moment any queued message
-- goes out. flush_pending runs once per tick PLUS once per inbound SL frame, so before this flag the
-- per-class flags bounded display and MVOL_WRITE to one per tick but let LED, MVOL_READ and protocol
-- messages leave 2ms apart within the same tick - which is what made one-shot messages vanish and
-- forced the 3x repeat workaround. See docs/config-lua-history.md#one-sl-message-per-tick-2026-09-17.
-- The fast-turn MVOL bypass is the single documented exception. Starts true for the same reason
-- displayFlushReady does.
slFlushReady = true

-- A full-screen Clear Screen plausibly takes the panel longer to paint than an ordinary text line.
-- Set to MODE_SWITCH_SETTLE_TICKS by flush_pending() the moment it emits a Clear Screen;
-- decremented by controller_timer_trigger, which withholds that tick's displayFlushReady grant
-- while this is nonzero - so the draws that follow a clear get roughly MODE_SWITCH_SETTLE_TICKS+1
-- tick periods of quiet instead of one. Protocol messages and the trailing Identification Query are
-- never gated by displayFlushReady at all, so the session clock keeps running through the settle
-- regardless.
--
-- Named as its own constant, not folded into FLUSH_SOON_MS, so the two can be retuned
-- independently. Lowered from 3 to 1 on 2026-08-29 - the double Clear Screen in flush_pending()
-- already fixed the delivery bug the raise to 3 was compensating for, so the settle no longer needs
-- to carry it. Confirmed on hardware 2026-08-29: Clear-Screen-to-first-pixel dead time dropped from
-- 8 ticks to 4, with no stale text on popups or the Zoom-button zoom<->list toggle. Revert ladder if
-- stale text or dropped lines ever reappear on a mode switch: try 2 next; 3 is the last known-good
-- value. See docs/config-lua-history.md#mode_switch_settle_ticks-lowered-to-1-2026-08-29.
MODE_SWITCH_SETTLE_TICKS = 1
displaySettleTicks = 0

-- Counts every display message queue_message() handles (append OR coalesced replace-in-place).
-- update_screen()/paint_screen() used to detect "did this paint queue anything real" by comparing
-- #pendingMessages before/after - that broke once coalescing can replace an existing entry without
-- changing the queue's length, so they diff this counter instead.
queuedDisplayOps = 0

-- What MainStage has loaded (from controller_select_patch), and the model for both display modes
-- below. currentConcert already existed before this feature and is reused rather than adding a
-- parallel concertName. 'zoom' stays the default (unchanged on load/restart); the Home button
-- (BID_HOME, see handle_home_button) toggles to 'list' and back. See
-- docs/config-lua-history.md#defect-a-the-ungated-flush-drained-at-round-trip-speed-not-timer-speed
-- for why 'list' used to be avoided (a display-pacing bug, since fixed - not anything about the
-- list screen itself).
displayMode = 'zoom' -- or 'list'

activeSetIndex = 0
activePatchIndex = 0
currentConcert = ''
setName = ''
patchName = ''

-- cursorIndex is an index into listRows (0-based, matching the pattern used throughout this file:
-- listRows[cursorIndex + 1] is the Lua-array entry). Phase 2 moves it independently of the active
-- patch (joystick navigation); Phase 1 has no wired input for that, so controller_select_patch
-- simply keeps it tracking whatever MainStage just loaded - see find_active_row_index().
cursorIndex = 0

-- BROWSE: the ring moves cursorIndex on its own, without changing patch - the joystick press commits it
-- (see handle_joystick_press). browsePending says a browsed patch is waiting; it also brings the tick
-- forward to POPUP_TICK_MS so check_browse_revert() can put the cursor back after a few seconds.
browsePending = false
browseLastActivityIdleTick = 0
scrollOffset = 0

-- The flat, interleaved patchlist, normalised: { label, isPatch, setIndex, patchIndex }, in the
-- SAME order MainStage's own patchlist array uses - this order IS the continuous list (sets and
-- patches interleaved exactly as MainStage displays them), so it is built with ipairs(), not
-- pairs(), in controller_select_patch: order is not just cosmetic here the way it was for the old
-- per-set filter.
listRows = {}

-- What the screen was last painted with, and when. Used to keep the display self-healing: see the
-- ID_QUERY handling in handle_sl_frame.
lastPaintedPatch = nil
lastPaintTick = -1

-- Repaint at least this often even when nothing changed, because the SL88 redraws its own screen
-- when the user picks an app from the APP list and there is no reliable signal for that (LOGIN
-- CONFIRMATION only arrives on a *fresh* login; if the keyboard still remembers us it never sends
-- one).
--
-- MUST be counted in IDLE ticks, not raw timer ticks - the tick rate is not constant, it drops to
-- FLUSH_SOON_MS while a repaint drains. Counting raw ticks makes 'N ticks' elapse fast mid-drain,
-- which repaints, which queues more work, which produces more fast ticks: a runaway repaint loop.
-- See Tests/lua/harness.lua's 'queue convergence' and 'repaint rate' checks, which fail if this
-- regresses.
REPAINT_EVERY_IDLE_TICKS = 10
idleTicks = 0

-- Every '[sllink] ...' print goes through here so each line carries instanceTag/instanceID - see
-- the instanceTag comment near its definition, above (Session state section).
function slog(msg)
	print('[sllink ' .. instanceTag .. '/' .. string.format('%02X', instanceID) .. '] ' .. msg)
end

-- MARK: - Outbound plumbing
--
-- A script can only send by returning MIDI from a callback. MainStage imposes a BYTE-LENGTH CEILING
-- on what it will emit (rule 2 in the banner): over it the whole array is discarded, not truncated.
-- Keep queued messages DISCRETE rather than pre-concatenated, and emit only as many whole messages per
-- flush as fit inside FLUSH_BUDGET; whatever is left over goes out on a following tick.
-- 78 is the largest size measured to deliver in THIS flush shape ([display, query]) - 78, 79 and 80 all
-- arrived, 2026-09-21 - and it also matches the original two-Write-Text measurement. Raised from 72,
-- which was a guess below that. See docs/config-lua-history.md#the-mainstage-byte-ceiling.
FLUSH_BUDGET = 78

-- Write Text's fixed wire overhead before the string itself: header+ids (7) + itemType+func (2) +
-- x/y/maxWidth (6) + align+size (2) + fg rgb (3) + bg rgb (3) + 0x00 terminator (1) + F7 (1) = 25.
WRITE_TEXT_OVERHEAD = 25

-- While output is still queued, ask for the next tick quickly rather than waiting a whole keepalive
-- period, so a repaint converges in a fraction of a second instead of one message every
-- KEEPALIVE_MS. This is the actual pace a repaint drains at, one display message per interval - it
-- only became true once flush_pending() started gating display messages behind displayFlushReady
-- (set once per timer tick); before that this constant was inert (see
-- docs/config-lua-history.md#defect-a-the-ungated-flush-drained-at-round-trip-speed-not-timer-speed).
--
-- Sweep: 50 -> 35 -> 25, one step per hardware run. 35 is confirmed on hardware (2026-08-29),
-- including while playing, and is the settled value. 25 was tried the same day, also while playing,
-- and the display sometimes dropped out - a failure mode the sweep plan did not predict (it was
-- watching for missing regions/stale tails, not playing dropouts). 25 is below the usable floor on
-- this hardware; the sweep concluded at 35. The exact mechanism is not yet pinned down - see
-- docs/config-lua-history.md#flush_soon_ms-retuned-to-25-backed-out-2026-08-29 for what the capture
-- does and doesn't show, and #flush_soon_ms-retuning-and-the-sweep-plan for the overall procedure.
FLUSH_SOON_MS = 35

-- Inbound events tolerated with timerPending latched true before rearm_timer() forces a re-arm
-- anyway, recovering from a one-shot MainStage never delivered. Only fires when has_pending() is
-- also true (rule 6 protection - see docs/config-lua-history.md#timer-watchdog-a-lost-one-shot-
-- latches-timerpending-forever-2026-09-07 for the measured healthy/failure distribution behind
-- both this value and that gate).
TIMER_WATCHDOG_FRAMES = 20

-- Second, ungated backstop: forces a re-arm at this frame count regardless of has_pending(), so a
-- clock that dies while the queue is EMPTY (TIMER_WATCHDOG_FRAMES above only fires when there is
-- queued output stuck behind it) is not stuck forever - see
-- docs/config-lua-history.md#dead-clock-instrumentation-and-two-recovery-backstops-2026-09-14. Must
-- stay well above anything ordinary play could reach before the next real tick fires on its own
-- (KEEPALIVE_MS, independent of MIDI traffic) - a threshold reached during a still-healthy pending
-- one-shot would revive rule 6 (re-arming cancels-and-restarts it, pushing the deadline back). 600 is
-- sized against the same margin TIMER_WATCHDOG_FRAMES used relative to its own healthy/failure split,
-- not measured hardware data for the empty-queue case (that data does not exist yet).
TIMER_WATCHDOG_FORCE_FRAMES = 600

-- Rate limit for the diagnostic log in rearm_timer() that fires while a one-shot looks lost but the
-- watchdog above is declining to act (frame count past TIMER_WATCHDOG_FRAMES yet has_pending() is
-- false, or still short of TIMER_WATCHDOG_FORCE_FRAMES) - the case that was previously silent and
-- ambiguous. rearm_timer() runs on every inbound MIDI event including notes, so this must not log
-- every frame; logs once at first crossing, then at most every 40 frames after (2x
-- TIMER_WATCHDOG_FRAMES - frequent enough to bound a multi-second stall in a handful of lines,
-- sparse enough that ordinary play never floods the log).
TIMER_WATCHDOG_DIAG_EVERY_FRAMES = 40

-- `regionId`, when given, is stashed as a NAMED field on the message table (Lua's `#`/ipairs only
-- see the integer-keyed byte sequence, so this rides along for free without disturbing
-- flush_pending's byte-for-byte indexing or drop_queued_display's `m[8]` itemType check). It is how
-- drop_queued_display() finds its way back to the `drawn[id]` memo entry a discarded message came
-- from - see that function's comment - and, below, how a newer paint for the same region COALESCES
-- with an older one still sitting in the queue instead of piling up behind it.
--
-- PER-REGION COALESCING: if the queue already holds a display message for this SAME regionId,
-- REPLACE it in place rather than appending a duplicate - see
-- docs/config-lua-history.md#per-region-coalescing-under-rapid-navigation for the hardware finding
-- this fixes. Position is preserved deliberately - the SL88 has no layers and paints strictly in
-- message order, so an update to one region must not reorder it relative to regions queued around
-- it, or draw order (e.g. a row's backing rect before its text) could invert.
--
-- Protocol messages (identification, keepalive, logout - regionId nil) are NEVER coalesced: they
-- append as always. Collapsing two Identification Queries, for instance, would drop one side of a
-- request/reply pair the session clock depends on (see the SESSION CLOCK note near
-- controller_timer_trigger).
function queue_message(msg, regionId)
	if regionId then
		msg.regionId = regionId
		queuedDisplayOps = queuedDisplayOps + 1
		for i = 1, #pendingMessages do
			if pendingMessages[i].regionId == regionId then
				pendingMessages[i] = msg
				return
			end
		end
	end
	table.insert(pendingMessages, msg)
end

-- Removes a single pending queue entry by regionId, without touching drawn[] - unlike
-- drop_queued_display() below, which drops every display message. Used when a region must be
-- forced back to the tail instead of coalescing at its old position - see draw_popup_knob.
-- Drops every queued Identification Request. They carry no regionId (they must never coalesce), so
-- drop_queued_region cannot reach them - see handle_identification_approved for why they must go.
function drop_queued_identification_requests()
	local keep = {}
	for i = 1, #pendingMessages do
		local m = pendingMessages[i]
		if not (m[8] == IT_IDENTIFICATION and m[9] == ID_REQUEST) then
			keep[#keep + 1] = m
		end
	end
	pendingMessages = keep
end

function drop_queued_region(regionId)
	for i = 1, #pendingMessages do
		if pendingMessages[i].regionId == regionId then
			table.remove(pendingMessages, i)
			return
		end
	end
end

-- Queues `count` fresh messages from `builder()`, one call per copy, all with regionId nil so
-- PER-REGION COALESCING (queue_message's own comment above) never collapses them back into one -
-- that would defeat the whole point of repeating a one-shot write. `builder` is called once per
-- copy (not shared) to mirror set_display_mode's double-Clear-Screen idiom.
function queue_repeated(builder, count)
	for i = 1, count do
		queue_message(builder())
	end
end

function has_pending()
	return #pendingMessages > 0
end

-- Counts every display message flush_pending() actually emits (not merely queues). Screen content
-- proves what was PAINTED; it cannot distinguish a message that was sent and dropped by the
-- keyboard from one that was never sent at all - see the alternating-row-loss finding at the
-- displayMode declaration above. This is the observation path that tells the two apart.
flushCounter = 0

-- Emits whole messages up to the budget. `includeQuery` appends an Identification Query and
-- reserves room for it inside the budget: its reply is the only thing that re-arms the one-shot
-- timer (see the SESSION CLOCK note above controller_midi_in), so a flush carrying no query can
-- stall the session clock. A Master Volume write used to go out unpaired (dropping the query) -
-- reverted, it was not what made Master Volume work and it starved the clock during an A-encoder
-- sweep - see docs/config-lua-history.md#master-volume-writes-go-out-unpaired-2026-09-10.
function flush_pending(includeQuery)
	local out = {}
	local query = includeQuery and msg_identification_query() or nil
	local reserve = query and #query or 0
	-- A queued message may tag itself with an .outport field to send on a port other than SL_PORT
	-- (nothing currently does - the Phase 2 CC batch goes out through flush_pending_cc, not this path,
	-- and is outport-less by design). General escape hatch: an ordinary queued message leaves .outport
	-- nil and keeps going to SL_PORT. A MIDIPacketList return can only carry one outport per call, so
	-- this is set from the single message dequeued below only.
	local outPort = SL_PORT

	-- Exactly ONE queued message per flush, always paired with the query - the only shape ([display,
	-- query]) ever confirmed reliable on hardware. See
	-- docs/config-lua-history.md#the-display-query-flush-shape.
	--
	-- A display message (itemType IT_DISPLAY) may only be dequeued here while displayFlushReady is
	-- true, and an MVOL_WRITE only while mvolFlushReady is true - each clears its own flag the moment
	-- it goes out (rule 5 in the banner; mvolFlushReady mirrors it, see that flag's declaration). Every
	-- other message (identification, keepalive, logout, MVOL_READ) is never gated - it dequeues every
	-- flush regardless.
	--
	-- If the head message can't go out this flush (paced and its flag is false), scan forward for the
	-- FIRST message that isn't itself paced-and-blocked and let it jump the queue instead, removed from
	-- its own position with everything else left untouched - otherwise a keepalive (or a ready display
	-- message) queued behind a blocked one would starve. See
	-- docs/config-lua-history.md#defect-b-a-keepalive-stuck-behind-a-display-backlog. Paced messages
	-- never reorder relative to OTHER paced messages of the same kind - only an unblocked message can
	-- jump ahead of ones still waiting on their flag. Still at most one queued message per flush, still
	-- paired with the query below.
	local function is_fast_bypass(msg)
		-- Fast-turn bypass: a write tagged .fast (handle_sl_frame) may still go out once
		-- mvolFlushReady is spent, up to MVOL_FAST_WRITES_PER_TICK - 1 of them this tick window - see
		-- mvolFastWritesThisTick. The one exception to the one-message-per-tick rule below.
		return msg[8] == IT_MASTER_VOLUME and msg[9] == MVOL_WRITE
			and msg.fast and mvolFastWritesThisTick < MVOL_FAST_WRITES_PER_TICK - 1
	end

	local function is_paced_and_blocked(msg)
		if not slFlushReady then return not is_fast_bypass(msg) end
		if msg[8] == IT_DISPLAY then return not displayFlushReady end
		if msg[8] == IT_MASTER_VOLUME and msg[9] == MVOL_WRITE then
			return not (mvolFlushReady or is_fast_bypass(msg))
		end
		return false
	end

	-- The keepalive takes its turn in queue order like everything else. slFlushReady caps the drain at
	-- one message per tick, but a non-empty queue rearms the timer at FLUSH_SOON_MS, so a keepalive
	-- behind a full repaint waits milliseconds, not the ~5s that would cost us the APP list (rule 6,
	-- docs/config-lua-history.md#the-unconditional-keepalive).
	local index, m = nil, nil
	if #pendingMessages > 0 then
		local head = pendingMessages[1]
		if not is_paced_and_blocked(head) then
			index, m = 1, head
		else
			for i = 2, #pendingMessages do
				if not is_paced_and_blocked(pendingMessages[i]) then
					index, m = i, pendingMessages[i]
					break
				end
			end
		end
	end

	if m ~= nil and #m + reserve <= FLUSH_BUDGET then
		local isDisplay = (m[8] == IT_DISPLAY)
		local isMvolWrite = (m[8] == IT_MASTER_VOLUME and m[9] == MVOL_WRITE)
		table.remove(pendingMessages, index)
		for i = 1, #m do out[#out + 1] = m[i] end
		if m.outport then outPort = m.outport end
		if isDisplay then
			displayFlushReady = false
			-- CLEAR SCREEN SETTLE GUARD: see displaySettleTicks' declaration. A Clear Screen going out
			-- earns the next draw MODE_SWITCH_SETTLE_TICKS extra ticks of quiet on top of the ordinary
			-- one-per-tick pacing.
			if m[9] == DISP_CLEAR_SCREEN then displaySettleTicks = MODE_SWITCH_SETTLE_TICKS end
		elseif isMvolWrite then
			-- Spend the base per-tick grant first; only count against the fast-turn budget once it's
			-- gone, so a slow turn (never tagged .fast) is completely unaffected.
			if mvolFlushReady then
				mvolFlushReady = false
			else
				mvolFastWritesThisTick = mvolFastWritesThisTick + 1
			end
		end
		-- Spend the shared one-message-per-tick permit. Later fast-turn writes in the same tick don't
		-- need it back: with it spent they go out via is_paced_and_blocked's fast-bypass branch.
		slFlushReady = false
		flushCounter = flushCounter + 1
		-- `tick=` ties this FLUSH to controller_timer_trigger's tick print, so a captured log reads as
		-- 'tick N emitted region R, depth D' - flushes can also happen off-tick (inbound-frame flushes
		-- in controller_midi_in, controller_select_patch); a FLUSH whose tick= repeats the previous
		-- FLUSH's is exactly one of those.
		-- Protocol messages (regionId nil) get their bytes dumped too - they're rare enough not to
		-- flood the log, and distinguishing e.g. a keepalive from a Master Volume read needs the bytes.
		local msgSuffix = m.regionId == nil and (' msg=' .. dump_bytes(m)) or ''
		slog('FLUSH #' .. flushCounter ..
			' tick=' .. timerTicks ..
			' regionId=' .. tostring(m.regionId or 'none') ..
			' bytes=' .. #m ..
			' queueDepthAfter=' .. #pendingMessages ..
			msgSuffix)
	end

	if query then
		for i = 1, #query do out[#out + 1] = query[i] end
	end

	if #out == 0 then return nil end
	return { midi = out, outport = outPort }
end


-- MARK: - Phase 2 CC dispatch (queue/emit; see the CC_MAP block near the top)

-- Coalesces into the pending-CC table, keyed by CONTROL (a CC_MAP key), not by CC number. A second
-- call for the same control before it flushes REPLACES the pending value rather than queuing a
-- duplicate - this is what lets a fast button re-press collapse to one CC per control instead of one
-- per event (see controller_midi_in's return path). For the CC_TURN/JOY_ROTATE relative encoders, use
-- queue_relative_cc() instead - replacing an unflushed delta would lose motion.
function queue_cc(control, value)
	if value < 0 then value = 0 elseif value > 127 then value = 127 end
	if pendingCC[control] == nil then
		pendingCCOrder[#pendingCCOrder + 1] = control
	end
	pendingCC[control] = value
end

-- Companion to queue_cc for relative controls (CC_TURN/JOY_ROTATE): ACCUMULATES the signed delta
-- instead of replacing, so two ticks for the same control before a flush sum rather than lose the
-- first tick's motion. Left in signed space - clamped and Relative2C-encoded only at emit time, in
-- flush_pending_cc().
function queue_relative_cc(control, delta)
	if pendingDelta[control] == nil then
		pendingCCOrder[#pendingCCOrder + 1] = control
	end
	pendingDelta[control] = (pendingDelta[control] or 0) + delta
end

-- Buttons read as momentary in MainStage (127 then 0), but queue_cc's own per-control coalescing
-- means two queue_cc calls back to back for the same control would just leave the release (0)
-- pending - the press would never reach a batch at all. So the release is NOT queued immediately
-- behind the press: this only queues 127 now and remembers the control in pendingReleases;
-- controller_midi_in queues each pending release's 0 at the START of the NEXT round (the next
-- inbound SL frame - in practice usually within one Identification Query/reply round-trip, since
-- that heartbeat keeps inbound SL frames arriving even with no further user input), before handling
-- that frame's own event. Simpler than threading a delay through the batching path, and 'shortly
-- after' is all momentary behaviour needs.
function queue_momentary_cc(control)
	queue_cc(control, 127)
	pendingReleases[#pendingReleases + 1] = control
end

function build_cc_message(control, value)
	return { 0xB0 + CC_CHANNEL, CC_MAP[control], value }
end

-- Batches every pending CC into ONE { midi = {...} } table (outport-less, like the old spike
-- injection this replaces) and clears what it emits. Capped at CC_BATCH_CAP controls (CC_BATCH_CAP
-- * 3 bytes) - see that constant's comment for why. A control past the cap is left in
-- pendingCC/pendingCCOrder for the next round rather than being dropped or truncated into an
-- oversized array.
function flush_pending_cc()
	local out = {}
	local emitted = 0
	local remaining = {}
	local emittedCCs = {}
	for i = 1, #pendingCCOrder do
		local control = pendingCCOrder[i]
		if emitted < CC_BATCH_CAP then
			local value = pendingCC[control]
			if value ~= nil then
				pendingCC[control] = nil
			else
				-- Relative control: clamp the accumulated signed total, then Relative2C-encode (two's
				-- complement) only now - see queue_relative_cc(). A net-zero total (e.g. +1 then -1 before
				-- this flush) emits nothing and does not occupy a batch slot.
				local total = pendingDelta[control]
				pendingDelta[control] = nil
				if total > 63 then total = 63 elseif total < -63 then total = -63 end
				if total ~= 0 then value = total % 128 end
			end
			if value ~= nil then
				local msg = build_cc_message(control, value)
				for j = 1, #msg do out[#out + 1] = msg[j] end
				emittedCCs[#emittedCCs + 1] = CC_MAP[control] .. '=' .. value
				emitted = emitted + 1
			end
		else
			remaining[#remaining + 1] = control
		end
	end
	pendingCCOrder = remaining
	slog('CC batch: ' .. emitted .. ' CC(s) [' .. table.concat(emittedCCs, ', ') .. '], ' .. #out .. ' bytes' ..
		(#remaining > 0 and (', ' .. #remaining .. ' deferred to next round') or ''))
	-- Nothing emitted (every queued relative delta netted to zero): return nil, NOT { midi = {} }.
	-- An empty table swallows the inbound event and costs the round its SL flush for no MIDI at all -
	-- see docs/mainstage-device-scripts.md section 4's return-value table.
	if pendingProgram ~= nil then
		if pendingBank ~= nil then
			-- MSB then LSB, then the PC - the order Apple's documentation requires.
			out[#out + 1] = 0xB0 + CC_CHANNEL
			out[#out + 1] = 0x00
			out[#out + 1] = math.floor(pendingBank / 128)
			out[#out + 1] = 0xB0 + CC_CHANNEL
			out[#out + 1] = 0x20
			out[#out + 1] = pendingBank % 128
			pendingBank = nil
		end
		out[#out + 1] = 0xC0 + CC_CHANNEL
		out[#out + 1] = pendingProgram
		pendingProgram = nil
	end
	if #out == 0 then return nil end
	return { midi = out }
end


-- MARK: - Message builders

function sl_header()
	local m = {}
	for i = 1, #SL_HEADER do m[i] = SL_HEADER[i] end
	m[#m + 1] = SL_HOST_ID
	m[#m + 1] = instanceID
	return m
end

-- ASCII-clamps to the SLMK2 font range and 0x00-terminates, per the spec's text field encoding.
function append_text(msg, text, maxLength)
	if text ~= nil then
		local limit = math.min(#text, maxLength or 32)
		for i = 1, limit do
			local b = string.byte(text, i)
			if b < 0x20 or b > 0x80 then b = 0x20 end
			table.insert(msg, b)
		end
	end
	table.insert(msg, 0x00)
end

-- Known non-ASCII units MainStage's locale-formatted valueString can contain, substituted before
-- the ASCII strip below runs - see docs/config-lua-history.md#controller_midi_out-reports-real-parameter-values-with-a-screen-control-2026-09-17.
UNIT_SUBSTITUTIONS = { ['\xE3\x8F\x88'] = 'dB' } -- U+33C8 SQUARE DB, 3 UTF-8 bytes

-- Substitutes known unit glyphs, then DROPS any remaining byte outside 0x20-0x80 (rather than
-- letting append_text's own per-byte clamp turn a multi-byte glyph into a run of spaces).
function sanitize_value_string(s)
	if s == nil then return nil end
	for glyph, ascii in pairs(UNIT_SUBSTITUTIONS) do
		s = s:gsub(glyph, ascii)
	end
	local out = {}
	for i = 1, #s do
		local b = string.byte(s, i)
		if b >= 0x20 and b <= 0x80 then out[#out + 1] = string.char(b) end
	end
	return table.concat(out)
end

-- Splits a value >127 into (msb, lsb), per the spec's 7-bit MIDI payload encoding.
function append_msb_lsb(msg, value)
	if value == nil or value < 0 then value = 0 end
	table.insert(msg, math.floor(value / 128) % 128)
	table.insert(msg, value % 128)
end

-- 8-bit RGB -> the 7-bit-per-channel form every SL Link colour field uses (the spec's colour fields
-- drop the least significant bit).
function append_rgb(msg, r, g, b)
	table.insert(msg, math.floor(r / 2))
	table.insert(msg, math.floor(g / 2))
	table.insert(msg, math.floor(b / 2))
end

function msg_identification_request()
	local m = sl_header()
	table.insert(m, IT_IDENTIFICATION)
	table.insert(m, ID_REQUEST)
	append_text(m, APP_NAME, 32)
	table.insert(m, SL_END)
	return m
end

-- Sent purely to elicit a reply and thereby keep the session clock running - see
-- controller_timer_trigger.
function msg_identification_query()
	local m = sl_header()
	table.insert(m, IT_IDENTIFICATION)
	table.insert(m, ID_QUERY)
	table.insert(m, SL_END)
	return m
end

-- flush_pending only ever dequeues ONE message per flush, and only if it fits alongside the
-- Identification Query it always reserves room for (see flush_pending's comment) - a message that
-- never fits is never sent AND never dropped, which jams the queue and stalls the session clock
-- forever. append_text used to allow up to 96 characters with no relation to that budget, so a
-- ~48-char patch name was enough to hang the script.
--
-- This cap is NOT the rule-4 'never truncate' violation: Max Width still does the *visual*
-- truncation in pixels, with its own '...' for anything that doesn't fit on screen, regardless of
-- how many characters were sent. This is a transport limit only, computed from the query builder
-- itself (not hand-counted) so it stays correct if either message's shape ever changes.
TEXT_STRING_CAP = FLUSH_BUDGET - #msg_identification_query() - WRITE_TEXT_OVERHEAD

function msg_system(func)
	local m = sl_header()
	table.insert(m, IT_SYSTEM)
	table.insert(m, func)
	table.insert(m, SL_END)
	return m
end

-- vol is 0-100 (a percentage, not 0-127) - single byte, no msb/lsb split. MUTE is omitted
-- deliberately so a volume write never touches mute status - see docs/implementing-sl-link.md §6.
function msg_master_volume_write(vol)
	local m = sl_header()
	table.insert(m, IT_MASTER_VOLUME)
	table.insert(m, MVOL_WRITE)
	table.insert(m, vol)
	table.insert(m, SL_END)
	return m
end

function msg_master_volume_read()
	local m = sl_header()
	table.insert(m, IT_MASTER_VOLUME)
	table.insert(m, MVOL_READ)
	table.insert(m, SL_END)
	return m
end

-- A write that also carries MUTE explicitly - unlike msg_master_volume_write(), which always omits
-- it. Used by the A button: pass MVOL_IGNORE_VOL to change mute alone, or a real vol to change both
-- at once (the LONG-press reset). See docs/implementing-sl-link.md §6.
function msg_master_volume_mute_write(vol, muted)
	local m = sl_header()
	table.insert(m, IT_MASTER_VOLUME)
	table.insert(m, MVOL_WRITE)
	table.insert(m, vol)
	table.insert(m, muted and 1 or 0)
	table.insert(m, SL_END)
	return m
end

-- White LED write (IT_LED): on/off only, no colour or brightness - see docs/implementing-sl-link.md §6.
-- MainStage reports a parameter's colour as r/g/b FLOATS 0.0-1.0 (confirmed on hardware, see
-- docs/config-lua-history.md#controller_midi_out-reports-real-parameter-values-with-a-screen-control-2026-09-17),
-- while the wire is 7-bit per channel. Scale, do not halve: the halving rgb7() in the spec's examples
-- converts 0-255 ints, which is not what arrives here. Clamped because an out-of-range byte would have
-- its MSB set, which is illegal in a MIDI data byte and drops the whole message.
function rgb7(c)
	local v = math.floor((c or 0) * 127 + 0.5)
	if v < 0 then v = 0 elseif v > 127 then v = 127 end
	return v
end

-- RGB ring LED, one of the four zone encoders. r/g/b/brightness are already 7-bit here - callers
-- convert MainStage floats with rgb7() above.
function msg_rgb_led(lid, r, g, b, brightness)
	local m = sl_header()
	table.insert(m, IT_RGB_LED)
	table.insert(m, lid)
	table.insert(m, r)
	table.insert(m, g)
	table.insert(m, b)
	table.insert(m, brightness)
	table.insert(m, SL_END)
	return m
end

function msg_white_led(wlid, on)
	local m = sl_header()
	table.insert(m, IT_LED)
	table.insert(m, wlid)
	table.insert(m, on and 1 or 0)
	table.insert(m, SL_END)
	return m
end

function msg_clear_screen(r, g, b)
	local m = sl_header()
	table.insert(m, IT_DISPLAY)
	table.insert(m, DISP_CLEAR_SCREEN)
	append_rgb(m, r, g, b)
	table.insert(m, SL_END)
	return m
end

function msg_write_text(text, x, y, maxWidth, align, size, fr, fg, fb, br, bg, bb)
	local m = sl_header()
	table.insert(m, IT_DISPLAY)
	table.insert(m, DISP_WRITE_TEXT)
	append_msb_lsb(m, x)
	append_msb_lsb(m, y)
	append_msb_lsb(m, maxWidth)
	table.insert(m, align)
	table.insert(m, size)
	append_rgb(m, fr, fg, fb)
	append_rgb(m, br, bg, bb)
	if text ~= nil and #text > TEXT_STRING_CAP then
		slog('msg_write_text: clamping "' .. text .. '" (' .. #text ..
			' chars) to ' .. TEXT_STRING_CAP .. ' chars - transport limit (see' ..
			' TEXT_STRING_CAP), not a visual-truncation change; Max Width still' ..
			' does its own "..." truncation on screen.')
	end
	append_text(m, text, TEXT_STRING_CAP)
	table.insert(m, SL_END)
	return m
end

function msg_draw_rect(x, y, w, h, r, g, b)
	local m = sl_header()
	table.insert(m, IT_DISPLAY)
	table.insert(m, DISP_DRAW_RECT)
	append_msb_lsb(m, x)
	append_msb_lsb(m, y)
	append_msb_lsb(m, w)
	append_msb_lsb(m, h)
	append_rgb(m, r, g, b)
	table.insert(m, SL_END)
	return m
end

-- Payload order per the spec's Plot Bitmap message: X(2) Y(2) GroupIdx IconIdx FG(3)
-- BG(3) - groupIndex/iconIndex are single 7-bit bytes, NOT msb/lsb split (unlike x/y/w/h above).
function msg_plot_bitmap(x, y, groupIndex, iconIndex, fr, fg, fb, br, bg, bb)
	local m = sl_header()
	table.insert(m, IT_DISPLAY)
	table.insert(m, DISP_PLOT_BITMAP)
	append_msb_lsb(m, x)
	append_msb_lsb(m, y)
	table.insert(m, groupIndex)
	table.insert(m, iconIndex)
	append_rgb(m, fr, fg, fb)
	append_rgb(m, br, bg, bb)
	table.insert(m, SL_END)
	return m
end

-- MARK: - Per-region memoization
--
-- Ported from this project's Swift implementation (see the display layer on archive/swift-app):
-- draw_text/draw_rect remember the full parameter tuple they last sent for a given caller-supplied
-- id, and queue nothing when a call repeats it unchanged. Mandatory, not an optimisation - at one
-- message per ~100ms flush, a full list repaint costs about a second; without this every self-heal
-- repaint would cost the same again.
--
-- NON-OVERLAP RULE (same rule the Swift display layer documents): every region id must own screen pixels
-- that no other id draws. A change to one id's memo does not invalidate any other id, so a caller
-- that layers draws - e.g. a filled rect under text - will corrupt the screen the moment only the
-- bottom layer changes and the top layer is skipped as unchanged; the device has no concept of
-- layers, it paints strictly in message order. A caller that cannot avoid overlap must clear the
-- shared ids' drawn[] entries together so they resend as one unit - used by draw_popup_erase()
-- below, and previously by the zoom screen's zset/zname (maxWidth=0, via the since-removed
-- draw_text_with_erase()) - see
-- docs/config-lua-history.md#zoom-screen-centring-moved-to-the-device-2026-08-29.

drawn = {}

function invalidate_all()
	drawn = {}
end

function tuple_equal(a, b, n)
	if a == nil then return false end
	for i = 1, n do
		if a[i] ~= b[i] then return false end
	end
	return true
end

-- Returns true when it actually queued a message, false when memoization skipped it as unchanged -
-- callers that need to know whether a redraw really landed (e.g. draw_popup_knob, below) use this
-- instead of re-deriving it from drawn[id] themselves.
function draw_text(id, text, x, y, maxWidth, align, size, fr, fg, fb, br, bg, bb)
	local t = { text, x, y, maxWidth, align, size, fr, fg, fb, br, bg, bb }
	if tuple_equal(drawn[id], t, #t) then return false end
	drawn[id] = t
	queue_message(msg_write_text(text, x, y, maxWidth, align, size, fr, fg, fb, br, bg, bb), id)
	return true
end

function draw_rect(id, x, y, w, h, r, g, b)
	local t = { x, y, w, h, r, g, b }
	if tuple_equal(drawn[id], t, #t) then return false end
	drawn[id] = t
	queue_message(msg_draw_rect(x, y, w, h, r, g, b), id)
	return true
end

-- Like draw_text/draw_rect, but for Plot Bitmap. A bitmap fully replaces the pixels beneath it -
-- no alpha channel (docs/implementing-sl-link.md §5) - so it is self-clearing the same way a
-- Write Text redraw is, and satisfies the non-overlap rule above on its own.
function draw_bitmap(id, x, y, groupIndex, iconIndex, fr, fg, fb, br, bg, bb)
	local t = { x, y, groupIndex, iconIndex, fr, fg, fb, br, bg, bb }
	if tuple_equal(drawn[id], t, #t) then return false end
	drawn[id] = t
	queue_message(msg_plot_bitmap(x, y, groupIndex, iconIndex, fr, fg, fb, br, bg, bb), id)
	return true
end

-- MARK: - Screen
--
-- Each element is queued as its own message and delivered across consecutive flushes, because
-- MainStage will not emit more than ~78 bytes at once (see FLUSH_BUDGET). Concatenating a whole
-- repaint is exactly what produced a completely black screen in earlier attempts.
--
-- No manual string truncation: the SL Link spec sets no text-length limit, and Max Width already
-- truncates visually in pixels, appending '...' when needed. Let the keyboard do it.

SCREEN_WIDTH = 320
SCREEN_HEIGHT = 240
TEXT_X = 8
TEXT_MAXW = SCREEN_WIDTH - (2 * TEXT_X)

ROW_COUNT = 8
ROW_Y0 = 30
ROW_PITCH = 26
ROW_X = 8
ROW_MAXW = 304

-- The BOTTOM row is narrower than the rest, carving a right-hand gutter for the navigation icons: with 8
-- rows the last one occupies y=212-230, so the icons cannot go below it and sit beside it instead. Only
-- row ROW_COUNT-1 is shortened, so the seven rows above keep the full width for patch names - see
-- draw_list_row(). The active-patch highlight is therefore narrower on the bottom row than elsewhere.
ROW_LAST_MAXW = 198

-- Navigation icons, bottom right of the list screen, in the order the gestures escalate: the tilt pairs
-- select a patch or a set outright, the rotate icon says the ring browses, and the push icon lights when a
-- browsed patch is waiting to be committed. 20px wide on a 26px pitch, right edge at 312 to match ROW_X's
-- margin. They own the gutter ROW_LAST_MAXW leaves, so nothing else draws those pixels (rule 4). Colour,
-- not presence, carries the state - same region id and pixels either way, so nothing needs erasing.
NAV_ICON_Y = 214
NAV_UPDOWN_X = 214
NAV_LEFTRIGHT_X = 240
NAV_RING_X = 266
NAV_PUSH_X = 292
-- White for an available gesture, grey for the push icon while nothing is browsed. Amber was tried on
-- hardware and swapped for white (2026-09-21); amber now means ONLY the active patch.
NAV_ICON_DIM = { 60, 60, 70 }
NAV_ICON_LIT = { 255, 255, 255 }

-- The same tilt pair on the zoom screen, level with the n/N counter. The counter's box is narrowed
-- SYMMETRICALLY about the screen centre (ZOOM_POS_X + ZOOM_POS_W / 2 == SCREEN_WIDTH / 2) so its digits
-- stay where they were while the icons take the right-hand end - the harness asserts both.
ZOOM_NAV_Y = 210
ZOOM_NAV_UPDOWN_X = 266
ZOOM_NAV_LEFTRIGHT_X = 292
ZOOM_POS_X = 58
ZOOM_POS_W = 204

-- Max Width TRUNCATION is UNRELIABLE at SIZE_BIG - confirmed on hardware: a long patch name at
-- maxWidth=304 rendered as a single letter followed by '...'. So the zoom screen's patch name is
-- pre-truncated in Lua (truncate_text(), paint_zoom_screen()) before it ever reaches the device -
-- belt-and-braces so the device's own (broken) truncation never gets a chance to fire. See
-- docs/config-lua-history.md#max-width-truncation-broken-at-size_big. This is a DIFFERENT device
-- feature from Max Width CENTERING (ALIGN_CENTER within a real, non-zero maxWidth), which IS trusted
-- for zset/zname - see paint_zoom_screen()'s comment and
-- docs/config-lua-history.md#zoom-screen-centring-moved-to-the-device-2026-08-29. Confirmed working
-- at SIZE_SMALL too (see
-- docs/config-lua-history.md#settled-facts-max-width-and-the-write-text-background-box), which is
-- why every list row below uses a real, non-zero maxWidth instead. Do not switch zname/zset
-- TRUNCATION back to trusting the device without re-confirming on hardware first.
--
-- HARDWARE-CALIBRATED BY EYE, not measured from real glyph widths. Retune by eye against a name a
-- couple of characters either side of this constant if the geometry below changes (screen width, X
-- margins, font).
BIG_MAX_CHARS = 27

-- Same idea, for SIZE_MEDIUM text (only zset uses this - znext draws SIZE_SMALL with a trusted Max
-- Width instead, needing no character-count truncation). Also eye-calibrated; retune the same way
-- as BIG_MAX_CHARS.
-- WARNING, unverified and probably too high: 35 characters at SIZE_MEDIUM overflowed a 304px box on
-- hardware (2026-09-21) and the device's own truncation mangled it to 'Jose..' - so anything near 36 is
-- unsafe at this width. zset survives only because set names are usually short. Measure with
-- Scripts/probe-text-metrics.swift before relying on it.
MEDIUM_MAX_CHARS = 36

-- truncate_text() cuts zname/zset to exactly these character counts before they are drawn, even
-- though both also draw at a real, non-zero maxWidth now (paint_zoom_screen()) - belt-and-braces so
-- the device's own Max Width truncation, confirmed broken at SIZE_BIG, never gets a chance to fire.
-- znext no longer calls truncate_text() - see MEDIUM_MAX_CHARS's comment above. TEXT_STRING_CAP is
-- msg_write_text's own hard transport clamp (a DIFFERENT limit - see that constant's comment); assert
-- the relationship rather than assume it, since if either MAX_CHARS constant is ever retuned past
-- TEXT_STRING_CAP, msg_write_text would silently re-truncate the already-truncated string, losing
-- truncate_text()'s own '...' and cutting mid-word.
assert(BIG_MAX_CHARS <= TEXT_STRING_CAP,
	'BIG_MAX_CHARS must fit within TEXT_STRING_CAP or zname draws would be re-truncated on the wire')
assert(MEDIUM_MAX_CHARS <= TEXT_STRING_CAP,
	'MEDIUM_MAX_CHARS must fit within TEXT_STRING_CAP or zset draws would be re-truncated on the wire')

-- SCROLL-OFF MARGIN (vim's `scrolloff`): a scroll TRIGGERS once the cursor comes within
-- SCROLL_MARGIN rows of an edge, so at least this many rows of context stay visible beyond it -
-- Jeroen's requirement that at least one patch AFTER the current one is always on screen. 2, not 1:
-- set headers occupy rows in a continuous list, so a margin of 1 could leave the single visible row
-- below the current patch a set header. See
-- docs/config-lua-history.md#scroll_margin-and-the-worked-example. Asserted rather than assumed:
-- SCROLL_MARGIN must stay under half the window or this rule and the final clamp in clamp_scroll()
-- fight each other.
SCROLL_MARGIN = 2
assert(SCROLL_MARGIN < ROW_COUNT / 2,
	'SCROLL_MARGIN must be less than ROW_COUNT / 2 or the margin and the final clamp fight each other')

-- PAGE_OVERLAP is DERIVED, not picked: the cursor's landing position after a page jump is not a
-- free choice once SCROLL_MARGIN and ROW_COUNT are fixed. Landing at the edge just jumped to (the
-- smallest possible overlap) puts the cursor back inside the OPPOSITE margin's trigger zone,
-- causing every subsequent single-row step to re-trigger a jump the other way - oscillation, worse
-- than the bug page-jumping exists to fix. The only landing spot safe from BOTH margins at once is
-- SCROLL_MARGIN rows in from the edge just crossed, which forces PAGE_OVERLAP = 2 * SCROLL_MARGIN.
-- Do not shrink this without re-running the oscillation check (see Tests/lua/harness.lua's
-- clamp_scroll test) - a smaller value than this WILL oscillate. See
-- docs/config-lua-history.md#page_overlap-derivation-and-the-oscillation-trace.
PAGE_OVERLAP = 2 * SCROLL_MARGIN
assert(PAGE_OVERLAP < ROW_COUNT,
	'PAGE_OVERLAP must be less than ROW_COUNT or a jump does not move the window at all')

-- Keeps scrollOffset such that cursorIndex is always inside the visible window, with SCROLL_MARGIN
-- rows of context beyond it wherever the list itself allows.
--
-- Once triggered, the window jumps by (ROW_COUNT - PAGE_OVERLAP) rows in the direction of travel,
-- landing the cursor SCROLL_MARGIN rows in from the edge it just crossed - the landing spot with
-- maximum runway in the direction of travel while staying clear of BOTH margins at once (see
-- PAGE_OVERLAP's comment for why any other landing spot oscillates). Do NOT replace this with a
-- one-row minimum-shift policy - that was tried and abandoned; see
-- docs/config-lua-history.md#the-one-row-shift-abandoned.
--
-- The cursor's landing row is computed directly from cursorIndex, not as an offset from the OLD
-- scrollOffset, so this is correct for a jump of any size (a single patch step, or the much bigger
-- cursorIndex jump a set change or full repaint can produce) without a separate case for either.
-- Still edge-triggered, NOT re-centring on every move - an in-window move costs nothing here
-- (scrollOffset untouched, the cheap 2-message case).
--
-- The final clamp is what makes the list's own ends behave: near the top or bottom the landing
-- guarantee can't always be honoured, so the offset pins at its limit and the cursor moves further
-- into the window instead. This is also what keeps the LAST page a full ROW_COUNT-row window rather
-- than a short one: scrollOffset can never exceed #listRows - ROW_COUNT.
--
-- Standalone rather than inlined into controller_select_patch so Phase 2's joystick-driven cursor
-- movement can call it too instead of re-deriving the same clamp arithmetic.
function clamp_scroll()
	local m = SCROLL_MARGIN
	if cursorIndex - m < scrollOffset then
		-- Triggered scrolling BACKWARD: land SCROLL_MARGIN rows in from the window's LAST row - symmetric
		-- with the forward branch below, and the one landing spot that is safe from both margins (see
		-- PAGE_OVERLAP's comment).
		scrollOffset = cursorIndex - (ROW_COUNT - 1 - m)
	elseif cursorIndex + m >= scrollOffset + ROW_COUNT then
		-- Triggered scrolling FORWARD: land SCROLL_MARGIN rows in from the window's FIRST row.
		scrollOffset = cursorIndex - m
	end
	local maxOffset = math.max(0, #listRows - ROW_COUNT)
	if scrollOffset > maxOffset then scrollOffset = maxOffset end
	if scrollOffset < 0 then scrollOffset = 0 end
end

-- Three row states - deliberately fewer than the old four, because the cursor is no longer a colour
-- state at all (see draw_list_row()'s '> ' marker below): only what KIND of row it is, and whether
-- it is the active patch, affects colour now. { fr, fg, fb, br, bg, bb } per state - see
-- docs/full-functionality-plan.md's colour table. All channel values even (the wire format is 7-bit
-- per channel and halves these, dropping the low bit - odd values silently round), except the
-- conventional 255 used for 'fully saturated' throughout this file, which rounds to the same 127 as
-- 254 so costs nothing.
ROW_HEADER = 0
ROW_PATCH  = 1
ROW_ACTIVE = 2

ROW_COLORS = {
	[ROW_HEADER] = { 110, 170, 230,   0,   0,   0 }, -- blue on black: structure, not a patch
	[ROW_PATCH]  = { 150, 150, 150,   0,   0,   0 }, -- grey on black: recessive, the bulk of the list
	[ROW_ACTIVE] = {   0,   0,   0, 255, 170,  40 }, -- black on amber: unmistakable at distance
}

-- MARK: - Encoder value popup
--
-- Shows a transient panel whenever ANY mapped encoder moves. Two modes: FEEDBACK, when
-- controller_midi_out has reported a MainStage screen control for this CC (real parameter name/
-- value/absolute position); LEGACY, the original ENCODER_NAME/CC-number/encoderValue-only layout,
-- for a control with no screen control assigned. See docs/config-lua-history.md#controller_midi_out-
-- reports-real-parameter-values-with-a-screen-control-2026-09-17 for the layout table and rules.
--
-- v6 replaced a hand-drawn 20-segment ring with the native Knob bitmap (BMP_GROUP_KNOB, verified on
-- hardware - see docs/implementing-sl-link.md §5) once Plot Bitmap was confirmed working; see
-- docs/config-lua-history.md#the-knob-bitmap-replaces-the-ring-2026-08-29 for the message-count and
-- layout rationale, and docs/config-lua-history.md#the-encoder-value-popup-v1-v5 for the v1-v5
-- history this closes out.
--
-- A genuine full-screen display mode (displayMode == 'popup', alongside 'list'/'zoom'), not a
-- floating overlay - see set_display_mode's 'popup' branch and paint_popup_screen below. Owning the
-- whole screen means dismiss_popup() can reuse set_display_mode's proven double-Clear-Screen/
-- invalidate sequence instead of an ad-hoc redraw, and there is nothing underneath to protect from
-- overlap.
--
-- How often controller_timer_trigger fires while the popup is up and idle, so
-- POPUP_DISMISS_IDLE_TICKS ticks at roughly this cadence instead of KEEPALIVE_MS's ~3s - see
-- rearm_timer's popupActive branch.
POPUP_TICK_MS = 1000

-- The Master Volume popup's extra "PUSH TO MUTE/UNMUTE" row: space reserved in the panel, not a
-- glyph height - it must stay >= TEXT_H_SMALL (the harness asserts this) or the row is clipped.
POPUP_MUTE_HINT_H = 21
POPUP_MUTE_HINT_GAP = 8

POPUP_W = 280
POPUP_H = 140 + POPUP_MUTE_HINT_H + POPUP_MUTE_HINT_GAP -- base panel + room for the mute hint row
POPUP_X = math.floor((SCREEN_WIDTH - POPUP_W) / 2)
POPUP_Y = math.floor((SCREEN_HEIGHT - POPUP_H) / 2)
POPUP_PAD = 10 -- inset for the label/value text, so neither touches the panel's side edges

POPUP_CONTENT_X = POPUP_X + POPUP_PAD
POPUP_CONTENT_W = POPUP_W - 2 * POPUP_PAD

POPUP_CENTER_X = POPUP_X + POPUP_W / 2 -- the panel is itself screen-centred, so this also centres on SCREEN_WIDTH

-- Two non-overlapping vertical bands (knob, then label - top to bottom); the value is not a third
-- band, it is drawn INSIDE the knob's band (see the NON-OVERLAP RULE escape hatch on
-- draw_popup_knob() below). Offsets sized against TEXT_H_MEDIUM and the Knob bitmap's fixed
-- BMP_ICON_W x BMP_ICON_H size.
POPUP_KNOB_X = math.floor(POPUP_CENTER_X - BMP_ICON_W / 2) -- horizontally centred (screen-centred, see above); floored - BMP_ICON_W is odd, so the raw centring math lands on a half-pixel
-- SHARED by both popup modes: the control's name on top at SIZE_MEDIUM, then the ring. Both modes used
-- to place these differently (the legacy label sat BELOW its ring), which made the two popups disagree
-- about where the name lives - Jeroen asked for the name above the ring in both, in the larger font.
POPUP_TITLE_Y = 42
POPUP_KNOB_Y = 70
-- Third band, Master Volume popup only: below the RING now that the name is above it.
POPUP_HINT_Y = POPUP_KNOB_Y + BMP_ICON_H + 12

-- FEEDBACK-mode geometry (a screen control exists - see the layout table this file's comment above
-- points at). Exact y's from that table; panel spans POPUP_Y..POPUP_Y+POPUP_H (35-204). Legacy-mode
-- geometry (POPUP_KNOB_Y etc. above) is untouched.
POPUP_FB_VALUE_Y = 132
POPUP_FB_HINT_Y = 165

-- The Knob bitmap's usable inner hole, MEASURED on hardware 2026-09-20 with
-- Scripts/probe-text-metrics.swift: the largest Write Text box that fits without touching the ring,
-- given as an offset from the icon's top-left. Write Text's background box fills its whole maxWidth,
-- so a box wider than the hole paints an opaque bar through the ring's sides.
KNOB_HOLE_W = 36
KNOB_HOLE_DY = 18

-- The value is drawn in that hole, so its box IS the hole. Do not nudge these by eye - the pair was
-- guessed twice that way before it was measured, and both guesses were wrong; re-run the probe
-- instead. See docs/config-lua-history.md#write-text-box-heights-measured-2026-09-20.
POPUP_VALUE_W = KNOB_HOLE_W
POPUP_VALUE_X = POPUP_KNOB_X + math.floor((BMP_ICON_W - POPUP_VALUE_W) / 2) -- centred on the icon
POPUP_VALUE_Y = POPUP_KNOB_Y + KNOB_HOLE_DY

POPUP_BG_COLOR = { 0, 0, 0 }
POPUP_KNOB_FG = { 255, 140, 0 } -- true orange, carried over from the old ring's lit-segment colour
POPUP_VALUE_FG = { 255, 255, 255 }
POPUP_LABEL_FG = { ROW_COLORS[ROW_PATCH][1], ROW_COLORS[ROW_PATCH][2], ROW_COLORS[ROW_PATCH][3] }
POPUP_BORDER_COLOR = { 200, 210, 220 } -- thin light neutral border, matching the native overlay's frame - NOT orange, keep orange exclusive to the knob's fill

popupActive = false
-- Cached name/CC/value for the CURRENTLY showing popup, updated by show_popup() and read by
-- paint_popup_screen() - so a repaint triggered from elsewhere (paint_screen() dispatching to
-- paint_popup_screen() because displayMode=='popup', or enter_popup_mode() itself) can redraw the
-- popup's content without needing the encoder id threaded through every call site.
popupControlName = nil
popupCcNumber = nil
popupValue = 0
popupMax = 127 -- popupValue's scale for popup_knob_icon's ring fill; 127 for CC encoders, 100 for Master Volume
-- FEEDBACK-mode state: eid currently showing (nil for the Master Volume popup, which never has
-- feedback - it has no CC), whether it currently has MainStage feedback, and the reported name/
-- sanitised valueString to paint when it does. popupModeIsFeedback tracks which geometry was last
-- PAINTED (not just "has feedback"), so a mode switch mid-session can be detected and re-erased -
-- see show_popup()'s mode-switch check.
popupEid = nil
popupFeedbackActive = false
popupFeedbackName = nil
popupValueString = nil
popupModeIsFeedback = nil
-- displayMode to restore when the popup dismisses - set by show_popup() to whatever displayMode was
-- BEFORE it switched to 'popup' (only on the transition into showing, never overwritten while
-- already active - see show_popup's popupActive guard), consumed once by dismiss_popup().
popupPreviousMode = nil
popupLastActivityIdleTick = 0

-- Repaint popupValue at most every Nth tick, not every tick - an opaque Write Text redraw on every
-- tick (~28/s while draining, see FLUSH_SOON_MS) reads as flicker on a device with no compositing;
-- measured 399 value repaints against the ring's 76 over one sweep. 3 -> ~10/s. See
-- docs/config-lua-history.md#popup-value-repaint-throttled-2026-09-14.
POPUP_VALUE_THROTTLE_TICKS = 3
-- timerTicks value popupValue was last actually redrawn; -1 so the first paint is never throttled.
popupValueLastPaintTick = -1
-- True when popupValue changed but the throttle withheld the redraw - drained by
-- flush_popup_value_if_due() once POPUP_VALUE_THROTTLE_TICKS have elapsed, so a settled value can
-- never stay stale.
popupValueDirty = false

-- Border: same 'four non-overlapping edge-strip rects' idiom as the Swift companion app's
-- zone-selection outline (see the demo screen on archive/swift-app) - top/bottom span the panel's
-- full width, left/right span only the strip between them, so no two edges cover the same pixel. The
-- fill (popupBg, below) is inset by the border's thickness so it never overlaps the border either -
-- each id owns pixels no other id touches, per the per-id-memoization rule above (see this
-- file's CLAUDE.md).
POPUP_BORDER_THICKNESS = 4

function draw_popup_border()
	local t = POPUP_BORDER_THICKNESS
	local c = POPUP_BORDER_COLOR
	draw_rect('popupBorderTop', POPUP_X, POPUP_Y, POPUP_W, t, c[1], c[2], c[3])
	draw_rect('popupBorderBottom', POPUP_X, POPUP_Y + POPUP_H - t, POPUP_W, t, c[1], c[2], c[3])
	draw_rect('popupBorderLeft', POPUP_X, POPUP_Y + t, t, POPUP_H - 2 * t, c[1], c[2], c[3])
	draw_rect('popupBorderRight', POPUP_X + POPUP_W - t, POPUP_Y + t, t, POPUP_H - 2 * t, c[1], c[2], c[3])
end

function draw_popup_bg()
	local t = POPUP_BORDER_THICKNESS
	draw_rect('popupBg', POPUP_X + t, POPUP_Y + t, POPUP_W - 2 * t, POPUP_H - 2 * t,
		POPUP_BG_COLOR[1], POPUP_BG_COLOR[2], POPUP_BG_COLOR[3])
end

-- Popup ids the full-region erase below overlaps - the NON-OVERLAP RULE's own escape hatch (see
-- MARK: - Per-region memoization above): a caller that can't avoid overlap must clear all the
-- shared ids' drawn[] entries together so they resend as one unit.
POPUP_ERASE_OVERLAP_IDS = { 'popupBg', 'popupBorderTop', 'popupBorderBottom', 'popupBorderLeft',
	'popupBorderRight', 'popupTitle', 'popupLabel', 'popupKnob', 'popupValue', 'popupMuteHint' }

-- Default entry behaviour for every popup (called once by enter_popup_mode(), never by a mid-session
-- repaint): one filled rect over the WHOLE panel (border included), queued first, so the previous
-- screen can never show through while the border/label/knob/value messages that follow are still
-- trickling out one per tick - see
-- docs/config-lua-history.md#popup-entry-always-erases-its-full-region-first-2026-09-12.
-- Must always resend - draw_rect() memoizes by id, so both this id and everything it overlaps have
-- their drawn[] entries cleared first, or an otherwise-unchanged popup would skip it.
function draw_popup_erase()
	drawn['popupErase'] = nil
	for _, id in ipairs(POPUP_ERASE_OVERLAP_IDS) do drawn[id] = nil end
	draw_rect('popupErase', POPUP_X, POPUP_Y, POPUP_W, POPUP_H,
		POPUP_BG_COLOR[1], POPUP_BG_COLOR[2], POPUP_BG_COLOR[3])
end

-- SIZE_MEDIUM + non-zero maxWidth is safe here, unlike the zoom screen's SIZE_BIG text: Max Width
-- truncation is only confirmed broken at SIZE_BIG (docs/config-lua-history.md#max-width-truncation-
-- broken-at-size_big), and 'ENC 1 - CC 59'-shaped strings are far shorter than POPUP_CONTENT_W, so
-- truncation never triggers. A non-zero maxWidth also means Write Text's own background box makes
-- this self-clearing (see MARK: - Per-region memoization's non-overlap rule above) - no erase rect
-- needed. Plain ASCII ' - ' separator, not a middle dot/en dash: the SLMK2 font only covers 0x20-0x80
-- (see append_text's clamp). Below the ring now, not above it - see docs/config-lua-history.md#value-
-- moved-inside-the-ring-2026-09-14.
function draw_popup_label(name, ccNumber)
	-- ccNumber is nil for controls with no CC (Master Volume/EID_A) - show just the name.
	local label = ccNumber and (name .. ' - CC ' .. ccNumber) or name
	draw_text('popupLabel', label, POPUP_CONTENT_X, POPUP_TITLE_Y,
		POPUP_CONTENT_W, ALIGN_CENTER, SIZE_MEDIUM, POPUP_LABEL_FG[1], POPUP_LABEL_FG[2],
		POPUP_LABEL_FG[3], POPUP_BG_COLOR[1], POPUP_BG_COLOR[2], POPUP_BG_COLOR[3])
end

-- FEEDBACK mode only: the MainStage screen control's own name, above the ring (see the layout
-- table). SIZE_SMALL, unlike popupLabel's SIZE_MEDIUM - it is a secondary line here, not the star.
function draw_popup_title(name)
	draw_text('popupTitle', name or '', POPUP_CONTENT_X, POPUP_TITLE_Y, POPUP_CONTENT_W,
		ALIGN_CENTER, SIZE_MEDIUM, POPUP_LABEL_FG[1], POPUP_LABEL_FG[2], POPUP_LABEL_FG[3],
		POPUP_BG_COLOR[1], POPUP_BG_COLOR[2], POPUP_BG_COLOR[3])
end

-- Same SIZE_MEDIUM/non-zero-maxWidth safety as draw_popup_label above - a 1-3 digit value is even
-- shorter than the label, so truncation is not in play here either.
-- value may be nil - shown as '--', never as a number (defensive; no current caller passes nil
-- since MVOL_SEED_DEFAULT replaced the placeholder - see
-- docs/config-lua-history.md#seed-master-volume-at-60-instead-of-refusing-to-write-2026-09-12).
-- Draws INSIDE draw_popup_knob()'s rect - POPUP_VALUE_W is kept narrower than the ring's inner hole
-- (see its declaration above) so Write Text's opaque background box never crosses into the ring.
function draw_popup_value(value)
	local text = value and tostring(value) or '--'
	return draw_text('popupValue', text, POPUP_VALUE_X, POPUP_VALUE_Y, POPUP_VALUE_W,
		ALIGN_CENTER, SIZE_MEDIUM, POPUP_VALUE_FG[1], POPUP_VALUE_FG[2], POPUP_VALUE_FG[3],
		POPUP_BG_COLOR[1], POPUP_BG_COLOR[2], POPUP_BG_COLOR[3])
end

-- FEEDBACK mode only: MainStage's own formatted valueString, below the ring rather than inside it
-- (a real string like '+0,0 dB' does not fit POPUP_VALUE_W's narrow ring-hole box) - full content
-- width, same idiom as draw_popup_label.
function draw_popup_feedback_value(text)
	return draw_text('popupValue', text or '', POPUP_CONTENT_X, POPUP_FB_VALUE_Y, POPUP_CONTENT_W,
		ALIGN_CENTER, SIZE_MEDIUM, POPUP_VALUE_FG[1], POPUP_VALUE_FG[2], POPUP_VALUE_FG[3],
		POPUP_BG_COLOR[1], POPUP_BG_COLOR[2], POPUP_BG_COLOR[3])
end

-- y differs by mode (POPUP_HINT_Y legacy / POPUP_FB_HINT_Y feedback - see paint_popup_legacy/
-- paint_popup_feedback). Non-zero maxWidth text is self-clearing (same idiom as draw_popup_label),
-- so a control switch that turns the hint off draws blank text over it once rather than leaving it
-- stale - see the paint_popup_* call sites.
function draw_popup_mute_hint(show, y)
	local text = show and 'PUSH TO MUTE/UNMUTE' or ''
	draw_text('popupMuteHint', text, POPUP_CONTENT_X, y, POPUP_CONTENT_W,
		ALIGN_CENTER, SIZE_SMALL, 120, 120, 120,
		POPUP_BG_COLOR[1], POPUP_BG_COLOR[2], POPUP_BG_COLOR[3])
end

-- Knob icon index for a 0-popupMax value: linear scaling by value/popupMax (NOT value/(popupMax+1)),
-- so that value=0 selects icon 0 (empty) and value=popupMax - the actual maximum - selects icon 0x0C
-- (full) exactly, whether popupMax is 127 (CC encoders) or 100 (Master Volume). nil (no READ reply
-- yet) also renders as icon 0 - empty, same as 0, never a misleading full ring.
function popup_knob_icon(value)
	if value == nil then return 0 end
	return math.floor(value * (BMP_KNOB_LEVELS - 1) / popupMax)
end

-- y is POPUP_KNOB_Y (legacy) or POPUP_FB_KNOB_Y (feedback) - see the two paint_popup_* functions.
-- legacyOverlap is true only for legacy mode, where popupValue draws INSIDE this bitmap's rect
-- (feedback mode's popupValue sits below the ring - no overlap, see draw_popup_feedback_value).
--
-- NON-OVERLAP RULE escape hatch (see MARK: - Per-region memoization above), legacy mode only: a knob
-- redraw (which repaints the whole icon) must always be queued BEFORE its value. queue_message
-- coalesces a same-regionId update at its OLD queue position, so a popupValue queued earlier (a
-- prior value-only change) would otherwise stay ahead of a knob queued just now - drop it and force
-- it to re-append behind the knob. See
-- docs/config-lua-history.md#popup-value-wiped-by-its-own-ring-redraw-2026-09-17.
function draw_popup_knob(value, y, legacyOverlap)
	local icon = popup_knob_icon(value)
	local queued = draw_bitmap('popupKnob', POPUP_KNOB_X, y, BMP_GROUP_KNOB, icon,
		POPUP_KNOB_FG[1], POPUP_KNOB_FG[2], POPUP_KNOB_FG[3],
		POPUP_BG_COLOR[1], POPUP_BG_COLOR[2], POPUP_BG_COLOR[3])
	if queued and legacyOverlap then
		drop_queued_region('popupValue')
		drawn['popupValue'] = nil
	end
	return queued
end

-- Throttled entry point for popupValue - call this instead of draw_popup_value()/
-- draw_popup_feedback_value() directly (see POPUP_VALUE_THROTTLE_TICKS). `drawn['popupValue'] ==
-- nil` means either the very first paint or draw_popup_knob() just invalidated it for an icon
-- change; either way that must win over the throttle immediately, or the value stays blank/stale
-- until the throttle next allows a repaint.
function queue_popup_value()
	local forced = drawn['popupValue'] == nil
	if forced or timerTicks - popupValueLastPaintTick >= POPUP_VALUE_THROTTLE_TICKS then
		popupValueLastPaintTick = timerTicks
		popupValueDirty = false
		if popupFeedbackActive then draw_popup_feedback_value(popupValueString) else draw_popup_value(popupValue) end
	else
		popupValueDirty = true
	end
end

-- Called every timer tick (controller_timer_trigger) while the popup is active - drains a
-- throttle-withheld redraw once POPUP_VALUE_THROTTLE_TICKS have elapsed, so a value that settles
-- mid-throttle still ends up painted rather than staying one step behind.
function flush_popup_value_if_due()
	if not popupActive or not popupValueDirty then return end
	if timerTicks - popupValueLastPaintTick < POPUP_VALUE_THROTTLE_TICKS then return end
	popupValueLastPaintTick = timerTicks
	popupValueDirty = false
	if popupFeedbackActive then draw_popup_feedback_value(popupValueString) else draw_popup_value(popupValue) end
end

-- CC-mapped encoder (eid, in ENCODER_CC's domain) -> the BID of its own paired push button, for the
-- mute indicator below. The joystick pairs with its own centre press; every zone encoder and B pair
-- with their own push button.
ENCODER_MUTE_BUTTON = {
	[EID_ZONE1] = BID_ZONE1_ENC, [EID_ZONE2] = BID_ZONE2_ENC,
	[EID_ZONE3] = BID_ZONE3_ENC, [EID_ZONE4] = BID_ZONE4_ENC,
	[EID_B] = BID_B_ENC,
}

-- Ring LED id for an encoder's mute state - only A and B have a ring LED (WLID_A_ENC/WLID_B_ENC);
-- Zone 1-4 and the joystick show the mute hint text only, no LED.
ENCODER_MUTE_WLID = { [EID_B] = WLID_B_ENC }

-- RGB ring LED id per zone encoder (IT_RGB_LED). Only these four have an RGB ring; A and B have a
-- white lamp instead (above), and the joystick has neither. Written out one per line so the pairing
-- can be checked by eye against the spec's LID table.
ENCODER_RGB_LID = {
	[EID_ZONE1] = 0x00,
	[EID_ZONE2] = 0x01,
	[EID_ZONE3] = 0x02,
	[EID_ZONE4] = 0x03,
}

-- Full brightness for a lit ring. The lamp cannot show a level, only colour and brightness (see
-- IT_RGB_LED), so brightness carries nothing but lit-vs-dark here.
RGB_BRIGHT = 0x7F

-- Last White LED state actually sent per WLID, so paint_popup_feedback (called on every popup
-- repaint) only queues msg_white_led on a real change, not on every tick - same idea as drawn[]
-- memoization but for LED state rather than display content.
encoderMuteLedSent = {}

-- Last { r, g, b, brightness } actually sent per RGB ring id, same purpose as encoderMuteLedSent -
-- see flush_encoder_rings().
encoderRingSent = {}

-- Returns (showHint, muted) for eid's paired push button: showHint is true only when that button
-- itself has MainStage feedback (see controller_midi_out) AND its reported name contains 'Mute'
-- (case-insensitive); muted is that feedback's absolute value ~= 0, meaningful only when showHint is
-- true. See docs/config-lua-history.md#controller_midi_out-reports-real-parameter-values-with-a-
-- screen-control-2026-09-17.
function encoder_mute_state(eid)
	local bid = eid and ENCODER_MUTE_BUTTON[eid]
	local buttonCc = bid and BUTTON_CC[bid]
	local cc = buttonCc and CC_MAP[buttonCc.short]
	local fb = cc and midiOutFeedback[cc]
	if fb == nil or fb.name == nil or not fb.name:lower():find('mute', 1, true) then
		return false, false
	end
	return true, (fb.value or 0) ~= 0
end

-- LEGACY-mode content: unchanged from before controller_midi_out reported real feedback - the
-- physical encoder's name/CC number, encoderValue's ring, and the mute hint for Master Volume only.
function paint_popup_legacy()
	draw_popup_label(popupControlName, popupCcNumber)
	draw_popup_knob(popupValue, POPUP_KNOB_Y, true)
	queue_popup_value()
	if popupCcNumber == nil then
		draw_popup_mute_hint(true, POPUP_HINT_Y)
	elseif drawn['popupMuteHint'] ~= nil then
		draw_popup_mute_hint(false, POPUP_HINT_Y) -- clear a stale hint left by a Master Volume popup before a control switch
	end
end

-- FEEDBACK-mode content: the reported MainStage parameter name/value, and the mute hint/LED driven
-- by the paired push button's own feedback (encoder_mute_state) rather than Master Volume.
function paint_popup_feedback()
	draw_popup_title(popupFeedbackName)
	draw_popup_knob(popupValue, POPUP_KNOB_Y, false)
	queue_popup_value()

	-- Hint only; the ring LED is driven by flush_mute_leds() on the timer tick, not from here.
	local showHint = encoder_mute_state(popupEid)
	if showHint then
		draw_popup_mute_hint(true, POPUP_FB_HINT_Y)
	elseif drawn['popupMuteHint'] ~= nil then
		draw_popup_mute_hint(false, POPUP_FB_HINT_Y)
	end
end

-- Drains the mute ring LEDs, once per timer tick from controller_timer_trigger. NOT driven from the
-- popup paint: the mute is pressed on the paired push button, which neither opens nor repaints the
-- popup, and the popup dismisses after ~2s anyway - the LED is a persistent indicator, so it has to
-- track the feedback rather than the popup. Not queued from controller_midi_out either, which must
-- never queue. Lit = unmuted, matching the A ring.
-- Last HOME lamp state sent; nil means 'unknown, send it'. Same memo/clear discipline as
-- encoderMuteLedSent - see flush_mute_leds.
homeLedSent = nil
-- Same for the GLOBAL lamp; nil means 'unknown, send it'.
globalLedSent = nil

-- HOME lamp mirrors the screen: lit in the patch list, dark in zoom. Drained on the tick and
-- ACTIVE-only for the same reasons as flush_mute_leds. During a popup it follows the mode the popup
-- is covering, so a transient popup never darkens it.
function flush_mode_led()
	if state ~= STATE_ACTIVE then return end
	-- What is actually on screen: a popup COVERS a mode rather than replacing it.
	local shown = popupActive and (popupPreviousMode or displayMode) or displayMode
	-- The HOME lamp tracks list-vs-zoom ONLY. The config screen is a temporary overlay on one of
	-- those, so it must leave the lamp exactly as it was - Jeroen's requirement after the first
	-- hardware run, where entering config darkened it. Follow what config is covering, the same way
	-- the popup follows popupPreviousMode.
	local underlying = shown
	if underlying == 'config' then underlying = configPreviousMode or 'list' end
	local ledOn = (underlying == 'list')
	if homeLedSent ~= ledOn then
		homeLedSent = ledOn
		queue_message(msg_white_led(WLID_HOME, ledOn))
	end
	-- GLOBAL lamp: lit only while the config screen shows, so the button's own light is the
	-- "you are in config" indicator.
	local configOn = (shown == 'config')
	if globalLedSent ~= configOn then
		globalLedSent = configOn
		queue_message(msg_white_led(WLID_GLOBAL, configOn))
	end
end

function flush_mute_leds()
	-- ACTIVE only. An LED write before the app is selected is discarded by the SL88 anyway, and
	-- queueing one during identification competes with the retry for the per-tick permit and delays
	-- re-identification - a harness assertion caught exactly that.
	if state ~= STATE_ACTIVE then return end
	for eid, wlid in pairs(ENCODER_MUTE_WLID) do
		local showHint, muted = encoder_mute_state(eid)
		-- No mute mapping means the ring must go DARK, not be left at whatever it happened to show:
		-- skipping here left a stale lamp from a previous concert or session lit.
		local ledOn = showHint and not muted or false
		if encoderMuteLedSent[wlid] ~= ledOn then
			encoderMuteLedSent[wlid] = ledOn
			queue_message(msg_white_led(wlid, ledOn))
		end
	end
end

-- Brightness for a lit ring: it tracks the control's value, so a fader dims the ring as it comes down and
-- bottoms out dark - Jeroen's requirement. Applied to EVERY ring rather than only to names containing
-- 'volume': the rings are driven by encoder TURN mappings, which are always continuous controls, and
-- matching on the name silently stopped dimming as soon as a mapping was relabelled (MainStage's Replace
-- Parameter Label decides that text - see docs/mainstage-integration.md). The consequence to accept is
-- that a Pan at hard left is 0, so its ring goes dark there too.
function ring_brightness(fb)
	local v = fb.value or RGB_BRIGHT
	if v < 0 then v = 0 elseif v > RGB_BRIGHT then v = RGB_BRIGHT end
	return v
end

-- The four zone encoder rings, coloured by MainStage itself: whatever parameter a knob is mapped to,
-- its own colour lights that knob's ring. Same discipline as flush_mute_leds - ACTIVE only, drained on
-- the tick, memoized so an unchanged ring queues nothing.
--
-- DARK means either 'muted' or 'nothing mapped' - agreed with Jeroen, who chose a muted channel going
-- fully dark over keeping the two distinguishable. Going dark when MainStage reports nothing is not
-- optional: skipping instead leaves a colour from a previous concert lit, the same trap flush_mute_leds
-- documents above. See docs/config-lua-history.md#rgb-encoder-rings-2026-09-20.
function flush_encoder_rings()
	if state ~= STATE_ACTIVE then return end
	for eid, lid in pairs(ENCODER_RGB_LID) do
		local cc = CC_MAP[ENCODER_CC[eid]]
		local fb = cc and midiOutFeedback[cc]
		local _, muted = encoder_mute_state(eid)
		local r, g, b, bright = 0, 0, 0, 0
		if fb ~= nil and fb.color ~= nil and not muted then
			r, g, b, bright = rgb7(fb.color.r), rgb7(fb.color.g), rgb7(fb.color.b), ring_brightness(fb)
		end
		local sent = encoderRingSent[lid]
		if sent == nil or sent[1] ~= r or sent[2] ~= g or sent[3] ~= b or sent[4] ~= bright then
			encoderRingSent[lid] = { r, g, b, bright }
			-- Own regionId per ring, so a fast fader move coalesces to ONE queued update instead of
			-- appending one message per value change - the same reason the Master Volume write carries
			-- 'mvol' (see queue_message's PER-REGION COALESCING comment). Without it a sweep queues dozens
			-- of LED messages ahead of display traffic and the keepalive.
			queue_message(msg_rgb_led(lid, r, g, b, bright), 'ring' .. lid)
		end
	end
end

-- The popup's own content-painting function, in the same family as paint_zoom_screen()/
-- paint_list_screen() - dispatched to from enter_popup_mode() (once per popup 'session') and from
-- paint_screen() (an ordinary content-driven repaint that lands while displayMode=='popup', e.g. a
-- patch-name change arriving mid-popup - see paint_screen's 3-way branch). Reads popup* module state
-- rather than taking parameters, since both call sites dispatch generically by mode with no encoder
-- id in hand. Safe to call repeatedly - every draw_* call underneath is per-id memoized (drawn[]), so
-- a call that changes nothing queues nothing (see show_popup's repeat-call path, which relies on
-- exactly this).
function paint_popup_screen()
	draw_popup_bg()
	draw_popup_border()
	if popupFeedbackActive then paint_popup_feedback() else paint_popup_legacy() end
end

-- Call from handle_sl_frame's IT_ENCODER branch, right after encoderValue[eid] is updated, for
-- every eid present in ENCODER_CC (looped there, not hardcoded - see that call site).
--
-- FIRST call of a popup 'session' (popupActive false -> true) runs enter_popup_mode() ONCE, whose
-- own paint dispatch does the drawing. REPEAT calls (continued scrubbing) must NOT re-run it - that
-- would re-invalidate everything on every tick, UNLESS the mode itself is switching (legacy <->
-- feedback - two feedback controls share geometry, so switching between THEM needs no re-erase):
-- the two modes place popupValue (and popupTitle/popupLabel) at different y positions, and
-- memoization never clears a position a region vacated - see
-- docs/config-lua-history.md#controller_midi_out-reports-real-parameter-values-with-a-screen-control-2026-09-17.
function show_popup(eid)
	-- No popup over the config screen: it would hide the page being read, and restoring it costs a
	-- full Clear-Screen repaint of every config region. The CC (or the Master Volume write) still goes
	-- out - only the panel is skipped. See
	-- docs/config-lua-history.md#no-popup-over-the-config-screen-2026-09-20.
	if displayMode == 'config' then return end
	-- Belt and braces for the ring: its own branch in handle_sl_frame never reaches here, but the patch
	-- list is its feedback and a popup would cover the very screen showing the selection.
	if eid == EID_JOYSTICK then return end
	local control = ENCODER_CC[eid]
	if control == nil then return end

	local cc = CC_MAP[control]
	local fb = midiOutFeedback[cc]

	popupEid = eid
	popupControlName = ENCODER_NAME[eid]
	popupCcNumber = cc
	popupValue = fb and fb.value or encoderValue[eid]
	popupMax = 127
	-- FEEDBACK mode exists to show MainStage's own name, so a nameless entry (see controller_midi_out's
	-- empty-name filter) falls back to LEGACY: the physical encoder's label and CC number. The ring still
	-- uses that entry's colour either way.
	popupFeedbackActive = fb ~= nil and fb.name ~= nil
	popupFeedbackName = fb and fb.name
	popupValueString = fb and fb.valueString
	popupLastActivityIdleTick = idleTicks

	if not popupActive then
		popupPreviousMode = displayMode
		popupActive = true
		popupModeIsFeedback = popupFeedbackActive
		enter_popup_mode()
	else
		if popupModeIsFeedback ~= popupFeedbackActive then
			draw_popup_erase()
			popupModeIsFeedback = popupFeedbackActive
		end
		paint_popup_screen()
		request_quick_rearm()
	end
end

-- EID_A's popup: same structure as show_popup, but for Master Volume (no CC number, 0-100 scale,
-- never has feedback - Master Volume is not a CC_MAP entry) rather than an ENCODER_CC entry.
function show_master_volume_popup()
	-- No popup over the config screen: it would hide the page being read, and restoring it costs a
	-- full Clear-Screen repaint of every config region. The CC (or the Master Volume write) still goes
	-- out - only the panel is skipped. See
	-- docs/config-lua-history.md#no-popup-over-the-config-screen-2026-09-20.
	if displayMode == 'config' then return end
	popupEid = nil
	popupControlName = 'AUDIO MASTER' -- what the SL88's own board calls it, so the two agree
	popupCcNumber = nil
	-- The value being SENT (masterVolume), tracked locally only - never reseeded from
	-- masterVolumeRead, which does not track our writes on this hardware. See
	-- docs/config-lua-history.md#master-volume-read-reply-does-not-track-writes-2026-09-12.
	popupValue = masterVolume
	popupMax = 100
	popupFeedbackActive = false
	popupLastActivityIdleTick = idleTicks

	if not popupActive then
		popupPreviousMode = displayMode
		popupActive = true
		popupModeIsFeedback = false
		enter_popup_mode()
	else
		if popupModeIsFeedback ~= false then
			draw_popup_erase()
			popupModeIsFeedback = false
		end
		paint_popup_screen()
		request_quick_rearm()
	end
end

-- ~2s-idle dismissal, quantised to the session clock's existing idle-tick counter (idleTicks,
-- incremented once per timer-tick while nothing is draining). While popupActive is true,
-- rearm_timer() arms the tick at POPUP_TICK_MS (~1s) instead of the normal KEEPALIVE_MS (~3s), so
-- POPUP_DISMISS_IDLE_TICKS=2 means 'wait two ~1s ticks'. This reuses the single existing timer
-- rather than adding a second settriggertimer, which risks the same starved-clock class of bug rule
-- 6 in the banner fixes. See docs/config-lua-history.md#popup-dismiss-doubled-to-2s-2026-09-10.
POPUP_DISMISS_IDLE_TICKS = 2

-- Idle ticks before an uncommitted browse puts the cursor back on the playing patch. Same units as
-- POPUP_DISMISS_IDLE_TICKS - browsePending also arms the ~1s tick, so 4 is roughly 4s. A screen left
-- pointing at a patch you did not select is a hazard on stage.
BROWSE_IDLE_TICKS = 4

-- Popup is a full-screen mode, so dismissal is just switching BACK to whatever mode was active
-- before it took over - reusing set_display_mode's own proven double-Clear-Screen/
-- drop_queued_display/invalidate_all/sacrificial-redraw sequence. popupActive is cleared BEFORE
-- that call so show_popup's 'is this a fresh popup' check is already correct if a new popup is
-- triggered again immediately after dismissal.
function dismiss_popup()
	popupActive = false
	set_display_mode(popupPreviousMode)
end

-- Puts an uncommitted browse back on the playing patch, once the ring has been still for
-- BROWSE_IDLE_TICKS. Called from the tick beside check_popup_dismiss().
function check_browse_revert()
	if not browsePending then return end
	if (idleTicks - browseLastActivityIdleTick) < BROWSE_IDLE_TICKS then return end
	browsePending = false
	cursorIndex = find_active_row_index()
	clamp_scroll()
	slog('browse reverted to the playing patch (cursor=' .. cursorIndex .. ')')
	update_screen()
end

-- Called once per timer tick (controller_timer_trigger), after idleTicks is updated for this tick.
function check_popup_dismiss()
	if popupActive and (idleTicks - popupLastActivityIdleTick) >= POPUP_DISMISS_IDLE_TICKS then
		dismiss_popup()
	end
end

-- Draws list row `i` (0-based, within the visible window) for `row` - one of the flat, normalised
-- listRows entries, or nil past the end of the list.
-- `isCursor` controls only the '> '/'  ' marker column, never the colour:
-- active state and cursor state are deliberately on separate channels (see
-- docs/full-functionality-plan.md), so there is no combined case to special-case here - a row that
-- is both simply gets ROW_ACTIVE's colours with a '> ' prefix, which reads correctly with nothing
-- extra written for it.
--
-- Every row - including a past-the-end blank one - draws at the SAME x and maxWidth (ROW_X,
-- ROW_MAXW), confirmed on hardware to make Write Text's background fill the whole box (see
-- docs/config-lua-history.md#settled-facts-max-width-and-the-write-text-background-box), so every
-- row is self-clearing: no erase rect, ever, on this screen. Indentation is two literal leading
-- spaces in the string, placed AFTER the marker column, never a change to x - that is what keeps
-- every row's background box identical (so highlight bars line up) and the '>' pinned to one
-- character position regardless of row kind.
function draw_list_row(i, row, isCursor)
	local y = ROW_Y0 + ROW_PITCH * i
	local id = 'row' .. i
	-- The bottom row stops short of the navigation icons' gutter; every other row spans the full width.
	local maxw = (i == ROW_COUNT - 1) and ROW_LAST_MAXW or ROW_MAXW

	if row == nil then
		local c = ROW_COLORS[ROW_PATCH]
		draw_text(id, '', ROW_X, y, maxw, ALIGN_LEFT, SIZE_SMALL, c[1], c[2], c[3], c[4], c[5], c[6])
		return
	end

	local isActive = row.isPatch and row.setIndex == activeSetIndex and row.patchIndex == activePatchIndex
	local state = ROW_PATCH
	if isActive then state = ROW_ACTIVE
	elseif not row.isPatch then state = ROW_HEADER
	end
	local c = ROW_COLORS[state]
	local marker = isCursor and '> ' or '  '
	local indent = row.isPatch and '  ' or ''
	draw_text(id, marker .. indent .. row.label, ROW_X, y, maxw, ALIGN_LEFT, SIZE_SMALL,
		c[1], c[2], c[3], c[4], c[5], c[6])
end

-- Finds the flat, 0-based listRows index of the currently ACTIVE patch (the one MainStage has
-- loaded - activeSetIndex/activePatchIndex), or 0 if none matches (e.g. before the first real patch
-- selection). Used both to keep cursorIndex tracking the active patch in Phase 1
-- (controller_select_patch) and to find where the NEXT patch search should start
-- (next_line_text()).
function find_active_row_index()
	for i = 1, #listRows do
		local row = listRows[i]
		if row.isPatch and row.setIndex == activeSetIndex and row.patchIndex == activePatchIndex then
			return i - 1
		end
	end
	return 0
end

-- Patch selection from the ring, confirmed working on hardware 2026-09-20 (MainStage 4.3.1): a Bank
-- Select pair followed by a Program Change selects a patch exactly - no scaling, no skipped patches, and
-- banks lift the 128-patch ceiling. Requires concert setup: Program Changes Device and Channel must admit
-- this device/channel, and the patches need program change numbers (MainStage's own reset command assigns
-- them in Patch List order). See
-- docs/mainstage-integration.md#the-ring-selects-patches-with-bank-select-and-program-change.
--
-- Queued for this round's injection, or nil. MainStage's Program Change Range is 1-128, so patch p shows
-- as PC p and goes on the wire as (p-1) % 128, with the bank as floor((p-1) / 128) - 0-based on the wire,
-- which MainStage displays as bank 1, 2, ... (verified across the 128 boundary).
pendingProgram = nil
pendingBank = nil

function queue_program(pc, bank)
	pendingProgram = pc
	pendingBank = bank
end

-- The cursor's ordinal among all patches in the concert - what a commit sends. Counts patches only, since
-- listRows interleaves set headers and a program change indexes patches.
function cursor_patch_ordinal()
	local n = 0
	for i = 1, #listRows do
		if listRows[i].isPatch then
			n = n + 1
			if i - 1 == cursorIndex then return n end
		end
	end
	return 1
end

-- Moves the browse cursor by `delta` PATCHES, skipping set headers - a header is not selectable, so the
-- cursor must never rest on one. Clamps at the first and last patch of the concert. Returns true only if
-- the cursor actually moved, which is what the joystick tilts use to decide whether to send a Program
-- Change at all (see handle_joystick_direction).
function move_browse_cursor(delta)
	local step = delta > 0 and 1 or -1
	local remaining = math.abs(delta)
	local start = cursorIndex
	local i = cursorIndex
	while remaining > 0 do
		local next_i = i + step
		-- Walk past headers rather than counting them as steps.
		while listRows[next_i + 1] ~= nil and not listRows[next_i + 1].isPatch do
			next_i = next_i + step
		end
		if listRows[next_i + 1] == nil then break end -- at an end: stop, do not wrap
		i = next_i
		remaining = remaining - 1
	end
	cursorIndex = i
	clamp_scroll()
	return cursorIndex ~= start
end

-- The 0-based listRows index of the first or last patch in the concert, or nil if there are none.
function edge_patch_index(last)
	local found = nil
	for i = 1, #listRows do
		if listRows[i].isPatch then
			found = i - 1
			if not last then return found end
		end
	end
	return found
end

-- The first patch of each set, in listRows order: { setIndex, index }, index 0-based. A set with no
-- patches of its own contributes nothing, so set stepping can never land the cursor on a header.
function set_entry_points()
	local starts, seen = {}, {}
	for i = 1, #listRows do
		local row = listRows[i]
		if row.isPatch and not seen[row.setIndex] then
			seen[row.setIndex] = true
			starts[#starts + 1] = { setIndex = row.setIndex, index = i - 1 }
		end
	end
	return starts
end

-- Moves the cursor to the first patch of the set `step` sets away from the cursor's own set, clamped at
-- the first and last set. From mid-set, step -1 therefore lands on the top of the PREVIOUS set, not the
-- top of the current one. Returns true only if the cursor moved.
function move_cursor_by_set(step)
	local starts = set_entry_points()
	if #starts == 0 then return false end
	local row = listRows[cursorIndex + 1]
	local pos = 1
	for k = 1, #starts do
		if row ~= nil and starts[k].setIndex == row.setIndex then pos = k end
	end
	local target = pos + step
	if target < 1 then target = 1 elseif target > #starts then target = #starts end
	if starts[target].index == cursorIndex then return false end
	cursorIndex = starts[target].index
	clamp_scroll()
	return true
end

-- Moves the cursor to the first or last patch of the concert. Returns true only if it moved.
function move_cursor_to_edge(last)
	local target = edge_patch_index(last)
	if target == nil or target == cursorIndex then return false end
	cursorIndex = target
	clamp_scroll()
	return true
end

function concert_patch_count()
	local n = 0
	for i = 1, #listRows do
		if listRows[i].isPatch then n = n + 1 end
	end
	return n
end

-- The ACTIVE patch's 1-based ordinal position among patches in its OWN set (activeSetIndex), and
-- that set's total patch count - 'patch 3 of 7 in this song', for the zoom screen's zpos line (see
-- paint_zoom_screen()). Counts only listRows entries with isPatch true AND setIndex ==
-- activeSetIndex, in listRows order, which is the same order MainStage's own patchlist uses within
-- a set - so this is a real 'position in the setlist', not a derived index. Returns 0, 0 if
-- activeSetIndex has no patches (listRows empty, or a state before the first real patch selection),
-- matching the graceful '0/0' this replaced.
function zoom_position_in_set()
	local pos, total = 0, 0
	for i = 1, #listRows do
		local row = listRows[i]
		if row.isPatch and row.setIndex == activeSetIndex then
			total = total + 1
			if row.patchIndex == activePatchIndex then pos = total end
		end
	end
	return pos, total
end

-- Finds the label of the nearest set header at or before cursorIndex, for the context bar. Phase
-- 1's cursor always sits on a patch row (it tracks the active patch - see controller_select_patch),
-- so this always finds a real header unless the list itself is empty.
function cursor_set_label()
	for i = cursorIndex + 1, 1, -1 do
		local row = listRows[i]
		if row and not row.isPatch then return row.label end
	end
	return ''
end

-- 'concert - set': the context bar's content. A plain ASCII hyphen, NOT a middle dot - the SLMK2
-- font only covers 0x20-0x80 (see append_text), so a middle dot would render as two spaces. See
-- docs/config-lua-history.md#typography-substitutions-non-ascii-glyphs.
function ctx_text()
	return currentConcert .. ' - ' .. cursor_set_label()
end

-- The context bar: y=2, dim grey, replacing the old per-set header. In a continuous list you
-- routinely scroll past a set header and lose track of which set you are in - this shows it in one
-- line, and redraws only when its CONTENT changes, for free, via the same per-region memoization
-- every other draw uses here (which is exactly "only when the cursor crosses into a different set",
-- since that is the only thing that can change cursor_set_label()'s result while browsing within a
-- set).
function draw_ctx()
	-- SIZE_MEDIUM, a size up from the rows below it: this line names the concert/set/patch context and is
	-- read at a glance. Its box is then 2..25 (TEXT_H_MEDIUM), still clear of ROW_Y0 at 30. The sacrificial
	-- duplicate in queue_sacrificial_redraw MUST use the same size, or it repaints a shorter box over this
	-- one and leaves the bottom of the glyphs behind.
	-- Blue, not grey: this line is structure rather than a patch, the same distinction ROW_COLORS draws
	-- between a set header and a patch row. Taken from ROW_COLORS[ROW_HEADER] so the convention lives in
	-- one place; amber stays reserved for the ACTIVE patch alone (the navigation icons are white).
	--
	-- SIZE_SMALL, not MEDIUM: at medium this line's 35 characters overflowed the 304px box and the SL88's
	-- own Max Width truncation mangled it to 'Jose..' (hardware, 2026-09-21). Concert plus set name only
	-- fits at small. The sacrificial duplicate must match size AND colour - see queue_sacrificial_redraw.
	local c = ROW_COLORS[ROW_HEADER]
	draw_text('ctx', ctx_text(), ROW_X, 2, ROW_MAXW, ALIGN_LEFT, SIZE_SMALL,
		c[1], c[2], c[3], 0, 0, 0)
end

-- Draws the list screen's current model, memoized per region - repeat calls with nothing changed
-- queue nothing. No trailing sacrificial here - both update_screen and paint_screen add it
-- themselves, after calling this, via queue_sacrificial_redraw() (see that function for why it now
-- covers both paths). Every list-mode draw call passes ALIGN_LEFT (draw_ctx() and draw_list_row(),
-- including the blank past-end-of-list row) - the single-line ctx bar replaced an older two-line
-- header with a right-aligned n/N counter, which no longer exists in this codebase. If a
-- right-aligned counter is ever reported as visible on hardware, suspect stale content from an
-- unreliable mode-switch erase (see
-- docs/config-lua-history.md#fix-5-audit-the-first-switch-anomaly) before assuming one needs to be
-- added here.
function paint_list_screen()
	draw_ctx()
	-- Bottom right: the two tilt pairs select a patch/set outright, the rotate icon says the ring browses
	-- this list, and the push icon lights while a browsed patch is waiting for the press. See NAV_ICON_Y.
	local dim, lit = NAV_ICON_DIM, NAV_ICON_LIT
	draw_bitmap('navUpDown', NAV_UPDOWN_X, NAV_ICON_Y, BMP_GROUP_NAV, BMP_ICON_UPDOWN,
		lit[1], lit[2], lit[3], 0, 0, 0)
	draw_bitmap('navLeftRight', NAV_LEFTRIGHT_X, NAV_ICON_Y, BMP_GROUP_NAV, BMP_ICON_LEFTRIGHT,
		lit[1], lit[2], lit[3], 0, 0, 0)
	draw_bitmap('navRing', NAV_RING_X, NAV_ICON_Y, BMP_GROUP_NAV, BMP_ICON_ROTATE,
		lit[1], lit[2], lit[3], 0, 0, 0)
	local pushColor = browsePending and lit or dim
	draw_bitmap('navPush', NAV_PUSH_X, NAV_ICON_Y, BMP_GROUP_NAV, BMP_ICON_PUSH,
		pushColor[1], pushColor[2], pushColor[3], 0, 0, 0)
	for i = 0, ROW_COUNT - 1 do
		local row = listRows[scrollOffset + i + 1]
		local isCursor = (scrollOffset + i == cursorIndex)
		draw_list_row(i, row, isCursor)
	end
end

-- Truncates `text` to at most `maxChars` characters, cutting to maxChars - 3 and appending '...'
-- (plain ASCII full stops - the SLMK2 font only covers 0x20-0x80, see append_text) when it doesn't
-- fit. Used instead of the SL88's own Max Width truncation, which is confirmed broken at SIZE_BIG
-- (see BIG_MAX_CHARS's comment above) - both the patch name and the set name are truncated here in
-- the script and drawn with maxWidth=0.
function truncate_text(text, maxChars)
	text = text or ''
	if #text <= maxChars then
		return text
	end
	return text:sub(1, maxChars - 3) .. '...'
end

-- 'NEXT' line for the zoom screen: the next listRows entry after the ACTIVE patch with isPatch
-- true, skipping set headers - i.e. what you are about to change to. The prompt word itself carries
-- whether that patch starts a new song (rather than trying to also fit the set's name on the line),
-- since a song boundary matters more mid-performance than the destination set's name. Returns the
-- no-next form at the end of the concert.
function next_line_text()
	local activeIndex = find_active_row_index()
	for i = activeIndex + 2, #listRows do
		local row = listRows[i]
		if row.isPatch then
			local word = (row.setIndex ~= activeSetIndex) and 'NEXT SONG' or 'NEXT'
			return word .. '  ' .. row.label
		end
	end
	-- End of the concert: no next patch. NOT an em dash - the SLMK2 font range is 0x20-0x80 (see
	-- append_text) - a plain ASCII substitute instead. See
	-- docs/config-lua-history.md#typography-substitutions-non-ascii-glyphs.
	return 'NEXT  --'
end

-- Draws the zoom screen's current model, memoized per region. Shows the ACTIVE patch, not the
-- cursor - 'what am I playing right now' - plus, on znext, what you are about to change to. Single
-- truncated line, not two wrapped lines - wrapping was tried and left stale text on the second line
-- (see docs/config-lua-history.md#max-width-truncation-broken-at-size_big).
--
-- zname and zset both draw at a real, non-zero maxWidth now and let the DEVICE's own ALIGN_CENTER
-- centre them - CONFIRMED on hardware 2026-08-29 (SL88 MK2 + MainStage: zset/zname render correctly
-- centred, the too-far-right symptom is gone, 0 Lua errors over a 255-tick session) - see
-- docs/config-lua-history.md#zoom-screen-centring-moved-to-the-device-2026-08-29 for the full
-- observation and for why the previous approach (maxWidth=0 plus a Lua pixel-width estimate to fake
-- centring) was abandoned: both lines rendered slightly right of centre no matter how the
-- per-character width constants were retuned, so the estimate itself was the wrong tool. That same
-- run's visible truncation '...' on long names is truncate_text()'s own ASCII ellipsis, added before
-- either line ever reaches the device - NOT evidence the device's own SIZE_BIG Max Width truncation
-- is fixed; that bug stays on the books as unresolved (see BIG_MAX_CHARS's comment: Max Width
-- TRUNCATION, a different device feature from centring, is confirmed broken at SIZE_BIG), and
-- pre-truncation in Lua is what keeps the device from ever having to truncate a name itself. A real
-- maxWidth also makes both lines self-clearing (Write Text's background fills the whole box - see
-- "Settled facts" in docs/config-lua-history.md), so neither needs an erase rect any more - confirmed
-- on the same 2026-08-29 run: zero regionId messages split as z*:rect/z*:text appeared on the wire.
-- REVERT PATH: if a long patch name ever renders on hardware as a single letter plus '...', the
-- device's own truncation is firing again - go back to maxWidth=0 with manual ALIGN_LEFT centring
-- (see that same docs section for the removed implementation) rather than retuning anything here.
-- znext always draws SIZE_SMALL, at a real maxWidth, unconditionally - it never needed this
-- migration. Layout
-- (docs/full-functionality-plan.md): zcnc y=12, zset y=44, zname y=100, znext y=170, zpos y=210 -
-- bands 12-33 / 44-71 / 100-133 / 170-191 / 210-231, all non-overlapping. Retune together with
-- ROW_Y0-style constants if the layout ever moves again.
function paint_zoom_screen()
	draw_text('zcnc', currentConcert, 8, 12, 304, ALIGN_CENTER, SIZE_SMALL, 120, 120, 120, 0, 0, 0)

	draw_text('zset', truncate_text(setName, MEDIUM_MAX_CHARS), 8, 44, SCREEN_WIDTH - 16,
		ALIGN_CENTER, SIZE_MEDIUM, 110, 170, 230, 0, 0, 0)

	draw_text('zname', truncate_text(patchName, BIG_MAX_CHARS), 8, 100, SCREEN_WIDTH - 16,
		ALIGN_CENTER, SIZE_BIG, 255, 255, 255, 0, 0, 0)

	-- SIZE_SMALL + trusted Max Width, unconditionally - no truncate_text() needed, unlike zname/zset
	-- above: SIZE_SMALL is the one regime list rows already trust Max Width TRUNCATION in, so it
	-- needs no hardware check first.
	draw_text('znext', next_line_text(), 8, 170, SCREEN_WIDTH - 16, ALIGN_CENTER, SIZE_SMALL,
		80, 200, 120, 0, 0, 0)

	-- n/N: the ACTIVE patch's ordinal position among patches in its OWN set - 'patch 3 of 7 in this
	-- song', matching what the zoom screen actually shows (the active set/patch, not the cursor - a
	-- flat position across ALL listRows, 'row 41 of 98', does not answer the question this counter
	-- exists to answer). See zoom_position_in_set().
	local n, total = zoom_position_in_set()
	draw_text('zpos', n .. '/' .. total, ZOOM_POS_X, 210, ZOOM_POS_W, ALIGN_CENTER, SIZE_SMALL,
		120, 120, 120, 0, 0, 0)

	-- The tilt pairs, level with the counter: the joystick selects patches and sets on the zoom screen too.
	-- The ring and press are deliberately absent here - a ring turn switches to the list before it browses,
	-- so there is never a pending browse to commit from this screen. See ZOOM_NAV_Y.
	local lit = NAV_ICON_LIT
	draw_bitmap('zNavUpDown', ZOOM_NAV_UPDOWN_X, ZOOM_NAV_Y, BMP_GROUP_NAV, BMP_ICON_UPDOWN,
		lit[1], lit[2], lit[3], 0, 0, 0)
	draw_bitmap('zNavLeftRight', ZOOM_NAV_LEFTRIGHT_X, ZOOM_NAV_Y, BMP_GROUP_NAV, BMP_ICON_LEFTRIGHT,
		lit[1], lit[2], lit[3], 0, 0, 0)
end

-- MARK: - Config screen
--
-- A third full display mode ('config', alongside 'list'/'zoom'/'popup'), toggled by the Global
-- button: the script version and the whole CC map, for reading the mapping off the keyboard instead
-- of the docs. Scrolled by the joystick ring, which suppresses its own CC while this screen shows
-- (see handle_sl_frame's IT_ENCODER branch). Layout agreed with Jeroen; see
-- docs/config-lua-history.md#the-config-screen-2026-09-20.
-- The title line (name + version) is SIZE_MEDIUM, the rest SIZE_SMALL: it is the screen's heading,
-- readable at a glance. Everything below it shifted down by the extra glyph height (TEXT_H_MEDIUM 23
-- vs TEXT_H_SMALL 18) and the row pitch tightened to 22 to keep 7 rows above the footer - the
-- harness asserts every band still clears the next.
CONFIG_TITLE_Y = 2
CONFIG_HEADER_Y = 30
CONFIG_RULE_Y = 52
CONFIG_ROW_Y0 = 58
CONFIG_ROW_PITCH = 22
CONFIG_ROW_COUNT = 7
CONFIG_FOOTER_Y = 216

-- Two columns: the control's name left, its SHORT/LONG CC pair as ONE right-aligned string. One
-- draw for the pair rather than two columns of text - every CC is two digits, so they line up
-- without a fixed-width font, and it halves the messages a page costs.
CONFIG_NAME_X = 8
CONFIG_NAME_W = 190
CONFIG_CC_X = 200
CONFIG_CC_W = 104

CONFIG_ICON_X = 8 -- the rotate icon marks the joystick ring as this screen's scroller
CONFIG_COUNT_X = 150
CONFIG_COUNT_W = 162

-- One row per control: { SHORT key, LONG key }, both CC_MAP keys, LONG nil for a turn-only control.
-- Written out explicitly, one per line, so the rows can be compared by eye against CC_MAP above.
-- The displayed NAME is not repeated here - it comes from CC_LABEL[short], so there is no third copy
-- of the names to drift. The harness asserts this covers every CC_MAP key exactly once.
CONFIG_ROWS = {
	{ 'ENC1_PRESS_SHORT', 'ENC1_PRESS_LONG' },
	{ 'ENC2_PRESS_SHORT', 'ENC2_PRESS_LONG' },
	{ 'ENC3_PRESS_SHORT', 'ENC3_PRESS_LONG' },
	{ 'ENC4_PRESS_SHORT', 'ENC4_PRESS_LONG' },
	{ 'ENC1_TURN' },
	{ 'ENC2_TURN' },
	{ 'ENC3_TURN' },
	{ 'ENC4_TURN' },
	{ 'ENCB_TURN' },
	{ 'ENCB_PRESS_SHORT', 'ENCB_PRESS_LONG' },
	{ 'SEL1_SHORT', 'SEL1_LONG' },
	{ 'SEL2_SHORT', 'SEL2_LONG' },
	{ 'SEL3_SHORT', 'SEL3_LONG' },
	{ 'SEL4_SHORT', 'SEL4_LONG' },
}

-- Top visible CONFIG_ROWS index (0-based), driven by the joystick ring.
configScroll = 0

-- displayMode to restore when the config screen is dismissed - same idiom as popupPreviousMode.
configPreviousMode = nil

function config_max_scroll()
	local max = #CONFIG_ROWS - CONFIG_ROW_COUNT
	if max < 0 then max = 0 end
	return max
end

-- Its own clamp, not clamp_scroll(): that one is about cursorIndex and SCROLL_MARGIN, neither of
-- which exists here - this list has no cursor, just a window.
function scroll_config(delta)
	local before = configScroll
	local v = configScroll + delta
	if v < 0 then v = 0 end
	local max = config_max_scroll()
	if v > max then v = max end
	configScroll = v
	return configScroll ~= before
end

-- '40  41' for a pair, '50   -' for a turn-only control - the dash holds the SHORT column's digits
-- in place rather than letting a lone number drift into the LONG column.
function config_cc_text(row)
	local short = CC_MAP[row[1]]
	local long = row[2] ~= nil and CC_MAP[row[2]] or nil
	if long == nil then return tostring(short) .. '   -' end
	return tostring(short) .. '  ' .. tostring(long)
end

function paint_config_screen()
	local hc = ROW_COLORS[ROW_HEADER]
	local rc = ROW_COLORS[ROW_PATCH]

	draw_text('cfgTitle', 'CONFIG', CONFIG_NAME_X, CONFIG_TITLE_Y, CONFIG_NAME_W, ALIGN_LEFT,
		SIZE_MEDIUM, hc[1], hc[2], hc[3], hc[4], hc[5], hc[6])
	draw_text('cfgVer', 'v' .. SCRIPT_VERSION, CONFIG_CC_X, CONFIG_TITLE_Y, CONFIG_CC_W, ALIGN_RIGHT,
		SIZE_MEDIUM, rc[1], rc[2], rc[3], rc[4], rc[5], rc[6])

	-- Header and rule do not scroll with the rows.
	draw_text('cfgHdrName', 'CONTROL', CONFIG_NAME_X, CONFIG_HEADER_Y, CONFIG_NAME_W, ALIGN_LEFT,
		SIZE_SMALL, hc[1], hc[2], hc[3], hc[4], hc[5], hc[6])
	draw_text('cfgHdrCC', 'SHORT  LONG', CONFIG_CC_X, CONFIG_HEADER_Y, CONFIG_CC_W, ALIGN_RIGHT,
		SIZE_SMALL, hc[1], hc[2], hc[3], hc[4], hc[5], hc[6])
	draw_rect('cfgRule', CONFIG_NAME_X, CONFIG_RULE_Y, SCREEN_WIDTH - 2 * CONFIG_NAME_X, 1,
		hc[1], hc[2], hc[3])

	for i = 0, CONFIG_ROW_COUNT - 1 do
		local row = CONFIG_ROWS[configScroll + i + 1]
		local y = CONFIG_ROW_Y0 + CONFIG_ROW_PITCH * i
		local name = row ~= nil and (CC_LABEL[row[1]] or row[1]) or ''
		local ccs = row ~= nil and config_cc_text(row) or ''
		draw_text('cfg' .. i, name, CONFIG_NAME_X, y, CONFIG_NAME_W, ALIGN_LEFT, SIZE_SMALL,
			rc[1], rc[2], rc[3], rc[4], rc[5], rc[6])
		draw_text('cfgv' .. i, ccs, CONFIG_CC_X, y, CONFIG_CC_W, ALIGN_RIGHT, SIZE_SMALL,
			rc[1], rc[2], rc[3], rc[4], rc[5], rc[6])
	end

	draw_bitmap('cfgIcon', CONFIG_ICON_X, CONFIG_FOOTER_Y, BMP_GROUP_NAV, BMP_ICON_ROTATE,
		hc[1], hc[2], hc[3], 0, 0, 0)
	local first = configScroll + 1
	local last = math.min(configScroll + CONFIG_ROW_COUNT, #CONFIG_ROWS)
	draw_text('cfgFoot', first .. '-' .. last .. '/' .. #CONFIG_ROWS, CONFIG_COUNT_X,
		CONFIG_FOOTER_Y, CONFIG_COUNT_W, ALIGN_RIGHT, SIZE_SMALL,
		rc[1], rc[2], rc[3], rc[4], rc[5], rc[6])
end

-- Ordinary content-driven redraw: draws the current model, memoized per region, and queues NOTHING
-- beyond whatever actually changed (2 messages for a patch change within a set, 9 for a set change,
-- 0 if nothing differs - see docs/mainstage-integration.md's redraw cost figures) PLUS the trailing
-- sacrificial redraw below when anything real was queued - see queue_sacrificial_redraw()'s comment
-- for why this MUST run here too, not only from paint_screen's full repaint.
--
-- Does NOT call drop_queued_display() at the top - per-region coalescing in queue_message()
-- supersedes a stale queued region in place, so nothing needs to be thrown away first. Do not
-- reintroduce a "drop everything, then re-queue" step here; it starves rows under rapid patch
-- changes (see queue_message's coalescing comment).
function update_screen()
	-- 3-way dispatch, matching paint_screen's - a content change (patch/set change from MainStage) can
	-- land while displayMode=='popup' and must redraw the popup's own content, not incorrectly paint
	-- list/zoom underneath a mode that's still supposed to be showing.
	local before = queuedDisplayOps
	if displayMode == 'popup' then
		paint_popup_screen()
	elseif displayMode == 'zoom' then
		paint_zoom_screen()
	elseif displayMode == 'config' then
		-- Content-independent, so memoization makes this a no-op unless the scroll moved - a patch
		-- change from MainStage must not repaint the list underneath the config screen.
		paint_config_screen()
	else
		paint_list_screen()
	end
	if queuedDisplayOps > before then
		queue_sacrificial_redraw()
	end
	lastPaintedPatch = patchName
	lastPaintTick = idleTicks
	slog('update queued (' .. #pendingMessages .. ' msgs) mode=' .. displayMode ..
		' "' .. patchName .. '"')
end

-- Drops display messages still sitting in the queue. Used only where the queue's content is
-- genuinely garbage, not merely stale-but-wanted - see set_display_mode, its one remaining caller:
-- switching modes vacates the whole screen, so anything still queued for the outgoing mode cannot
-- be coalesced into anything the new mode will ever draw. Protocol messages (identification,
-- logout, ...) are preserved.
--
-- MUST undo the memo for exactly the id(s) it discards (drawn[m.regionId] = nil), so the next paint
-- re-queues them. draw_text/draw_rect record drawn[id] the moment they QUEUE a message, not when it
-- is actually sent - without this undo, a message discarded here before it ever goes out leaves
-- drawn[id] permanently claiming the region was painted, and the memo and the physical screen
-- diverge for good. Do not reintroduce 'update the memo at queue time' without also undoing it here
-- on drop. See docs/config-lua-history.md#drop_queued_display-and-the-memo-vs-screen-divergence-bug.
--
-- Used to unwind an id..':rect'/id..':text' coalescing-key split via a base_region_id() helper -
-- the zoom screen's zset/zname were the only source of that split (the since-removed
-- draw_text_with_erase()). Nothing produces a split regionId any more, so m.regionId IS the
-- drawn[] key directly and that helper was removed with it - see
-- docs/config-lua-history.md#zoom-screen-centring-moved-to-the-device-2026-08-29.
function drop_queued_display()
	local keep = {}
	for i = 1, #pendingMessages do
		local m = pendingMessages[i]
		if m[8] ~= IT_DISPLAY then
			keep[#keep + 1] = m
		elseif m.regionId then
			drawn[m.regionId] = nil
		end
	end
	pendingMessages = keep
end

-- TRAILING SACRIFICIAL REDRAW, shared by paint_screen, update_screen AND set_display_mode - all
-- three MUST call this after queuing real content.
--
-- Empirically the FINAL flush of a repaint never takes effect: whichever display message ends up
-- last is silently lost, regardless of content, size, or what it's bundled with - swapping the draw
-- order just moves the loss to whatever is now last. See
-- docs/config-lua-history.md#the-trailing-sacrificial-redraw. So end any real screen update with a
-- harmless duplicate: re-drawing the concert line is idempotent, so it costs one extra message and
-- is safe to lose, while everything that matters now has something following it. Every caller gates
-- this on having actually queued something real - an all-memoized no-op call has no 'last real
-- message' that needs a harmless successor.
--
-- MUST build and queue the message DIRECTLY, bypassing draw_text(), and with NO regionId. A nil
-- regionId always appends (see queue_message) - routing this through draw_text('ctx', ...) would
-- instead hand it the SAME regionId as the real ctx/zcnc draw earlier in this same paint's queue
-- and coalesce into that entry, collapsing the one thing this mechanism must guarantee (a
-- disposable duplicate strictly AFTER everything real).
--
-- While a popup is showing, displayMode is 'popup', not the mode it covers - the duplicate must
-- match what's underneath (popupPreviousMode), or it paints the WRONG screen's line over the
-- other one (see docs/config-lua-history.md#sacrificial-redraw-painted-the-list-line-under-a-
-- popup-2026-09-14). Falls back to 'zoom' if popupPreviousMode is somehow unset, matching
-- displayMode's own declared default.
function queue_sacrificial_redraw()
	local underlyingMode = displayMode
	if displayMode == 'popup' then
		underlyingMode = popupPreviousMode or 'zoom'
	end
	if underlyingMode == 'zoom' then
		queue_message(msg_write_text(currentConcert, 8, 12, 304, ALIGN_CENTER, SIZE_SMALL,
			120, 120, 120, 0, 0, 0))
	elseif underlyingMode == 'config' then
		-- The config screen's own title line, redrawn identically. The list's ctx line below would
		-- paint the wrong screen's text over this one - the popup bug in
		-- docs/config-lua-history.md#sacrificial-redraw-painted-the-list-line-under-a-popup-2026-09-14.
		local hc = ROW_COLORS[ROW_HEADER]
		queue_message(msg_write_text('CONFIG', CONFIG_NAME_X, CONFIG_TITLE_Y, CONFIG_NAME_W,
			ALIGN_LEFT, SIZE_MEDIUM, hc[1], hc[2], hc[3], hc[4], hc[5], hc[6]))
	else
		-- Size AND colour must match draw_ctx() byte for byte - see the note there.
		local c = ROW_COLORS[ROW_HEADER]
		queue_message(msg_write_text(ctx_text(), ROW_X, 2, ROW_MAXW, ALIGN_LEFT, SIZE_SMALL,
			c[1], c[2], c[3], 0, 0, 0))
	end
end

-- FULL repaint: draws everything for the current mode, relying on the caller having invalidated
-- first (handle_login, handle_restart, and the self-heal branch in handle_sl_frame all call
-- invalidate_all() before this) so every region actually resends rather than being skipped as
-- unchanged. Ordinary content-driven updates (a patch/set change from MainStage) go through
-- update_screen() instead, which also ends with queue_sacrificial_redraw() - see that function's
-- comment for why both paths need it. Does NOT call drop_queued_display() at the top - see
-- update_screen's comment on why that's unnecessary once invalidate_all() has run.
--
-- The SL88 keeps no display state across Standby, so this is also what a Restart triggers.
function paint_screen()
	-- NO Clear Screen here (rule 3 in the banner) - Write Text "completely overwrites any existing
	-- content on the screen pixels within the area where the text is printed"
	-- (sl-link/docs/display-messages.md), so redrawing the same regions is self-cleaning. See
	-- docs/config-lua-history.md#the-clear-screen-ban-and-its-lift for what this ban was protecting
	-- against.

	-- 3-way dispatch: if an ordinary content-driven repaint lands while a popup happens to be showing
	-- (e.g. a patch change arriving mid-popup), this must redraw the POPUP's own content again, not
	-- incorrectly repaint list/zoom underneath a mode that's still supposed to be showing.
	local before = queuedDisplayOps
	if displayMode == 'popup' then
		paint_popup_screen()
	elseif displayMode == 'zoom' then
		paint_zoom_screen()
	elseif displayMode == 'config' then
		paint_config_screen()
	else
		paint_list_screen()
	end

	-- Trailing sacrificial redraw - see queue_sacrificial_redraw()'s comment.
	if queuedDisplayOps > before then
		queue_sacrificial_redraw()
	end

	lastPaintedPatch = patchName
	lastPaintTick = idleTicks
	slog('paint queued (' .. #pendingMessages .. ' msgs) mode=' .. displayMode ..
		' "' .. patchName .. '"')
end

-- Mode switching. Wired to the Home button (BID_HOME, confirmed on hardware - see
-- handle_home_button).
--
-- The ONE place in the file that sends Clear Screen (rule 3 in the banner bans it everywhere else).
-- MUST stay queued as its own discrete message with no regionId - never coalesced, never bundled
-- into an array with a Write Text - and paired with the SETTLE guard (displaySettleTicks). See
-- docs/config-lua-history.md#the-clear-screen-ban-and-its-lift for why, and the documented fallback
-- (a full-screen black msg_draw_rect) if remnants or dropped lines return on hardware.
--
-- An unexplained 'first switch differs from later ones' anomaly was chased here and not root-caused
-- - see docs/config-lua-history.md#fix-5-audit-the-first-switch-anomaly before assuming this
-- function branches correctly on 'is this the first switch' (it doesn't - nothing here does).
function set_display_mode(mode)
	if mode ~= 'list' and mode ~= 'zoom' and mode ~= 'popup' and mode ~= 'config' then return end
	displayMode = mode
	drop_queued_display()
	invalidate_all()
	-- MUST queue the Clear Screen TWICE, as two SEPARATE messages with no regionId (queue_message
	-- never coalesces without one), each earning its own flush. Do not collapse this back to one
	-- queue_message() call. flush_pending always appends the Identification Query to whatever it
	-- emits, so a single Clear Screen goes out bundled with the query in one MIDI array - confirmed on
	-- hardware to be an unreliable shape (only [display, query] alone, or [display] first, ever
	-- reliably painted; see docs/config-lua-history.md#the-double-clear-screen). It is idempotent, and
	-- a dropped copy costs nothing but one extra flush. flush_pending's settle-guard
	-- (displaySettleTicks) resets on EVERY Clear Screen it emits, so the settle window still lands
	-- after the LAST one.
	queue_message(msg_clear_screen(0, 0, 0))
	queue_message(msg_clear_screen(0, 0, 0))
	local before = queuedDisplayOps
	if mode == 'popup' then
		paint_popup_screen()
	elseif mode == 'zoom' then
		paint_zoom_screen() -- redundant with the full-screen erase above, but each name draw erases its own band anyway
	elseif mode == 'config' then
		paint_config_screen()
	else
		paint_list_screen()
	end
	-- MUST end with the same trailing sacrificial redraw paint_screen/ update_screen use - see
	-- queue_sacrificial_redraw()'s comment; without it the LAST message of a mode switch (zpos in
	-- zoom, or the last visible row in list) is exposed to the same "final flush is silently dropped"
	-- finding. Same gate: only queue it if real content was queued.
	if queuedDisplayOps > before then
		queue_sacrificial_redraw()
	end
	lastPaintedPatch = patchName
	lastPaintTick = idleTicks
	-- Always has real content queued here (Clear Screen plus a guaranteed-non-empty repaint, since
	-- invalidate_all() above forces every region to resend) - see request_quick_rearm's comment.
	request_quick_rearm()
	slog('display mode -> ' .. mode)
end

-- Entering the popup overlay, unlike set_display_mode(), skips Clear Screen and invalidate_all() -
-- see docs/config-lua-history.md#popup-entry-skips-clear-screen-2026-09-12 for why (both are the
-- expensive part; the popup's own content is not). draw_popup_erase() still blanks the whole panel
-- as its own first message, so nothing already on screen can show through while the border/label/
-- knob/value messages that follow are still draining one per tick - see
-- docs/config-lua-history.md#popup-entry-always-erases-its-full-region-first-2026-09-12.
-- dismiss_popup() still uses the full set_display_mode() to restore whatever the popup covered.
function enter_popup_mode()
	displayMode = 'popup'
	drop_queued_display()
	local before = queuedDisplayOps
	draw_popup_erase()
	paint_popup_screen()
	if queuedDisplayOps > before then
		queue_sacrificial_redraw()
	end
	request_quick_rearm()
end


-- MARK: - Session

function start_identification()
	state = STATE_IDENTIFYING
	identifyResendsLeft = MAX_IDENTIFY_RESENDS
	identifyFallback = false
	queue_message(msg_identification_request())
	slog('-> Identification Request as (' ..
		string.format('%02X %02X', SL_HOST_ID, instanceID) .. ') on outport=' .. SL_PORT)
end

function handle_identification_approved()
	state = STATE_LISTED
	-- Any Identification Request still queued is now obsolete, and at one message per tick a deep
	-- queue can hold one for many ticks - it would go out after approval and draw a REJECTED that
	-- restarts the whole retry cycle. See docs/config-lua-history.md#stale-identification-requests-2026-09-17.
	drop_queued_identification_requests()
	-- Cleanly cancels any pending reidentify-wait: this instanceID is now confirmed good, so a LATER
	-- rejection (a fresh re-init down the line) should get the full retry budget again, not whatever
	-- was left over.
	reidentifyRetriesLeft = MAX_SAME_ID_RETRIES
	slog('<- IDENTIFICATION APPROVED as ' ..
		string.format('%02X %02X', SL_HOST_ID, instanceID) ..
		' - now in the SL88 APP list; select it there to activate')
end

-- Reason 0x00 = DeviceID taken/reserved - usually OUR OWN previous incarnation's still-live
-- registration after a MainStage-driven re-init (see REIDENTIFY_WAIT_MS's comment for why bumping
-- the id immediately would be wrong here). Wait out REIDENTIFY_WAIT_MS and retry the SAME id first;
-- only fall back to bumping the instance byte after MAX_SAME_ID_RETRIES failed retries. See
-- docs/config-lua-history.md#identification-and-instance-id-collisions.
function handle_identification_rejected(reason)
	slog('<- IDENTIFICATION REJECTED (reason ' ..
		string.format('%02X', reason or 0) .. ') for instance ' ..
		string.format('%02X', instanceID))

	-- We only ever send an Identification Request while identifying, so a rejection arriving once we
	-- are already approved is the echo of a stale request, not a real collision - acting on it would
	-- tear down a working session. See the same anchor as handle_identification_approved.
	if state == STATE_LISTED or state == STATE_ACTIVE or state == STATE_STANDBY then
		slog('  ignored - already approved, so this is a stale request echo')
		return
	end

	if reidentifyRetriesLeft > 0 then
		reidentifyRetriesLeft = reidentifyRetriesLeft - 1
		state = STATE_REIDENTIFY_WAIT
		-- Not rearm_timer() - this must WIN over the FLUSH_SOON_MS/KEEPALIVE_MS that inbound traffic
		-- would otherwise re-arm it to (see rearm_timer's STATE_REIDENTIFY_WAIT guard, which is what
		-- stops that overwrite from happening on every subsequent inbound frame during the wait).
		settriggertimer(REIDENTIFY_WAIT_MS)
		-- This call genuinely arms a fresh one-shot (unlike controller_timer_trigger's own
		-- top-of-function call - see timerPending's declaration), so timerPending must reflect that:
		-- keeps rearm_timer's gating honest once the wait ends and normal inbound traffic resumes calling
		-- it.
		timerPending = true
		-- Not KEEPALIVE_MS: request_quick_rearm() must never shorten THIS wait (see its own
		-- STATE_REIDENTIFY_WAIT guard, which is belt-and-suspenders for the same reason - this value
		-- alone already keeps its `timerArmedInterval == KEEPALIVE_MS` check from matching).
		timerArmedInterval = REIDENTIFY_WAIT_MS
		slog('re-identify retry ' ..
			(MAX_SAME_ID_RETRIES - reidentifyRetriesLeft) .. '/' .. MAX_SAME_ID_RETRIES ..
			' as (' .. string.format('%02X %02X', SL_HOST_ID, instanceID) .. ')')
		return
	end

	instanceID = instanceID + 1
	if instanceID > SL_INSTANCE_MAX then instanceID = SL_INSTANCE_MIN end
	reidentifyRetriesLeft = MAX_SAME_ID_RETRIES
	slog('bumping instance to ' ..
		string.format('%02X %02X', SL_HOST_ID, instanceID) .. ' after ' ..
		MAX_SAME_ID_RETRIES .. ' failed retries')
	start_identification()
end

-- Sets masterMuted and (re)sends the A encoder's LED to match - on/off only, see
-- docs/implementing-sl-link.md §6. Called for every real state change (button toggle, LONG reset,
-- a differing READ reply) and once at session start to establish the LED - see enter_active_session.
function set_master_mute(muted)
	masterMuted = muted
	queue_message(msg_white_led(WLID_A_ENC, not muted))
	slog('-> A ENCODER LED: ' .. (muted and 'muted' or 'unmuted'))
end

-- Builds, logs and queues a Master Volume READ to sync masterVolume with the hardware's current
-- value. Split out so handle_login can force one even when enter_active_session() is a no-op.
-- Diagnostic only, issued once per session (see docs/config-lua-history.md#master-volume-writes-take-effect-without-a-paired-read-probe-four-phase-result-2026-09-13) -
-- no longer polled per EID_A tick.
function queue_master_volume_read()
	local mvolReadMsg = msg_master_volume_read()
	slog('-> MASTER VOLUME READ: ' .. dump_bytes(mvolReadMsg))
	queue_message(mvolReadMsg)
end

-- Called once per timer tick (controller_timer_trigger), after idleTicks is updated - same shape as
-- check_popup_dismiss(). Fires once per gesture (mvolSettlePending is set by every EID_A tick, cleared
-- here): a dropped FINAL write of a gesture has no successor to correct it, so the value is repeated
-- the same way mute/LED writes are (a single drop is otherwise unrecoverable). The read that follows is
-- diagnostic only - see docs/config-lua-history.md#settle-resend-of-the-final-master-volume-write-2026-09-16
-- for why it never corrects masterVolume itself.
function check_mvol_settle()
	if not mvolSettlePending then return end
	if (idleTicks - mvolLastActivityIdleTick) < MVOL_SETTLE_IDLE_TICKS then return end
	mvolSettlePending = false

	local vol = masterVolume
	queue_message(msg_master_volume_write(vol))
	slog('-> MASTER VOLUME SETTLE: resend vol=' .. vol)

	if mvolLastSettleReadTick == nil or (timerTicks - mvolLastSettleReadTick) >= MVOL_SETTLE_READ_MIN_TICKS then
		mvolLastSettleReadTick = timerTicks
		awaitingSettleRead = true
		queue_master_volume_read()
	end
end

-- Shared entry point for every transition into STATE_ACTIVE (login confirmation/recall, restart,
-- and the ID_QUERY self-heal path - see handle_sl_frame). Idempotent: returns false and does
-- nothing if already active, so a self-heal reaffirmation never requeues the volume read. Returns
-- true if it performed the transition (and so already queued the read).
function enter_active_session()
	if state == STATE_ACTIVE then return false end
	state = STATE_ACTIVE
	-- A real return to ACTIVE clears the recovery watchdog's failure count (see
	-- ACTIVE_QUERY_DROP_MS above) - it counts CONSECUTIVE attempts that never even got back here, not
	-- how often the session drops.
	activeMsSinceQueryReply = 0
	framesSinceQueryReply = 0
	recoveryAttempts = 0
	queue_master_volume_read()
	set_master_mute(masterMuted) -- establish the LED for this session; the READ reply may correct it
	-- Forget what the mute rings were last sent, so the next tick re-establishes them for this
	-- session rather than trusting a memo from before the SL88 confirmed us - same reasoning as
	-- invalidate_all() for the display. See docs/config-lua-history.md#startup-led-discarded-before-login-confirmation-2026-09-16.
	encoderMuteLedSent, encoderRingSent, homeLedSent, globalLedSent = {}, {}, nil, nil
	return true
end

function handle_login()
	slog('<- LOGIN - session active')
	-- Fresh/re-confirmed session: make sure everything is resent rather than trusting our memo, which
	-- may record draws sent before the keyboard had actually identified/confirmed us.
	invalidate_all()
	paint_screen()
	-- A genuine login confirmation must resync volume AND resend the LED even if the self-heal path
	-- already made us ACTIVE (the SL88 discards messages sent before the app is actually selected,
	-- so a self-heal LED send can be silently dropped - see
	-- docs/config-lua-history.md#startup-led-discarded-before-login-confirmation-2026-09-16) - avoid
	-- double-queuing when enter_active_session() itself just did both.
	if not enter_active_session() then
		queue_master_volume_read()
		set_master_mute(masterMuted)
	end
	-- And the mute rings, for the same reason: enter_active_session's own clear does not run when we
	-- were already ACTIVE, so a ring set before this confirmation was discarded and never re-sent.
	encoderMuteLedSent, encoderRingSent, homeLedSent, globalLedSent = {}, {}, nil, nil
end

function handle_standby()
	state = STATE_STANDBY
	slog('<- STANDBY')
end

function handle_restart()
	slog('<- RESTART - repainting (SL88 retains no screen state)')
	invalidate_all() -- the SLMK2 forgets everything across Standby (see docs/implementing-sl-link.md); without this
		-- every id's memo would wrongly think its last content is still on screen and skip resending it.
	paint_screen()
	enter_active_session()
end

function handle_logout_request()
	slog('<- LOGOUT REQUEST - confirming')
	queue_message(msg_system(SYS_LOGOUT_CONFIRMATION))
	state = STATE_IDLE
end

-- Host-initiated logout (Cancel button, SHORT). STATE_IDLE would make the next timer tick
-- re-identify (controller_timer_trigger's STATE_IDLE branch) - instantly logging back in. The spec
-- says a Logout Request means we want off the APP list, so STATE_LOGGED_OUT withholds the keepalive
-- (see controller_timer_trigger's branch) until the SL88's own ~5s timeout drops us, then resumes
-- identification on its own.
-- The spec says a logged-out sender should suspend display traffic, so dismiss any popup and drop
-- whatever is still queued - dismiss_popup() itself repaints the previous screen, so the drop must
-- come AFTER it, not before, or that repaint refills the queue we just emptied.
function request_logout()
	slog('-> LOGOUT REQUEST (Cancel button SHORT)')
	queue_message(msg_system(SYS_LOGOUT_REQUEST))
	state = STATE_LOGGED_OUT
	logoutTicksLeft = LOGOUT_SILENT_TICKS
	if popupActive then dismiss_popup() end
	drop_queued_display()
end

-- Cancel button, LONG: the keyboard never replies to our Logout Request anyway (see this file's
-- header), so skip it and go straight to silence.
function force_logout()
	slog('-> FORCE LOGOUT (Cancel button LONG, no Logout Request sent)')
	state = STATE_LOGGED_OUT
	logoutTicksLeft = LOGOUT_SILENT_TICKS
	if popupActive then dismiss_popup() end
	drop_queued_display()
end

function handle_logout_confirmation()
	slog('<- LOGOUT CONFIRMATION')
	state = STATE_IDLE
end

function send_keepalive()
	queue_message(msg_system(SYS_DEVICE_NOTIFICATION))
end

-- True if a Device Notification is already queued and not yet flushed. See
-- controller_timer_trigger's unconditional-keepalive comment for why this guard exists: protocol
-- messages are never coalesced by queue_message, so calling send_keepalive() on every tick without
-- this check would pile up a duplicate behind an already-queued-but-undrained keepalive.
function has_keepalive_queued()
	for i = 1, #pendingMessages do
		local m = pendingMessages[i]
		if m[8] == IT_SYSTEM and m[9] == SYS_DEVICE_NOTIFICATION then
			return true
		end
	end
	return false
end

-- MARK: - Inbound decoding
--
-- controller_midi_in receives the SL88's traffic, SysEx included (the VAX77 reference matches F0 in
-- its own controller_midi_in the same way).

function is_our_sl_frame(e)
	return e[0] == 0xF0
		and e[1] == 0x00 and e[2] == 0x20 and e[3] == 0x1A and e[4] == 0x16
		and e[5] == SL_HOST_ID and e[6] == instanceID
end

function handle_sl_frame(e)
	local itemType = e[7]
	local func = e[8]

	if itemType == IT_IDENTIFICATION then
		if func == ID_APPROVED then
			handle_identification_approved()
		elseif func == ID_REJECTED then
			handle_identification_rejected(e[9])
		elseif func == ID_QUERY then
			-- Any reply - whichever result byte - proves the query round-trip is alive, which is what
			-- both recovery watchdogs (ACTIVE_QUERY_DROP_MS/_FRAMES) watch for.
			activeMsSinceQueryReply = 0
			framesSinceQueryReply = 0
			-- The reply to our own keepalive query. Receiving it is what re-arms the timer, but its result
			-- byte is also the most reliable session signal we get - far more dependable than waiting for a
			-- LOGIN CONFIRMATION, which the keyboard only sends on a *fresh* login and skips entirely if it
			-- still remembers us.
			if e[9] == 0x00 then
				slog('<- query: not identified; re-identifying')
				state = STATE_IDLE
				start_identification()
			else
				-- Identified. A query reply is not proof of APPROVAL though - only promote from LISTED
				-- (already approved, just reaffirming); an unapproved STATE_IDENTIFYING session keeps
				-- resending the Identification Request instead, so a real APPROVED/REJECTED reply lands.
				-- identifyFallback is the floor for when that never happens - see
				-- docs/config-lua-history.md#identification-approval-and-rejection-are-lost-in-mainstages-init-window-2026-09-10.
				if state == STATE_LISTED or (state == STATE_IDENTIFYING and identifyFallback) then
					enter_active_session()
				end
				if patchName ~= '' and not has_pending() then
					local stale = (lastPaintedPatch ~= patchName)
					local due = (idleTicks - lastPaintTick) >= REPAINT_EVERY_IDLE_TICKS
					if due then
						-- Memoization means an unchanged repaint would emit ZERO messages and heal nothing, defeating
						-- the entire point of this periodic repaint (the SL88 wipes its own screen on APP-list
						-- selection with no reliable signal for it) - force every region to resend.
						invalidate_all()
					end
					if stale or due then paint_screen() end
				end
			end
		end
	elseif itemType == IT_SYSTEM then
		if func == SYS_LOGIN_CONFIRMATION or func == SYS_LOGIN_RECALL then
			handle_login()
		elseif func == SYS_STANDBY then
			handle_standby()
		elseif func == SYS_RESTART then
			handle_restart()
		elseif func == SYS_LOGOUT_REQUEST then
			handle_logout_request()
		elseif func == SYS_LOGOUT_CONFIRMATION then
			handle_logout_confirmation()
		end
	elseif itemType == IT_MASTER_VOLUME then
		-- e[9] is VOL; a trailing MUTE byte may or may not follow (docs/implementing-sl-link.md §7 -
		-- trailing bytes are optional more often than the spec documents).
		local vol = e[9]
		if vol < 0 then vol = 0 elseif vol > 100 then vol = 100 end
		if func == MVOL_READ then
			-- vol is diagnostic/logging only - never feeds masterVolume. See
			-- docs/config-lua-history.md#master-volume-writes-take-effect-without-a-paired-read-probe-four-phase-result-2026-09-13.
			masterVolumeRead = vol
			-- MUTE (e[10]) seeds masterMuted if present; absent (e[10] is SL_END instead) leaves the
			-- default established by enter_active_session's own set_master_mute call.
			local muteByte = e[10]
			if muteByte ~= nil and muteByte ~= SL_END then
				local muted = muteByte ~= 0
				if muted ~= masterMuted then set_master_mute(muted) end
			end
			slog('<- MASTER VOLUME READ reply vol=' .. vol .. ' mute=' .. tostring(muteByte) ..
				' (masterVolume=' .. masterVolume .. ', masterMuted=' .. tostring(masterMuted) .. ')')
			-- Diagnostic only - see check_mvol_settle()'s comment for why a mismatch never corrects
			-- masterVolume.
			if awaitingSettleRead then
				awaitingSettleRead = false
				if vol == masterVolume then
					slog('settled volume confirmed vol=' .. vol)
				else
					slog('settled volume MISMATCH: sent ' .. masterVolume .. ', device reports ' .. vol)
				end
			end
		else
			masterVolume = vol
			slog('<- MASTER VOLUME WRITE echo vol=' .. vol)
		end
	elseif itemType == IT_BUTTON then
		local bid = func
		local pressKind = e[9]
		local ccButton = BUTTON_CC[bid]
		if bid == BID_HOME then
			handle_home_button(pressKind)
		elseif bid == BID_GLOBAL then
			handle_global_button(pressKind)
		elseif bid == BID_JOY_MAIN then
			handle_joystick_press(pressKind)
		elseif JOYSTICK_NAV[bid] ~= nil and (pressKind == PRESS_SHORT or pressKind == PRESS_LONG) then
			handle_joystick_direction(bid, pressKind)
		elseif bid == BID_A_ENC then
			handle_a_encoder_button(pressKind)
		elseif bid == BID_CANCEL then
			if pressKind == PRESS_LONG then
				force_logout()
			else
				request_logout()
			end
		elseif ccButton ~= nil and (pressKind == PRESS_SHORT or pressKind == PRESS_LONG) then
			local control = (pressKind == PRESS_SHORT) and ccButton.short or ccButton.long
			queue_momentary_cc(control)
		else
			local kind = (pressKind == PRESS_SHORT and 'SHORT') or (pressKind == PRESS_LONG and 'LONG')
				or tostring(pressKind)
			slog('<- BUTTON bid=' .. string.format('0x%02X', bid)
				.. ' event=' .. kind .. ' (unhandled) frame=' .. dump_event(e))
		end
	elseif itemType == IT_ENCODER then
		local eid = func
		local delta = e[9] - 0x40
		if eid == EID_A then
			-- Marks a gesture in progress - check_mvol_settle() clears this once quiet for
			-- MVOL_SETTLE_IDLE_TICKS, so a settle fires once per gesture rather than on every idle tick.
			mvolLastActivityIdleTick = idleTicks
			mvolSettlePending = true
			-- masterVolume starts at MVOL_SEED_DEFAULT and thereafter changes ONLY by accumulated
			-- deltas - never reseeded from masterVolumeRead. See
			-- docs/config-lua-history.md#master-volume-writes-take-effect-without-a-paired-read-probe-four-phase-result-2026-09-13.
			local vol = masterVolume + delta
			if vol < 0 then vol = 0 elseif vol > 100 then vol = 100 end
			masterVolume = vol
			-- Own regionId so a fast twist's many ticks coalesce to one queued write, not several - see
			-- queue_message's PER-REGION COALESCING comment. No accompanying READ poll any more - a
			-- write takes effect without one (same anchor above); dropping it frees a flush slot.
			local mvolWriteMsg = msg_master_volume_write(masterVolume)
			-- FAST-TURN BUDGET: tag the write when THIS delta is fast, so flush_pending() may let it
			-- bypass the one-per-tick pace (up to MVOL_FAST_WRITES_PER_TICK total) - see
			-- mvolFastWritesThisTick's declaration. A slow delta leaves the tag unset.
			mvolWriteMsg.fast = math.abs(delta) >= MVOL_FAST_DELTA_THRESHOLD
			slog('-> MASTER VOLUME WRITE: ' .. dump_bytes(mvolWriteMsg))
			queue_message(mvolWriteMsg, 'mvol')
			show_master_volume_popup()
		elseif eid == EID_JOYSTICK and displayMode == 'config' then
			-- The ring is the config screen's scroller, and emits NO CC while that screen shows -
			-- otherwise every scroll tick also moves whatever MainStage learned to JOY_ROTATE. Raw
			-- delta, no acceleration curve on top: the hardware is already speed-sensitive (see
			-- docs/implementing-sl-link.md section 6). No popup either - the popup would cover the very
			-- screen being scrolled.
			-- update_screen(), not paint_config_screen() directly: it dispatches to the same painter but
			-- also adds the trailing sacrificial redraw, without which the last row of a scroll is
			-- silently lost (see queue_sacrificial_redraw's comment).
			if scroll_config(delta) then
				update_screen()
				request_quick_rearm()
			end
			slog('<- ENCODER joystick delta=' .. tostring(delta) .. ' - config scroll=' .. configScroll)
		elseif eid == EID_JOYSTICK then
			-- The ring BROWSES: it moves the cursor and changes no patch. The joystick press commits (see
			-- handle_joystick_press), which is what keeps MainStage from loading every patch scrolled past.
			-- Emits no CC either - CC 50 was removed once patch selection worked.
			-- A turn on the zoom screen switches to the list first, so the gesture is not wasted.
			if displayMode ~= 'list' then set_display_mode('list') end
			move_browse_cursor(delta)
			browsePending = true
			browseLastActivityIdleTick = idleTicks
			update_screen()
			request_quick_rearm()
			slog('<- RING browse -> cursor=' .. cursorIndex .. ' (patch ' .. cursor_patch_ordinal() .. ')')
		else
			local control = ENCODER_CC[eid]
			if control ~= nil then
				local newValue = encoderValue[eid] + delta
				if newValue < 0 then newValue = 0 elseif newValue > 127 then newValue = 127 end
				encoderValue[eid] = newValue -- still tracked for show_popup's ring gauge, not for what's emitted below
				if delta ~= 0 then
					-- Relative2C two's complement; wire encoding confirmed on hardware 2026-09-05, see
					-- docs/mainstage-integration.md. queue_relative_cc accumulates the raw signed delta;
					-- flush_pending_cc clamps and encodes it at emit time.
					queue_relative_cc(control, delta)
				end
				show_popup(eid)
			else
				slog('<- ENCODER eid=' .. string.format('0x%02X', eid)
					.. ' tick=' .. string.format('0x%02X', e[9])
					.. ' delta=' .. tostring(delta) .. ' (unhandled) frame=' .. dump_event(e))
			end
		end
	else
		slog('<- unhandled itemType=' .. string.format('0x%02X', itemType)
			.. ' frame=' .. dump_event(e))
	end
end

-- SHORT toggles mute alone (VOL=MVOL_IGNORE_VOL so the volume is untouched); LONG resets volume to
-- MVOL_SEED_DEFAULT (plain write, no MUTE byte - see msg_master_volume_write's own comment) and
-- separately unmutes, satisfying the project's LONG-must-never-be-a-no-op rule (see
-- handle_home_button's own comment) since it always lands on a known volume/mute pair.
function handle_a_encoder_button(pressKind)
	if pressKind == PRESS_LONG then
		masterVolume = MVOL_SEED_DEFAULT
		local writeMsg = msg_master_volume_write(MVOL_SEED_DEFAULT)
		slog('-> A BUTTON LONG: reset volume ' .. dump_bytes(writeMsg))
		queue_message(writeMsg, 'mvol')
		queue_message(msg_master_volume_mute_write(MVOL_IGNORE_VOL, false))
		slog('-> A BUTTON LONG: unmute')
		set_master_mute(false)
	else
		local newMuted = not masterMuted
		queue_message(msg_master_volume_mute_write(MVOL_IGNORE_VOL, newMuted))
		slog('-> A BUTTON SHORT: mute toggle -> ' .. tostring(newMuted))
		set_master_mute(newMuted)
	end
	show_master_volume_popup()
end

-- SHORT toggles the display mode; LONG forces a full repaint of whichever mode is currently
-- showing. LONG must never be silently dropped - the project rule (see CLAUDE.md's demo-screen
-- interaction model: LONG_PRESSION is confirmed delivered on real hardware, and every button case
-- must give it a distinct effect or run the same action as SHORT) - so it gets its own, always-safe
-- effect: a manual on-demand version of the periodic self-heal repaint above (paint_screen() after
-- invalidate_all()), useful if the SL88's screen has drifted from what the script thinks it last
-- painted.
--
-- Popup interaction: the plain SHORT toggle ('list' <-> 'zoom') assumes displayMode is one of
-- exactly those two - false while a popup is showing, where it would compute newMode='zoom'
-- regardless of what was showing before the popup, ignoring popupPreviousMode and leaving
-- popupActive stale-true. So a Zoom-button SHORT while a popup is up must instead dismiss the popup
-- - dismiss_popup() already restores popupPreviousMode via set_display_mode. LONG needs no special
-- case: invalidate_all()+paint_screen() already redraws whatever displayMode currently is, popup
-- included, via paint_screen's 3-way dispatch.
function handle_home_button(pressKind)
	if pressKind == PRESS_LONG then
		slog('<- BUTTON home LONG - forcing full repaint of mode=' .. displayMode)
		invalidate_all()
		paint_screen()
		-- invalidate_all() above guarantees this repaint queues real content - see request_quick_rearm's
		-- comment.
		request_quick_rearm()
	elseif displayMode == 'popup' then
		slog('<- BUTTON home SHORT - dismissing popup (mode=popup)')
		dismiss_popup()
	elseif displayMode == 'config' then
		-- The config screen is entered and left with the Global button alone: one button owns one mode. Toggling
		-- here would compute 'zoom' regardless of what config is covering and lose configPreviousMode.
		slog('<- BUTTON home SHORT - ignored (mode=config; the Global button dismisses it)')
	else
		local newMode = (displayMode == 'zoom') and 'list' or 'zoom'
		slog('<- BUTTON home SHORT - toggling display mode -> ' .. newMode)
		set_display_mode(newMode)
	end
end

-- Selects whatever patch the cursor is on: Bank Select + Program Change for its ordinal. The single exit
-- for every in-script patch selection - the joystick press (browse-and-commit) and the joystick tilts
-- (which move the cursor and commit in one gesture) both end here, so the wire arithmetic lives once.
function commit_cursor_patch(why)
	local ordinal = cursor_patch_ordinal()
	-- -1 because MainStage counts program changes from 1 and MIDI from 0: patch 1 is wire value 0.
	local bank, pc = math.floor((ordinal - 1) / 128), (ordinal - 1) % 128
	queue_program(pc, bank)
	browsePending = false
	slog('-> BANK ' .. bank .. ' + PROGRAM CHANGE ' .. pc .. ' (' .. why .. ', patch ' .. ordinal .. ')')
end

-- The joystick press commits a browsed patch (see move_browse_cursor). Nothing browsed means nothing to
-- commit - the press is not a patch re-trigger.
-- LONG runs the same action as SHORT, the project rule for LONG_PRESSION (see handle_home_button).
-- Commit-only: this button's CC (48/49) was removed, so it emits nothing to MainStage but the selection.
function handle_joystick_press(pressKind)
	if not browsePending then
		slog('<- BUTTON joystick press - nothing browsed, ignored')
		return
	end
	commit_cursor_patch('committing browsed patch')
end

-- The joystick tilts select patches directly, with no CC of their own: each gesture moves the cursor and
-- the move is committed immediately. Stepping from the CURSOR rather than the playing patch is what makes
-- a fast double-tilt advance two patches (the second press sees the first one's cursor, whether or not
-- MainStage has answered yet) and what lets a tilt continue a ring browse.
-- LONG absent means LONG does what SHORT does - the project rule for LONG_PRESSION.
JOYSTICK_NAV = {
	[BID_JOY_UP]    = { name = 'up',    short = function() return move_browse_cursor(-1) end,
	                                    long = function() return move_cursor_to_edge(false) end },
	[BID_JOY_DOWN]  = { name = 'down',  short = function() return move_browse_cursor(1) end,
	                                    long = function() return move_cursor_to_edge(true) end },
	[BID_JOY_LEFT]  = { name = 'left',  short = function() return move_cursor_by_set(-1) end },
	[BID_JOY_RIGHT] = { name = 'right', short = function() return move_cursor_by_set(1) end },
}

-- Runs one JOYSTICK_NAV gesture. No move means no Program Change: at the ends of the concert or setlist
-- the gesture is a no-op rather than a re-trigger of the patch already playing, which would reload it.
function handle_joystick_direction(bid, pressKind)
	local nav = JOYSTICK_NAV[bid]
	local isLong = pressKind == PRESS_LONG
	local move = (isLong and nav.long) or nav.short
	if not move() then
		slog('<- JOY ' .. nav.name .. (isLong and ' LONG' or '') .. ' - at the end, nothing sent')
		return
	end
	commit_cursor_patch('joystick ' .. nav.name .. (isLong and ' long' or ''))
	update_screen()
	request_quick_rearm()
end

-- The Global button (panel: SETTINGS) toggles the config screen, restoring whatever it covered. LONG runs the same action as
-- SHORT rather than being dropped - the project rule for LONG_PRESSION (see handle_home_button's
-- comment); a second effect on a screen-toggle button would only surprise.
--
-- Pressed while a popup is up, it takes over the popup's stored previous mode rather than calling
-- dismiss_popup() first: that would be a second full Clear-Screen repaint for a screen nobody sees.
-- configScroll deliberately survives a dismiss, so re-opening returns to the same page.
function handle_global_button(pressKind)
	if displayMode == 'config' then
		local back = configPreviousMode or 'list'
		configPreviousMode = nil
		slog('<- BUTTON global - leaving config -> ' .. back)
		set_display_mode(back)
		return
	end
	if popupActive then
		configPreviousMode = popupPreviousMode or 'list'
		popupActive = false
	else
		configPreviousMode = displayMode
	end
	slog('<- BUTTON global - entering config (over ' .. tostring(configPreviousMode) .. ')')
	set_display_mode('config')
end

-- MARK: - MainStage callbacks

function controller_initialize(applicationName, deviceNewlyDetected)
	settriggertimer(KEEPALIVE_MS)
	-- This is the very first arm for a fresh script instance - nothing was outstanding before it, and
	-- this call genuinely arms a timer (unlike controller_timer_trigger's own top-of-function call),
	-- so timerPending must say so or the first rearm_timer() from inbound traffic would wrongly re-arm
	-- on top of it.
	timerPending = true
	timerArmedInterval = KEEPALIVE_MS
	state = STATE_IDLE
	instanceID = derive_instance_start(instanceTag)
	reidentifyRetriesLeft = MAX_SAME_ID_RETRIES
	pendingMessages = {}
	pendingCC = {}
	pendingDelta = {}
	pendingCCOrder = {}
	pendingReleases = {}
	encoderValue = {
		[EID_ZONE1] = 64, [EID_ZONE2] = 64, [EID_ZONE3] = 64, [EID_ZONE4] = 64,
		[EID_JOYSTICK] = 64, [EID_B] = 64,
	}
	displayMode = 'zoom' -- see the displayMode declaration above for why
	patchName, setName, currentConcert = '', '', ''
	activeSetIndex, activePatchIndex = 0, 0
	cursorIndex, scrollOffset = 0, 0
	listRows = {}
	invalidate_all()

	if applicationName ~= nil and applicationName ~= '' then
		APP_NAME = applicationName
	end

	slog('controller_initialize (app="' .. tostring(applicationName) .. '", version=' .. SCRIPT_VERSION .. ')')
	-- MIDI_LSB/MSB are strings, not numbers
	slog('injected globals: MIDI_CtrChange=' .. tostring(MIDI_CtrChange) ..
		' MIDI_LSB=' .. tostring(MIDI_LSB) .. ' MIDI_MSB=' .. tostring(MIDI_MSB) ..
		' MIDI_Wildcard=' .. tostring(MIDI_Wildcard))
	start_identification()
	return flush_pending()
end

-- A teardown that holds a live registration releases it, so the SL88 drops us at once instead of
-- waiting out its ~5s keepalive timeout and briefly showing a dead second entry in the APP list.
-- GATED, because MainStage tears the script down and re-initialises it constantly and two earlier
-- unconditional attempts had to be reverted for logging the app out mid-startup: a churn teardown
-- fires at tick 0 in STATE_IDENTIFYING, holding nothing worth releasing, while a real quit fires
-- from a registered state many ticks in. See
-- docs/config-lua-history.md#controller_finalize-sends-no-logout-request.
LOGOUT_ON_QUIT_MIN_TICKS = 20

function controller_finalize()
	slog('controller_finalize (state=' .. tostring(state) .. ', tick=' .. tostring(timerTicks) ..
		', pending=' .. #pendingMessages .. ')')
	local registered = (state == STATE_LISTED or state == STATE_ACTIVE or state == STATE_STANDBY)
	local mature = timerTicks >= LOGOUT_ON_QUIT_MIN_TICKS
	pendingMessages = {}
	state = STATE_IDLE
	if not (registered and mature) then return nil end
	slog('-> LOGOUT REQUEST from controller_finalize')
	return { midi = msg_system(SYS_LOGOUT_REQUEST), outport = SL_PORT }
end

-- Fires the recovery action itself (drop to STATE_IDLE, which controller_timer_trigger's STATE_IDLE
-- branch turns into a re-identify) subject to the cooldown/attempt-cap bounds. Shared by the ms-based
-- watchdog below (ticks still running) and check_inbound_recovery() (ticks dead - see
-- ACTIVE_QUERY_DROP_FRAMES and docs/config-lua-history.md#dead-clock-instrumentation-and-two-recovery-backstops-2026-09-14),
-- so the bounds apply no matter which one notices the drop first.
function trigger_recovery(reason)
	if recoveryGivenUp or recoveryCooldownMs > 0 then return end
	recoveryAttempts = recoveryAttempts + 1
	if recoveryAttempts > MAX_RECOVERY_ATTEMPTS then
		recoveryGivenUp = true
		slog('recovery watchdog: giving up after ' .. MAX_RECOVERY_ATTEMPTS ..
			' failed attempts - not re-identifying')
		return
	end
	slog('recovery watchdog: ' .. reason .. ' - re-identifying (attempt ' .. recoveryAttempts .. '/' ..
		MAX_RECOVERY_ATTEMPTS .. ')')
	recoveryCooldownMs = RECOVERY_COOLDOWN_MS
	activeMsSinceQueryReply = 0
	framesSinceQueryReply = 0
	state = STATE_IDLE
end

-- Inbound-path counterpart to controller_timer_trigger's ms-based recovery watchdog below - reachable
-- even when the session clock itself is dead, since it runs off inbound frames rather than ticks. See
-- ACTIVE_QUERY_DROP_FRAMES's declaration for why frames, and why its threshold sits above
-- TIMER_WATCHDOG_FORCE_FRAMES. Called from controller_midi_in on every inbound event.
function check_inbound_recovery()
	if state ~= STATE_ACTIVE then return end
	if framesSinceQueryReply >= ACTIVE_QUERY_DROP_FRAMES then
		trigger_recovery('no query reply for ' .. framesSinceQueryReply .. ' inbound frames')
	end
end

-- Periodic. Re-arms itself so it keeps firing for as long as the device stays selected. This is the
-- only clock the session has, so the keepalive cadence depends on it.
timerTicks = 0

function controller_timer_trigger()
	-- The one-shot has just fired, so nothing is outstanding any more - clear this BEFORE the
	-- settriggertimer call below, which (per the SESSION CLOCK note further down, established on
	-- hardware) does NOT actually re-arm anything when called from inside this function. Leaving
	-- timerPending false here is what is factually correct AND what lets the real re-arm -
	-- rearm_timer(), from the next inbound frame, almost always the reply to the Identification Query
	-- this function's own return flushes - go ahead instead of being gated out by a flag claiming a
	-- timer is already pending when none actually is.
	timerPending = false
	framesSinceTick = 0
	watchdogDiagLastFrames = 0
	settriggertimer(KEEPALIVE_MS)
	timerTicks = timerTicks + 1

	-- Grant this tick's one-display-message permit (see displayFlushReady's declaration). Withhold it
	-- while a Clear Screen is still settling (displaySettleTicks), so the draw that follows one gets
	-- roughly two tick periods of quiet instead of one. Protocol messages and the trailing
	-- Identification Query are never gated by displayFlushReady, so the session clock keeps running
	-- through the settle regardless.
	if displaySettleTicks > 0 then
		displaySettleTicks = displaySettleTicks - 1
	else
		displayFlushReady = true
	end
	-- Master Volume writes get no settle guard - grant unconditionally every tick. See mvolFlushReady's
	-- declaration.
	mvolFlushReady = true
	mvolFastWritesThisTick = 0 -- fresh fast-turn budget for this tick window - see its own declaration
	-- The shared permit: one queued message leaves per tick, whatever its itemType. See its
	-- declaration for why the per-class flags above were not enough.
	slFlushReady = true
	-- Only ticks that arrive at the full keepalive cadence count towards the periodic refresh; fast
	-- drain ticks must not.
	local draining = has_pending()
	if not draining then idleTicks = idleTicks + 1 end
	check_popup_dismiss()
	check_browse_revert()
	check_mvol_settle()
	-- Drain a throttle-withheld popupValue redraw once it's due (see POPUP_VALUE_THROTTLE_TICKS) -
	-- this is what guarantees a settled value is never left stale.
	flush_popup_value_if_due()
	-- Mute ring LEDs track their parameter's feedback, not the popup - see flush_mute_leds().
	flush_mute_leds()
	-- The zone encoder rings, coloured by MainStage - see flush_encoder_rings().
	flush_encoder_rings()
	flush_mode_led()
	-- `tick=`/`pending=`/`draining=` here let a captured hardware log be read as 'N drain ticks
	-- elapsed while M messages went out' - pair against the `tick=` field flush_pending's own FLUSH
	-- print carries.
	slog('timer tick #' .. timerTicks .. ' (idle ' .. idleTicks .. ') state=' .. state ..
		' pending=' .. #pendingMessages .. ' draining=' .. tostring(draining))

	-- RECOVERY WATCHDOG: the SL88 has been observed to silently drop our registration while
	-- STATE_ACTIVE - no logout, no standby, encoder frames keep arriving, but Identification Query
	-- replies just stop. Falling to STATE_IDLE here reuses the ordinary re-identify branch just below
	-- rather than calling start_identification() twice over. Bounded (cooldown + attempt cap) so it
	-- cannot spin the way the detector removed after a suspected freeze could - see
	-- docs/config-lua-history.md#recovering-a-silently-dropped-active-session-bounded-2026-09-13.
	if recoveryCooldownMs > 0 then
		recoveryCooldownMs = recoveryCooldownMs - timerArmedInterval
		if recoveryCooldownMs < 0 then recoveryCooldownMs = 0 end
	end
	if state == STATE_ACTIVE then
		activeMsSinceQueryReply = activeMsSinceQueryReply + timerArmedInterval
		if activeMsSinceQueryReply >= ACTIVE_QUERY_DROP_MS then
			trigger_recovery('no query reply for ' .. activeMsSinceQueryReply .. 'ms')
		end
	end

	-- Announce unconditionally once an Identification Request has been sent, regardless of what we've
	-- observed back: if the keyboard still remembers us from a previous run it sends neither APPROVED
	-- nor LOGIN, so gating this on having seen APPROVED first stalls the state machine in IDENTIFYING
	-- with no keepalive going out - the entry ages out of the APP list after ~5s. The query reply is
	-- the reliable session signal (see handle_sl_frame's ID_QUERY branch), not APPROVED/LOGIN.
	if state == STATE_IDLE then
		start_identification()
	elseif state == STATE_REIDENTIFY_WAIT then
		-- This tick firing at all means REIDENTIFY_WAIT_MS actually elapsed (rearm_timer() refuses to
		-- shorten it while waiting - see there), so this is the retry, not an ordinary keepalive tick.
		-- Falling through to the send_keepalive() branch below would be wrong here: it would announce the
		-- still-rejected instanceID instead of retrying it.
		start_identification()
	elseif state == STATE_LOGGED_OUT then
		-- Deliberately no send_keepalive() - that silence is the whole point (see request_logout()).
		-- flush_pending(true) below still appends the Identification Query, which keeps the session
		-- clock alive (rule 6) without itself counting as a keepalive. If the SL88 confirms we've
		-- been dropped (ID_QUERY reply e[9]==0), handle_sl_frame already re-identifies immediately;
		-- this counter is the fallback that guarantees a resume either way.
		logoutTicksLeft = logoutTicksLeft - 1
		if logoutTicksLeft <= 0 then
			start_identification()
		end
	elseif state == STATE_IDENTIFYING then
		-- Not yet APPROVED. Resend rather than send_keepalive() - there is no APP-list entry to keep
		-- alive yet - so a later resend's reply lands after MainStage's inbound path is live. See
		-- docs/config-lua-history.md#identification-approval-and-rejection-are-lost-in-mainstages-init-window-2026-09-10.
		if identifyResendsLeft > 0 then
			identifyResendsLeft = identifyResendsLeft - 1
			slog('-> re-sending Identification Request (' .. identifyResendsLeft .. ' left)')
			queue_message(msg_identification_request())
		else
			-- Budget spent, still no APPROVED: fall back to the pre-fix query-reply promotion rather
			-- than going silent forever (a dead session is worse than one missing Master Volume).
			if not identifyFallback then
				identifyFallback = true
				slog('identification never approved - falling back to query-reply promotion')
			end
			if not has_keepalive_queued() then
				send_keepalive()
			end
		end
	else
		-- MUST send the keepalive UNCONDITIONALLY on every keepalive-cadence tick, even while display
		-- work is still queued - do not gate this on `not has_pending()`. A display message paces at one
		-- per tick (displayFlushReady), so a multi-message repaint can leave has_pending() true for
		-- several ticks in a row; gating the keepalive on an empty queue starves it for the whole
		-- repaint, an independent route to the same ~5s APP-list timeout rule 6 fixes. See
		-- docs/config-lua-history.md#the-unconditional-keepalive for the measurement that ruled out the
		-- alternative (bundling the keepalive into the same array as a Write Text, which the SL88
		-- discards).
		--
		-- Safe unconditionally because send_keepalive() queues a PROTOCOL message (itemType IT_SYSTEM,
		-- regionId nil), and flush_pending never gates non-display messages behind displayFlushReady -
		-- they jump ahead of any display backlog if necessary (flush_pending's scan-forward fix).
		-- has_keepalive_queued() guards against PILE-UP: protocol messages are deliberately never
		-- coalesced, so without this guard a keepalive queued-but-not-yet-flushed would get another one
		-- appended behind it on every subsequent tick, growing without bound.
		if not has_keepalive_queued() then
			send_keepalive()
		end
	end

	-- Also send an Identification Query. Its only purpose is to make the keyboard send something back:
	-- `settriggertimer` is a ONE-SHOT that cannot be re-armed from inside this callback (established
	-- on hardware, see the SESSION CLOCK note above controller_midi_in), so the only thing that keeps
	-- the clock running is inbound MIDI arriving at controller_midi_in. The query's reply is that
	-- inbound event, which re-arms the timer and schedules the next tick - a self-sustaining
	-- request/response heartbeat that does not depend on anyone playing. flush_pending appends the
	-- query itself and reserves budget for it.
	return flush_pending(true)
end

function dump_event(e)
	local parts = {}
	local i = 0
	while i < 48 do
		local b = e[i]
		if b == nil then break end
		parts[#parts + 1] = string.format('%02X', b)
		i = i + 1
	end
	return table.concat(parts, ' ')
end

-- Mirrors dump_event, but for an OUTBOUND queue_message table (1-based, e.g. from msg_* builders),
-- not an inbound 0-based MainStage MIDI event.
function dump_bytes(m)
	local parts = {}
	for i = 1, #m do
		parts[#parts + 1] = string.format('%02X', m[i])
	end
	return table.concat(parts, ' ')
end

-- SESSION CLOCK: `settriggertimer` is a ONE-SHOT that does NOT re-arm when called from inside
-- controller_timer_trigger - confirmed on hardware, that callback fires exactly once per script
-- instance no matter what. It DOES re-arm when called from here (controller_midi_in). Do not assume
-- controller_timer_trigger can free-run; it cannot.
--
-- So the heartbeat is: timer tick -> send keepalive + Identification Query -> keyboard replies ->
-- that reply lands here -> re-arm -> next tick. Without the query there is nothing to reply, the
-- chain stops after one tick, and the SL88 drops the host from its APP list after ~5s. See
-- docs/config-lua-history.md#settriggertimer-is-a-one-shot-and-does-not-self-renew-from-inside-the-tick-handler.
--
-- Re-arms the one-shot timer. Called at the END of controller_midi_in, after any queued output has
-- been drained, so the interval reflects what is still outstanding rather than what was outstanding
-- on entry.
--
-- MUST only actually call settriggertimer when timerPending is false (rule 6 in the banner):
-- controller_midi_in calls this on EVERY inbound MIDI event, including every note on/off, and
-- settriggertimer cancels-and-restarts whatever is pending on each call - an ungated call here
-- starves the clock while the user plays. See
-- docs/config-lua-history.md#rule-6-notes-starve-the-clock. A note arriving while a timer is
-- already pending leaves it alone and passes straight through untouched; the first inbound frame
-- after a tick fires (almost always the Identification Query's reply) is what chooses the next
-- interval.
function rearm_timer()
	if state == STATE_REIDENTIFY_WAIT then
		-- CRITICAL: rearm_timer() runs on EVERY inbound frame. The rejection handler sets the one-shot
		-- timer to REIDENTIFY_WAIT_MS to wait out the SL88's ~5s host timeout (see
		-- handle_identification_rejected) - if this function touched the timer here too, that wait would
		-- be overwritten with FLUSH_SOON_MS/KEEPALIVE_MS by the very next inbound frame, typically within
		-- milliseconds, and the wait would never actually happen. Leave the pending timer alone until the
		-- wait state ends.
		return
	end
	if timerPending then
		local queueBacked = framesSinceTick >= TIMER_WATCHDOG_FRAMES and has_pending()
		local forced = framesSinceTick >= TIMER_WATCHDOG_FORCE_FRAMES
		if not queueBacked and not forced then
			-- A one-shot is already outstanding; it will fire on its own. This is the notes-starve-the-clock
			-- fix - see this function's comment above. The has_pending() check keeps the watchdog from
			-- ever firing on idle play, where a slow tick isn't a dead clock - see the doc anchor above.
			--
			-- Diagnostic: past TIMER_WATCHDOG_FRAMES the clock already looks suspicious, but is being left
			-- alone here (either still short of TIMER_WATCHDOG_FORCE_FRAMES, or has_pending() is false) -
			-- log the inputs this decision is made from, rate-limited to first crossing plus once every
			-- TIMER_WATCHDOG_DIAG_EVERY_FRAMES after, so the next capture can show WHY a stalled clock did
			-- or didn't recover instead of just going silent. See that constant's declaration.
			if framesSinceTick >= TIMER_WATCHDOG_FRAMES and
				(framesSinceTick == TIMER_WATCHDOG_FRAMES or
					framesSinceTick - watchdogDiagLastFrames >= TIMER_WATCHDOG_DIAG_EVERY_FRAMES) then
				watchdogDiagLastFrames = framesSinceTick
				slog('timer watchdog diag: timerPending=' .. tostring(timerPending) ..
					' framesSinceTick=' .. framesSinceTick .. ' has_pending=' .. tostring(has_pending()) ..
					' state=' .. state .. ' timerArmedInterval=' .. timerArmedInterval)
			end
			return
		end
		-- Watchdog: MainStage never delivered the outstanding one-shot, so nothing was ever going to
		-- clear timerPending. Re-arm anyway - see
		-- docs/config-lua-history.md#timer-watchdog-a-lost-one-shot-latches-timerpending-forever-2026-09-07.
		slog('timer watchdog: one-shot lost after ' .. framesSinceTick .. ' frames' ..
			((forced and not queueBacked) and ' (forced - queue was empty)' or '') .. ' - re-arming')
		framesSinceTick = 0
		watchdogDiagLastFrames = 0
	end
	if state == STATE_LOGGED_OUT then
		-- Pin the tick at KEEPALIVE_MS regardless of has_pending()/popupActive, so LOGOUT_SILENT_TICKS
		-- maps to real seconds instead of whatever pace queued traffic would otherwise pick.
		settriggertimer(KEEPALIVE_MS)
		timerArmedInterval = KEEPALIVE_MS
	elseif has_pending() then
		settriggertimer(FLUSH_SOON_MS) -- still draining a repaint; come back soon
		timerArmedInterval = FLUSH_SOON_MS
	elseif popupActive or browsePending then
		-- While the popup is showing OR a browse is waiting to revert, and nothing is draining, arm the ~1s
		-- popup tick instead of the ~3s
		-- keepalive tick, so POPUP_DISMISS_IDLE_TICKS (an idleTicks count, not a literal duration)
		-- actually dismisses after ~1s. Only reached once has_pending() is false, so this never delays
		-- the popup's own draw burst - only the idle wait afterward, before dismissal.
		settriggertimer(POPUP_TICK_MS)
		timerArmedInterval = POPUP_TICK_MS
	else
		settriggertimer(KEEPALIVE_MS)
		timerArmedInterval = KEEPALIVE_MS
	end
	timerPending = true
end

-- If a one-shot is currently outstanding AND it was armed at either LONG interval (KEEPALIVE_MS or
-- POPUP_TICK_MS - matching both matters, see docs/config-lua-history.md#quick-rearm-2026-08-21 for
-- the responsiveness regression that motivated adding POPUP_TICK_MS here), shorten it to
-- FLUSH_SOON_MS instead of leaving newly-queued display work to wait out whatever is left. Call
-- ONCE per queueing burst - from controller_select_patch's update, set_display_mode, and the button
-- handlers - never from queue_message() itself, which would fire it many times over a single
-- repaint.
--
-- Shares rearm_timer's STATE_REIDENTIFY_WAIT guard: that wait must never be shortened (see
-- handle_identification_rejected). Also excludes STATE_LOGGED_OUT: dismiss_popup()'s
-- set_display_mode() call reaches here, and shortening the logout tick would undercut
-- LOGOUT_SILENT_TICKS's KEEPALIVE_MS cadence.
function request_quick_rearm()
	if state == STATE_REIDENTIFY_WAIT or state == STATE_LOGGED_OUT then return end
	if timerPending and (timerArmedInterval == KEEPALIVE_MS or timerArmedInterval == POPUP_TICK_MS) then
		settriggertimer(FLUSH_SOON_MS)
		timerArmedInterval = FLUSH_SOON_MS
		slog('quick-rearm -> FLUSH_SOON_MS')
	end
end

function controller_midi_in(midiEvent, portName)
	framesSinceTick = framesSinceTick + 1
	framesSinceQueryReply = framesSinceQueryReply + 1
	check_inbound_recovery()

	if midiEvent[0] == 0xF0 then
		slog('<- SYSEX on port=' .. tostring(portName) .. ': ' .. dump_event(midiEvent))
	end

	if is_our_sl_frame(midiEvent) then
		-- Release any momentary CC presses queued LAST round before handling THIS frame, so a button
		-- press on this frame queues its own release for the round after, not this one - see
		-- queue_momentary_cc's comment for why the release can't just follow the press directly.
		if #pendingReleases > 0 then
			for i = 1, #pendingReleases do
				queue_cc(pendingReleases[i], 0)
			end
			pendingReleases = {}
		end

		handle_sl_frame(midiEvent)

		-- Phase 2 (every SL88 control emits its own CC): a batch queued by the release-drain above and/or
		-- this frame's own button/encoder event takes priority this round, mirroring the old Q1a spike's
		-- proven injection shape - return it ALONE, never call flush_pending, never dequeue
		-- pendingMessages and discard the result. Anything already queued for the SL88 (display/protocol
		-- traffic) is untouched and drains on a later flush; rearm_timer() below still runs
		-- unconditionally, so skipping the Identification Query this round does not stall the session
		-- clock (this inbound frame is itself the 'reply' the clock needs - see the SESSION CLOCK note
		-- above rearm_timer).
		-- Only pre-empt the SL flush when the CC batch actually produced bytes; a net-zero batch
		-- returns nil and falls through, so the round still gets its SL flush.
		if #pendingCCOrder > 0 or pendingProgram ~= nil then
			local out = flush_pending_cc()
			if out ~= nil then
				rearm_timer()
				return out
			end
		end

		-- Protocol traffic, not music: swallow it, and use the opportunity to flush whatever the handler
		-- queued. Do NOT include the Identification Query while state == STATE_REIDENTIFY_WAIT:
		-- flush_pending(true) appends it unconditionally, and the SL88 would truthfully answer 'not
		-- identified' for an id it just rejected - which the ID_QUERY branch in handle_sl_frame treats as
		-- licence to re-identify right away, defeating the wait handle_identification_rejected just
		-- started.
		local out = flush_pending(state ~= STATE_REIDENTIFY_WAIT)
		rearm_timer()
		if out ~= nil then return out end
		return { midi = {} }
	end

	rearm_timer()

	if midiEvent[0] == 0xC0 then
		return { midi = {} } -- swallow Program Change (patchselector handles it)
	end

	-- Musical traffic must pass through untouched - never swallow it just to piggyback pending output,
	-- or notes will hang.
	return nil
end

-- Resolves a patchlist entry's label across the plausible field-name spellings MainStage might use
-- (docs/full-functionality-plan.md assumed .Label; an earlier version of this code assumed .Name;
-- neither alone was safe to trust).
function patch_label(entry)
	local candidates = { 'Label', 'Name', 'label', 'name', 'PatchName', 'patchname' }
	if type(entry) == 'table' then
		for _, key in ipairs(candidates) do
			local v = entry[key]
			if type(v) == 'string' and v ~= '' then return v end
		end
	end
	return tostring(entry)
end

-- Same idea for the fields the list model depends on (IsPatch/SetIndex/ PatchIndex): tries the
-- capitalised spelling (per docs/full-functionality-plan.md) then the all-lowercase one. Returns
-- nil (not false) when neither variant is present, so a genuinely-false IsPatch is distinguishable
-- from a missing key.
function patch_field(entry, field)
	if type(entry) ~= 'table' then return nil end
	local candidates = { field, field:lower() }
	for _, key in ipairs(candidates) do
		local v = entry[key]
		if v ~= nil then return v end
	end
	return nil
end

-- ARGUMENT HIERARCHY SHIFT: MainStage reuses this same callback for selections in Edit mode that
-- are NOT a patch - selecting a SET or the CONCERT there shifts the argument hierarchy up one
-- level, the selected thing arriving as patchname and its PARENT arriving as setname:
--   select a set:      patchname="2. Jacob & Sons / Joseph's Coat"  setname='Joseph key2'
--                       (setname is actually the CONCERT)
--   select the concert: patchname='Joseph key2'                    setname=''
-- Reverse of CC_MAP (CC number -> CC_MAP key), built once at load so controller_midi_out - which
-- fires constantly, thousands of times per idle session - never scans CC_MAP per call. See
-- docs/config-lua-history.md#controller_midi_out-reports-real-parameter-values-with-a-screen-control-2026-09-17.
CC_NUMBER_TO_KEY = {}
for key, cc in pairs(CC_MAP) do CC_NUMBER_TO_KEY[cc] = key end

-- Per-CC cached MainStage feedback (name/valueString/absolute 0-127 value/color), keyed by CC
-- number. Populated only for a control MainStage has assigned a screen control to - every other CC
-- has no entry here and the popup falls back to legacy mode. Read by show_popup() and
-- encoder_mute_state().
midiOutFeedback = {}

-- MainStage's own outbound-MIDI-feedback callback: reports the screen control assigned to a control
-- we emit, if any (name/valueString/color, absolute value in midiEvent[2]) - see the spec section
-- above for the hardware capture. Returns nil on EVERY path: our own outbound SL Link SysEx passes
-- through this same callback, and returning a table here would alter or swallow it.
-- Two MainStage colours are equal when both are absent or all three channels match. Compared at the
-- 7-bit resolution actually sent to the lamp, so float jitter below one step cannot churn the rings.
function colors_equal(a, b)
	if a == nil or b == nil then return a == nil and b == nil end
	return rgb7(a.r) == rgb7(b.r) and rgb7(a.g) == rgb7(b.g) and rgb7(a.b) == rgb7(b.b)
end

function controller_midi_out(midiEvent, name, valueString, color)
	if midiEvent == nil or midiEvent[0] ~= CC_STATUS then return nil end

	local cc = midiEvent[1]
	local key = CC_NUMBER_TO_KEY[cc]
	if key == nil then return nil end -- not one of ours

	-- MainStage reports the literal string 'Unmapped' (see
	-- Native Instruments/KOMPLETE KONTROL S61.device/config.lua:173 in the 4.3.1 bundle) for a
	-- control with no screen control assigned, same as nil - either way, no feedback for this CC.
	if name == nil or name == 'Unmapped' then
		midiOutFeedback[cc] = nil
		return nil
	end
	-- MainStage also reports an EMPTY name for a mapped control (observed on hardware 2026-09-20,
	-- cc 59). That is 'no name', not a name: painting it would leave the popup's title band blank.
	-- The entry is still kept - the colour and value behind it drive the encoder ring - so only the
	-- NAME is dropped, and the popup falls back to the physical encoder's own label.
	if name:match('^%s*$') ~= nil then name = nil end

	local value = midiEvent[2]
	local cleanValueString = sanitize_value_string(valueString)
	local prev = midiOutFeedback[cc]
	-- Colour is part of the tuple: it drives the encoder rings (flush_encoder_rings), and a patch change
	-- can report the SAME name and value in a different colour. Leaving colour out of this comparison
	-- left the ring showing the previous patch's colour, with nothing in any log.
	local sameColor = (prev ~= nil) and colors_equal(prev.color, color)
	if prev and prev.name == name and prev.valueString == cleanValueString and prev.value == value
		and sameColor then
		return nil -- unchanged tuple - a single static control reports this identically thousands of times
	end
	local wasMuted = prev and prev.value ~= 0
	midiOutFeedback[cc] = { name = name, valueString = cleanValueString, value = value, color = color }
	-- Logged on CHANGE only (the early return above filters the flood), so a capture shows what MainStage
	-- actually reports per control - including whether it varies the colour at all.
	slog('midi_out cc=' .. cc .. ' name=' .. tostring(name) .. ' value=' .. tostring(value) ..
		' color=' .. (color and (rgb7(color.r) .. '/' .. rgb7(color.g) .. '/' .. rgb7(color.b)) or 'nil'))

	-- A mute flipping is a one-off the user is waiting to SEE, and the LED only goes out on a tick -
	-- at KEEPALIVE_MS that is a ~3s lag. Pull the next tick forward. Safe from this flood-prone
	-- callback because request_quick_rearm only acts when the timer is armed at the slow interval,
	-- and only a real state change reaches here.
	-- name is nilable here: an empty report is normalised to nil above, and a nameless control cannot be
	-- a Mute.
	if name ~= nil and name:lower():find('mute', 1, true) and wasMuted ~= (value ~= 0) then
		request_quick_rearm()
	end
	return nil
end

-- controller_select_patch below trusts patchname/setname/concertname UNCONDITIONALLY - this is a
-- deliberate product decision (the user wants the selected value shown in the patch slot regardless
-- of hierarchy level), not an oversight. Do NOT reintroduce a 'refuse non-patch selections' guard
-- without checking with Jeroen first - see docs/config-lua-history.md#rejected-approaches.
function controller_select_patch(programchangeNumber, patchname, setname, concertname,
	patchlist, currentSetIndex, currentPatchIndex)
	local p, s, c = patchname or '', setname or '', concertname or ''

	-- CRASH-SAFETY GUARD ONLY (not the reverted 'refuse non-patch selections' behaviour above - see
	-- the ARGUMENT HIERARCHY SHIFT comment): MainStage's very first call happens before the concert
	-- has loaded, with patchlist nil/empty. There is nothing to browse yet, so bail out before
	-- touching displayed state rather than painting a blank/bogus name or letting the patchlist loop
	-- below run against nothing.
	if patchlist == nil or (type(patchlist) == 'table' and next(patchlist) == nil) then
		slog('controller_select_patch: patchlist not yet available - keeping last' ..
			' displayed patch "' .. patchName .. '"')
		return nil
	end

	-- MainStage calls this repeatedly with identical values (observed 5x for one patch change) - this
	-- is MainStage's own behaviour on a SINGLE script instance, confirmed on hardware, not the
	-- per-USB-MIDI-interface multi-instance scenario documented for this keyboard; a different
	-- MainStage/macOS version or USB mode could still produce it, so this guard stays regardless. See
	-- docs/config-lua-history.md#single-instance-confirmed-on-hardware-2026-08-28. Repainting each
	-- time would waste a lot of MIDI - a full repaint is several messages - so only redraw on a real
	-- change.
	--
	-- Extended beyond the original name-only check to also compare currentSetIndex/currentPatchIndex:
	-- two identically named patches in different sets or positions must still move the highlight,
	-- which a name-only comparison would miss entirely.
	if p == patchName and s == setName and c == currentConcert
		and currentSetIndex == activeSetIndex and currentPatchIndex == activePatchIndex then
		return nil
	end

	-- A new concert invalidates every stored parameter feedback: MainStage never announces that a
	-- control it used to report is gone, so a mute mapping from the previous concert would keep its
	-- ring lit forever. Dropping it lets flush_mute_leds dark-assert until the new concert reports.
	if c ~= currentConcert then midiOutFeedback = {} end

	patchName, setName, currentConcert = p, s, c
	activeSetIndex = currentSetIndex or activeSetIndex
	activePatchIndex = currentPatchIndex or activePatchIndex

	-- Rebuild the flat, interleaved list. ipairs(), NOT pairs(): the visual order of the continuous
	-- list IS patchlist's own array order (sets and patches interleaved as MainStage displays them -
	-- see docs/mainstage-integration.md), so this must preserve it, unlike the old per-set filter
	-- where scan order never mattered. Field names resolved via patch_label()/patch_field() above
	-- rather than trusted directly (that's what made the highlight bar blank on an earlier hardware
	-- run - see those functions' comments). patchIndex falls back to the array position when
	-- PatchIndex/patchindex is genuinely absent.
	listRows = {}
	if patchlist ~= nil then
		for i, entry in ipairs(patchlist) do
			if type(entry) == 'table' then
				local patchIndex = patch_field(entry, 'PatchIndex')
				listRows[#listRows + 1] = {
					label = patch_label(entry),
					isPatch = patch_field(entry, 'IsPatch') and true or false,
					setIndex = patch_field(entry, 'SetIndex'),
					patchIndex = patchIndex or (i - 1),
				}
			end
		end
	end

	-- Phase 1 has no independent browsing/cursor input yet (deferred to Phase 2's joystick handling) -
	-- the cursor simply tracks the active patch's position in the flat list.
	cursorIndex = find_active_row_index()

	-- currentConcert/setName logged alongside the existing fields so a blank concert line on the SL88
	-- screen can be told apart from a draw failure.
	slog('controller_select_patch: "' .. patchName .. '" (' .. #listRows .. ' rows total)' ..
		' concert="' .. currentConcert .. '" set="' .. setName .. '"' ..
		' activeSetIndex=' .. tostring(activeSetIndex) .. ' activePatchIndex=' .. tostring(activePatchIndex) ..
		' instance=' .. string.format('%02X', instanceID))

	-- Keep the visible window on the newly-set cursor - must run after listRows/cursorIndex are
	-- rebuilt above (clamp_scroll's upper bound depends on #listRows) and before the repaint below.
	clamp_scroll()

	if state == STATE_REIDENTIFY_WAIT then
		-- Don't queue or flush anything while waiting to retry identification (see
		-- handle_identification_rejected) - a flush here would send an Identification Query under an
		-- instanceID the SL88 just rejected, which would defeat the wait (see controller_midi_in's
		-- comment on the same hazard). The bookkeeping above (patchName/listRows/etc.) still ran, so once
		-- we are re-identified the ID_QUERY self-heal branch in handle_sl_frame finds lastPaintedPatch
		-- stale and repaints for real.
		return nil
	end

	-- Draw whenever MainStage says the patch changed, without waiting to be sure we are logged in: a
	-- LOGIN CONFIRMATION only arrives on a *fresh* login, and the keyboard harmlessly ignores drawing
	-- we are not entitled to do. The ID_QUERY branch repaints again once the session is confirmed.
	local opsBefore = queuedDisplayOps
	update_screen()
	if queuedDisplayOps > opsBefore then
		-- See request_quick_rearm's comment and docs/config-lua-history.md#quick-rearm-2026-08-21 - this
		-- is the exact call site the multi-second patch-change delay was measured against.
		request_quick_rearm()
	end
	return flush_pending(true)
end

-- MARK: - Device declaration

-- Items describe MIDI the SL88 **actually transmits**, captured live (notes, pitch bend,
-- modulation, second stick, sustain - all on LINK, none on CTRL). Ports use the short names for the
-- same reason outport does; see the banner at the top of this file.
--
-- The 23 gesture items below are written out literally, one per line, fields in the same order every
-- time, ordered by ascending CC number (51-74) to match CC_MAP - not generated - so they can be
-- compared by eye against CC_MAP/CC_LABEL above. CC_LABEL is still the source of truth for the names;
-- the harness asserts these literal strings match it.
function controller_info()
	local items = {
		{name='Keyboard', label='SL88', objectType='Keyboard', midiType='Keyboard',
			startKey=21, numberKeys=88, midi={0x90,MIDI_Wildcard,MIDI_Wildcard},
			inport='LINK', outport='LINK'},

		-- Stick 1 is the XY stick (X = pitch bend); Stick 2 is the modulation stick. The CC 16 ->
		-- Stick 1 Y attribution was confirmed on hardware 2026-09-05.
		{name='Stick 1 X', label='Pitch', objectType='Wheel', midi={0xE0,MIDI_MSB,MIDI_LSB},
			inport='LINK', outport='LINK'},
		{name='Stick 2 Mod', label='Mod', objectType='Wheel', midi={0xB0,0x01,MIDI_LSB},
			inport='LINK', outport='LINK'},
		{name='Stick 1 Y', label='Stick1Y', objectType='Wheel', midi={0xB0,0x10,MIDI_LSB},
			inport='LINK', outport='LINK'},

		{name='Sustain Pedal', label='Sustain', objectType='Sustain Pedal', midiType='Momentary',
			midi={0xB0,0x40,MIDI_LSB}, inport='LINK', outport='LINK'},

		-- No joystick items: the whole joystick drives patch selection in-script (see JOYSTICK_NAV),
		-- so CC 40-50 are unused and there is nothing for MainStage to learn.

		-- zone encoder pushes
		{name='Zone 1 Push',         objectType='Button',  midiType='Momentary',  midi={0xB0 + CC_CHANNEL, 51, MIDI_LSB}, inport='LINK', outport='LINK'},
		{name='Zone 1 Push (long)',  objectType='Button',  midiType='Momentary',  midi={0xB0 + CC_CHANNEL, 52, MIDI_LSB}, inport='LINK', outport='LINK'},
		{name='Zone 2 Push',         objectType='Button',  midiType='Momentary',  midi={0xB0 + CC_CHANNEL, 53, MIDI_LSB}, inport='LINK', outport='LINK'},
		{name='Zone 2 Push (long)',  objectType='Button',  midiType='Momentary',  midi={0xB0 + CC_CHANNEL, 54, MIDI_LSB}, inport='LINK', outport='LINK'},
		{name='Zone 3 Push',         objectType='Button',  midiType='Momentary',  midi={0xB0 + CC_CHANNEL, 55, MIDI_LSB}, inport='LINK', outport='LINK'},
		{name='Zone 3 Push (long)',  objectType='Button',  midiType='Momentary',  midi={0xB0 + CC_CHANNEL, 56, MIDI_LSB}, inport='LINK', outport='LINK'},
		{name='Zone 4 Push',         objectType='Button',  midiType='Momentary',  midi={0xB0 + CC_CHANNEL, 57, MIDI_LSB}, inport='LINK', outport='LINK'},
		{name='Zone 4 Push (long)',  objectType='Button',  midiType='Momentary',  midi={0xB0 + CC_CHANNEL, 58, MIDI_LSB}, inport='LINK', outport='LINK'},

		-- zone encoder turns
		{name='Zone 1 Encoder',  objectType='Knob',  midiType='Relative2C',  midi={0xB0 + CC_CHANNEL, 59, MIDI_LSB}, inport='LINK', outport='LINK'},
		{name='Zone 2 Encoder',  objectType='Knob',  midiType='Relative2C',  midi={0xB0 + CC_CHANNEL, 60, MIDI_LSB}, inport='LINK', outport='LINK'},
		{name='Zone 3 Encoder',  objectType='Knob',  midiType='Relative2C',  midi={0xB0 + CC_CHANNEL, 61, MIDI_LSB}, inport='LINK', outport='LINK'},
		{name='Zone 4 Encoder',  objectType='Knob',  midiType='Relative2C',  midi={0xB0 + CC_CHANNEL, 62, MIDI_LSB}, inport='LINK', outport='LINK'},

		-- B encoder
		{name='B Encoder',      objectType='Knob',    midiType='Relative2C',  midi={0xB0 + CC_CHANNEL, 63, MIDI_LSB}, inport='LINK', outport='LINK'},
		{name='B Push',         objectType='Button',  midiType='Momentary',   midi={0xB0 + CC_CHANNEL, 65, MIDI_LSB}, inport='LINK', outport='LINK'},
		{name='B Push (long)',  objectType='Button',  midiType='Momentary',   midi={0xB0 + CC_CHANNEL, 66, MIDI_LSB}, inport='LINK', outport='LINK'},

		-- zone selects
		{name='Zone 1 Select',         objectType='Button',  midiType='Momentary',  midi={0xB0 + CC_CHANNEL, 67, MIDI_LSB}, inport='LINK', outport='LINK'},
		{name='Zone 1 Select (long)',  objectType='Button',  midiType='Momentary',  midi={0xB0 + CC_CHANNEL, 68, MIDI_LSB}, inport='LINK', outport='LINK'},
		{name='Zone 2 Select',         objectType='Button',  midiType='Momentary',  midi={0xB0 + CC_CHANNEL, 69, MIDI_LSB}, inport='LINK', outport='LINK'},
		{name='Zone 2 Select (long)',  objectType='Button',  midiType='Momentary',  midi={0xB0 + CC_CHANNEL, 70, MIDI_LSB}, inport='LINK', outport='LINK'},
		{name='Zone 3 Select',         objectType='Button',  midiType='Momentary',  midi={0xB0 + CC_CHANNEL, 71, MIDI_LSB}, inport='LINK', outport='LINK'},
		{name='Zone 3 Select (long)',  objectType='Button',  midiType='Momentary',  midi={0xB0 + CC_CHANNEL, 72, MIDI_LSB}, inport='LINK', outport='LINK'},
		{name='Zone 4 Select',         objectType='Button',  midiType='Momentary',  midi={0xB0 + CC_CHANNEL, 73, MIDI_LSB}, inport='LINK', outport='LINK'},
		{name='Zone 4 Select (long)',  objectType='Button',  midiType='Momentary',  midi={0xB0 + CC_CHANNEL, 74, MIDI_LSB}, inport='LINK', outport='LINK'},
	}

	return {
		-- model MUST equal the hardware's reported kMIDIPropertyModel ('SL'), not the
		-- product name - a mismatch fails silently. See docs/mainstage-device-scripts.md §1.
		model = 'SL',
		manufacturer = 'STUDIOLOGIC',

		-- usb_vendor_id = 38166,  -- 0x9516
		-- usb_product_id = 16441, -- 0x4039

		patchselector = true,
		logicprox = false,

		items = items,
	}
end
