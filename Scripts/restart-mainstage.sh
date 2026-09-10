#!/bin/bash
# Quits MainStage (answering its "save the concert?" prompt with Don't Save),
# waits for it to actually exit, then relaunches it.
#
# Why this exists: testing a MainStage device script means relaunching MainStage
# after every edit, and MainStage frequently asks whether to save the concert on
# quit. That dialog must be answered one way or the other - see --save below for
# which, and which this project uses - and, just as importantly, an unanswered dialog silently
# blocks the quit, so the relaunch never happens and the next test looks like it
# failed for unrelated reasons.
#
# Usage:
#   Scripts/restart-mainstage.sh              # quit + relaunch
#   Scripts/restart-mainstage.sh --debug      # relaunch with LUA_DEBUG output
#                                             # redirected to /tmp/lua.log
#   Scripts/restart-mainstage.sh --quit-only  # quit and stay quit
#
# Add --save BEFORE the mode to answer the prompt with Save instead:
#   Scripts/restart-mainstage.sh --save --debug
# The script's default is Don't Save, but the project's standing instruction is to
# pass --save on every test restart - losing hand-made MIDI-Learn assignments costs
# far more than saving does. See .claude/skills/test-mainstage-script/SKILL.md.

set -uo pipefail

MAINSTAGE_BIN="/Applications/MainStage.app/Contents/MacOS/MainStage"
LUA_LOG="/tmp/lua.log"

mode="${1:-}"
save_mode="no"
if [ "$mode" = "--save" ]; then
    save_mode="yes"
    shift
    mode="${1:-}"
fi

if [ "$save_mode" = "yes" ]; then
    echo "Quitting MainStage (answering SAVE)..."
else
    echo "Quitting MainStage..."
fi
# Only an ASCII mode word crosses the environment boundary - the button names
# themselves are built inside the AppleScript below, since `system attribute`
# mis-decodes UTF-8 (e.g. the curly apostrophe in "Don't Save") as MacRoman.
if [ "$save_mode" = "yes" ]; then
    button_mode="save"
else
    button_mode="dontsave"
fi

osascript -e 'tell application "MainStage" to quit' >/dev/null 2>&1 &
quit_pid=$!

# Dismiss the save prompt if it shows up. Poll rather than sleep-then-click:
# the dialog can take a moment to appear, and on a concert with no changes it
# never appears at all.
for _ in $(seq 1 120); do
    if ! pgrep -f "$MAINSTAGE_BIN" >/dev/null 2>&1; then
        break
    fi
    # The prompt is a SHEET attached to a window, so its buttons are NOT in
    # `buttons of w` - they live in `buttons of sheet 1 of w`. Searching only the
    # window silently found nothing and the quit stalled with the dialog on
    # screen, which is exactly the failure this script exists to prevent. Search
    # both, and every sheet rather than assuming sheet 1.
    BUTTON_MODE="$button_mode" osascript >/dev/null 2>&1 <<'APPLESCRIPT'
set curly to character id 8217
set ellipsis to character id 8230
if (system attribute "BUTTON_MODE") is "save" then
    set wantedNames to {"Save", "Save" & ellipsis, "Bewaar", "Bewaren", "Opslaan"}
else
    set wantedNames to {"Don't Save", "Don" & curly & "t Save", "Niet bewaren", "Niet saven", "Niet opslaan"}
end if
tell application "System Events"
    if exists (process "MainStage") then
        tell process "MainStage"
            repeat with w in (every window)
                repeat with b in (every button of w)
                    if wantedNames contains (name of b as text) then
                        click b
                        return
                    end if
                end repeat
                repeat with s in (every sheet of w)
                    repeat with b in (every button of s)
                        if wantedNames contains (name of b as text) then
                            click b
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
    end if
end tell
APPLESCRIPT
    sleep 0.5
done

wait "$quit_pid" 2>/dev/null

# Confirm it really exited before doing anything else.
for _ in $(seq 1 120); do
    pgrep -f "$MAINSTAGE_BIN" >/dev/null 2>&1 || break
    sleep 0.5
done

if pgrep -f "$MAINSTAGE_BIN" >/dev/null 2>&1; then
    echo "warning: MainStage is still running - a dialog may still be open on screen." >&2
    exit 1
fi
echo "MainStage exited."

[ "$mode" = "--quit-only" ] && exit 0

if [ "$mode" = "--debug" ]; then
    rm -f "$LUA_LOG"
    echo "Relaunching with LUA_DEBUG -> $LUA_LOG"
    nohup "$MAINSTAGE_BIN" > "$LUA_LOG" 2>&1 &
    disown
else
    echo "Relaunching MainStage..."
    open -a MainStage
fi
