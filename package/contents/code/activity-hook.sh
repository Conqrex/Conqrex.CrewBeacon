#!/usr/bin/env bash
#
# activity-hook.sh — Claude Code activity hook for CrewBeacon.
#
# Registered from ~/.claude/settings.json (the widget can do this for you from
# its settings page) and invoked as:
#     activity-hook.sh prompt     # UserPromptSubmit — turn starts (busy)
#     activity-hook.sh pretool    # PreToolUse  — busy, labelled with the tool;
#                                 #   tools that block on you (AskUserQuestion,
#                                 #   ExitPlanMode) become "attention"
#     activity-hook.sh working    # PostToolUse — busy, tool cleared
#     activity-hook.sh idle       # Stop        — turn finished
#     activity-hook.sh attention  # Notification — needs you
#     activity-hook.sh end        # SessionEnd  — forget this session
#
# State is recorded PER SESSION so concurrent chats don't clobber each other:
# one JSON file per session_id under
#     ${XDG_CACHE_HOME:-~/.cache}/crewbeacon-claude-activity/<session_id>.json
# carrying {state, at, turnStartedAt, tool, cwd, session}. The hook payload
# (session_id, cwd, tool_name, tool_input, …) arrives as JSON on stdin. Always
# exits 0 and writes nothing to stdout, so it can never block or fail a turn.

mode="${1:-idle}"
payload="$(cat 2>/dev/null)"

dir="${XDG_CACHE_HOME:-$HOME/.cache}/crewbeacon-claude-activity"
mkdir -p "$dir" 2>/dev/null

sid="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$sid" ] || sid="default"
sid="$(printf '%s' "$sid" | tr -c 'A-Za-z0-9._-' '_')"   # keep the filename safe
file="$dir/$sid.json"

if [ "$mode" = "end" ]; then
    rm -f "$file" 2>/dev/null
    exit 0
fi

now="$(date +%s 2>/dev/null)" || now=0

# carry the turn-start timestamp across a turn (prompt resets it, idle clears it)
prevTurn=0
[ -f "$file" ] && prevTurn="$(jq -r '.turnStartedAt // 0' "$file" 2>/dev/null)"
case "$prevTurn" in ''|*[!0-9]*) prevTurn=0 ;; esac

tool=""
case "$mode" in
    prompt)    state="working";   turn="$now" ;;
    working)   state="working";   turn="$prevTurn" ;;
    attention) state="attention"; turn="$prevTurn" ;;
    idle)      state="idle";      turn=0 ;;
    pretool)
        state="working"; turn="$prevTurn"
        case "$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)" in
            AskUserQuestion|ExitPlanMode) state="attention" ;;
        esac
        local_name="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)"
        # collapse whitespace/newlines and cap at 40 chars *overall* (cut -c is
        # per-line, so a multi-line command would otherwise leak newlines)
        detail="$(printf '%s' "$payload" | jq -r \
            '((.tool_input.command // .tool_input.file_path // .tool_input.pattern // .tool_input.url // .tool_input.description // "") | tostring | gsub("\\s+"; " ") | gsub("^ | $"; "") | .[0:40])' 2>/dev/null)"
        if [ -n "$local_name" ]; then
            tool="$local_name"
            [ -n "$detail" ] && tool="$local_name: $detail"
        fi
        ;;
    *)         state="$mode";     turn="$prevTurn" ;;
esac

# a busy state with no running turn starts one now
{ [ "$state" = "working" ] || [ "$state" = "attention" ]; } && [ "$turn" = "0" ] && turn="$now"

tmp="$file.$$.tmp"
if printf '%s' "$payload" | jq -c --arg s "$state" --argjson t "$now" \
       --argjson ts "$turn" --arg tool "$tool" \
       '{state:$s, at:$t, turnStartedAt:$ts, tool:$tool, cwd:(.cwd // ""), session:(.session_id // "")}' \
       >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv -f "$tmp" "$file" 2>/dev/null
else
    rm -f "$tmp" 2>/dev/null
    printf '{"state":"%s","at":%s,"turnStartedAt":%s,"tool":"","cwd":"","session":"%s"}\n' \
        "$state" "$now" "$turn" "$sid" >"$file" 2>/dev/null
fi

# housekeeping: forget session files untouched for over a day (abnormal exits)
find "$dir" -maxdepth 1 -name '*.json' -mmin +1440 -delete 2>/dev/null
exit 0
