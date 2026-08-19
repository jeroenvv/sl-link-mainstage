#!/bin/bash
# Quits MainStage (answering its "save the concert?" prompt with Don't Save),
# waits for it to actually exit, then relaunches it.
#
# Why this exists: testing a MainStage device script means relaunching MainStage
# after every edit, and MainStage frequently asks whether to save the concert on
# quit. That dialog must be answered "Don't Save" - test runs must never modify
# the user's concert - and, just as importantly, an unanswered dialog silently
# blocks the quit, so the relaunch never happens and the next test looks like it
# failed for unrelated reasons.
#
# Usage:
#   Scripts/restart-mainstage.sh              # quit + relaunch
#   Scripts/restart-mainstage.sh --debug      # relaunch with LUA_DEBUG output
#                                             # redirected to /tmp/lua.log
#   Scripts/restart-mainstage.sh --quit-only  # quit and stay quit

set -uo pipefail

MAINSTAGE_BIN="/Applications/MainStage.app/Contents/MacOS/MainStage"
LUA_LOG="/tmp/lua.log"

mode="${1:-}"

echo "Quitting MainStage..."
osascript -e 'tell application "MainStage" to quit' >/dev/null 2>&1 &
quit_pid=$!

# Dismiss the save prompt if it shows up. Poll rather than sleep-then-click:
# the dialog can take a moment to appear, and on a concert with no changes it
# never appears at all.
for _ in $(seq 1 20); do
    if ! pgrep -f "$MAINSTAGE_BIN" >/dev/null 2>&1; then
        break
    fi
    osascript >/dev/null 2>&1 <<'APPLESCRIPT'
tell application "System Events"
    if exists (process "MainStage") then
        tell process "MainStage"
            repeat with w in (every window)
                repeat with b in (every button of w)
                    -- Localised builds may title it differently; match the
                    -- common spellings rather than assuming English.
                    if (name of b is "Don't Save") or (name of b is "Don’t Save") ¬
                        or (name of b is "Niet bewaren") or (name of b is "Niet saven") then
                        click b
                        return
                    end if
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
for _ in $(seq 1 20); do
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
