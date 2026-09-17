#!/bin/bash
# Collapses a LUA_DEBUG capture (/tmp/lua.log) down to the lines worth reading.
#
# A hardware run is ~95% repetition: every timer tick prints a tick line, a FLUSH line and the SL88
# identification reply, and a single encoder gesture prints dozens of near-identical volume writes.
# This keeps one line per DISTINCT event, collapses consecutive repeats of the same shape into a
# count, drops the keepalive chatter, and flags anomalies - so a run can be read with one command
# instead of paged through. See docs/config-lua-history.md for what the fields mean.
#
#   ./Scripts/lua-log-digest.sh [logfile]        # decoded events only - what a run is read for
#   ./Scripts/lua-log-digest.sh --flushes [log]  # add the per-message FLUSH lines
#   ./Scripts/lua-log-digest.sh --full [log]     # everything, uncollapsed
#
# Exit status is 0 even when anomalies are found - they are reported, not fatal.

set -uo pipefail

full=0
flushes=0
while [[ "${1:-}" == --* ]]; do
	case "$1" in
		--full)    full=1; flushes=1 ;;   # no collapsing at all
		--flushes) flushes=1 ;;           # include per-message FLUSH lines
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
	shift
done
log="${1:-/tmp/lua.log}"

if [[ ! -f "$log" ]]; then
	echo "no such log: $log" >&2
	echo "(run the test-mainstage-script skill first - it writes /tmp/lua.log)" >&2
	exit 1
fi

awk -v full="$full" -v showflush="$flushes" -v logfile="$log" '
# A line reduced to its shape: hex byte runs and bare numbers replaced by placeholders, so that
# twelve volume writes with different payloads collapse to one entry but a different event does not.
function shape(s) {
	gsub(/[0-9A-F][0-9A-F]( [0-9A-F][0-9A-F])+/, "<bytes>", s)
	sub(/^flush [A-Za-z][A-Za-z0-9]* /, "flush <region> ", s)  # a repaint cycles region ids; one shape
	gsub(/[0-9]+/, "#", s)
	return s
}
function line_out(t, text) {
	printf "  %6s  %s\n", (t == "" ? "-" : t), text
}
function flush_idle() {
	if (idle_run > 0) {
		line_out("...", sprintf("[%d idle ticks, keepalive only]", idle_run))
		idle_run = 0
	}
}
# Buffered emit: consecutive lines of the same shape print once, with a count and the last payload.
function emit(text,   sh) {
	sh = shape(text)
	if (pend_n > 0 && sh == pend_shape && !full) {
		pend_n++; pend_last = text; pend_tick2 = tick
		return
	}
	flush_pend()
	flush_idle()
	pend_shape = sh; pend_first = text; pend_last = text
	pend_n = 1; pend_tick1 = tick; pend_tick2 = tick
}
function flush_pend() {
	if (pend_n == 0) return
	line_out(pend_tick1, pend_first)
	if (pend_n > 1) {
		line_out("", sprintf("^ x%d through tick %s, last: %s", pend_n, pend_tick2, pend_last))
		collapsed += pend_n - 1
	}
	pend_n = 0
}

BEGIN {
	tick = ""; idle_run = 0; pend_n = 0
	ticks = 0; flushes = 0; keepalive = 0; collapsed = 0
	first_tick = -1; last_tick = -1; gaps = 0; version = "?"
	print "=== lua.log digest: " logfile " ==="
	print ""
	printf "  %6s  %s\n", "tick", "event"
	printf "  %6s  %s\n", "------", "-----"
}

# Strip the "[sllink <tag>/<instance>] " prefix in place, recording the instances seen, so every
# pattern below matches against the bare message. Lines without the prefix are host stdout noise
# from MainStage itself and are dropped.
{
	if (match($0, /^\[sllink [^]]*\] /)) {
		tag = substr($0, RSTART + 8, RLENGTH - 10)
		if (!(tag in seen_inst)) { seen_inst[tag] = 1; inst_list = inst_list (inst_list == "" ? "" : ", ") tag }
		$0 = substr($0, RSTART + RLENGTH)
	} else {
		next
	}
	line = $0
}

# --- timer ticks: tracked, never printed on their own ---
/^timer tick #/ {
	if (match(line, /#[0-9]+/)) tick = substr(line, RSTART + 1, RLENGTH - 1)
	ticks++
	if (first_tick < 0) first_tick = tick + 0
	if (last_tick >= 0 && tick + 0 != last_tick + 1) gaps++
	last_tick = tick + 0
	next
}

# --- the SL88 identification reply: pure noise once the session is up ---
/<- SYSEX on port=[A-Z]+: F0 00 20 1A 16 [0-9A-F]+ [0-9A-F]+ 7F 03 01 F7/ { keepalive++; next }

# --- flushes ---
/^FLUSH #/ {
	flushes++
	region = "none"
	if (match(line, /regionId=[A-Za-z0-9]+/)) region = substr(line, RSTART + 9, RLENGTH - 9)
	depth = ""
	if (match(line, /queueDepthAfter=[0-9]+/)) depth = substr(line, RSTART + 16, RLENGTH - 16)
	bytes = ""
	if (match(line, /bytes=[0-9]+/)) bytes = substr(line, RSTART + 6, RLENGTH - 6)

	# An idle flush is the bare Identification Query going out with nothing queued behind it.
	if (region == "none" && depth == "0" && line ~ /msg=F0 00 20 1A 16 [0-9A-F]+ [0-9A-F]+ 00 00 F7/ && !full) {
		flush_pend(); idle_run++; next
	}

	if (!showflush) { flush_pend(); next }
	if (region == "none") {
		msg = ""
		if (match(line, /msg=.*/)) msg = substr(line, RSTART + 4, RLENGTH - 4)
		emit(sprintf("flush %sB depth=%s  %s", bytes, depth, msg))
	} else {
		emit(sprintf("flush %-18s %sB depth=%s", region, bytes, depth))
	}
	if (bytes + 0 > 256) anomaly[++n_anom] = sprintf("tick %s: FLUSH of %s bytes - over any plausible budget", tick, bytes)
	next
}

# --- everything else is signal ---
{
	if (line ~ /controller_initialize/) {
		inits++
		if (match(line, /version=[0-9.]+/)) version = substr(line, RSTART + 8, RLENGTH - 8)
		next
	}
	if (line ~ /controller_finalize/) { finals++; next }
	if (line == "") next
	emit(line)
}

END {
	flush_pend()
	flush_idle()
	print ""
	print "=== summary ==="
	printf "  script version    %s\n", version
	printf "  instances         %s\n", (inst_list == "" ? "(none seen)" : inst_list)
	printf "  init/finalize     %d init, %d finalize\n", inits, finals
	if (ticks > 0)
		printf "  ticks             %d (#%d-#%d)%s\n", ticks, first_tick, last_tick, (gaps > 0 ? sprintf("  <-- %d GAP(S)", gaps) : " contiguous")
	else
		printf "  ticks             0  <-- NO TIMER TICKS: dead clock\n"
	printf "  flushes           %d\n", flushes
	printf "  keepalive replies %d\n", keepalive
	printf "  repeats collapsed %d\n", collapsed
	if (ticks > 0 && keepalive == 0)
		anomaly[++n_anom] = "no identification replies at all - the SL88 never answered"
	if (n_anom > 0) {
		print ""
		print "=== anomalies ==="
		for (i = 1; i <= n_anom; i++) print "  ! " anomaly[i]
	}
}
' "$log"
