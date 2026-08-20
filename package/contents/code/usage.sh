#!/usr/bin/env bash
#
# usage.sh — fetch AI-coding-tool subscription usage and print one normalized JSON
# line. Supports several providers, all read from credentials those tools already
# store locally; every usage read below is a FREE metering call (not model
# inference), so it consumes no quota and costs nothing. Tokens are sent only to
# each provider's own host and are never logged.
#
# Subcommands:
#   usage.sh detect                 # probe which providers are signed in (no network)
#   usage.sh claude [TOKEN_SOURCE]  # Anthropic Claude   (GET api.anthropic.com/api/oauth/usage)
#   usage.sh codex                  # OpenAI Codex        (GET chatgpt.com/backend-api/wham/usage)
#   usage.sh opencode               # OpenCode Go         (GET opencode.ai/zen/go/v1/usage)
#   usage.sh copilot                # GitHub Copilot      (GET api.github.com/copilot_internal/user)
#   usage.sh gemini                 # Google Gemini       (free tier retired 2026-06-18 -> unavailable)
#
# Normalized success envelope (single stdout line):
#   {"ok":true,"provider":"claude","label":"Claude","plan":null,
#    "gauges":[{"id":"session","label":"Session","cap":"5H","pct":19,"reset":"2026-..","extra":false}, ...],
#    "fetchedAt":"2026-.."}
# Error envelope:
#   {"ok":false,"provider":"codex","label":"Codex","reason":"no_credentials"}
#
# detect output:
#   {"providers":{"claude":{"detected":true,"reason":"ok"}, "codex":{"detected":false,"reason":"no_credentials"}, ...}}

set -u

CACHE_DIR="${XDG_CACHE_HOME:-${HOME}/.cache}"
CACHE_TTL=90                         # seconds; serve cache younger than this
mkdir -p "$CACHE_DIR" 2>/dev/null

ISO_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# directory this script lives in (so we can find activity-hook.sh + settings.json)
SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
SETTINGS_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"

label_of() {
    case "$1" in
        claude)  echo "Claude"  ;;
        codex)   echo "Codex"   ;;
        opencode) echo "OpenCode Go" ;;
        copilot) echo "Copilot" ;;
        gemini)  echo "Gemini"  ;;
        *)       echo "$1"      ;;
    esac
}

emit_err() { # provider reason
    printf '{"ok":false,"provider":"%s","label":"%s","reason":"%s"}\n' \
        "$1" "$(label_of "$1")" "$2"
    exit 0
}

# --- per-provider cache + lock --------------------------------------------------
cache_path() { printf '%s/crewbeacon-usage-%s.json' "$CACHE_DIR" "$1"; }
lock_path()  { printf '%s/crewbeacon-usage-%s.lock' "$CACHE_DIR" "$1"; }

serve_fresh() { # provider -> prints cache and returns 0 when younger than TTL
    local f age mtime
    f="$(cache_path "$1")"
    [ -f "$f" ] || return 1
    mtime=$(stat -c %Y "$f" 2>/dev/null) || return 1
    age=$(( $(date +%s) - mtime ))
    [ "$age" -lt "$CACHE_TTL" ] || return 1
    cat "$f"
}

write_cache() { # provider out
    printf '%s\n' "$2" > "$(cache_path "$1").tmp" 2>/dev/null \
        && mv -f "$(cache_path "$1").tmp" "$(cache_path "$1")" 2>/dev/null
}

finish() { # provider out  — cache (success only) and emit
    if [ -z "$2" ]; then
        record_fail "$1"
        emit_stale_or_err "$1" "bad_json"
    fi
    write_cache "$1" "$2"
    printf '%s\n' "$2"
    exit 0
}

# Take the per-provider lock so concurrent widget instances dedupe the fetch.
take_lock() { # provider
    exec 9>"$(lock_path "$1")" 2>/dev/null
    flock -w 6 9 2>/dev/null
}

# --- transient-failure backoff + stale serving --------------------------------
# Unofficial endpoints (Codex/Copilot) flap with 5xx/curl errors. Rather than
# blanking the gauge and hammering the endpoint every poll, we serve the last
# good envelope marked stale and back off exponentially. Auth failures
# (401/403) are deliberately NOT backed off — they surface as an honest
# "sign-in expired" row so the user re-authenticates.
fail_path() { printf '%s/crewbeacon-usage-%s.fail' "$CACHE_DIR" "$1"; }

record_fail() { # provider — bump the consecutive transient-failure count
    local f c l
    f="$(fail_path "$1")"; c=0; l=0
    [ -f "$f" ] && read -r c l < "$f" 2>/dev/null
    case "$c" in ''|*[!0-9]*) c=0 ;; esac      # tolerate a corrupt count
    printf '%s %s\n' "$(( c + 1 ))" "$(date +%s)" > "$f.tmp" 2>/dev/null \
        && mv -f "$f.tmp" "$f" 2>/dev/null
}

clear_fail() { rm -f "$(fail_path "$1")" 2>/dev/null; }

in_backoff() { # provider — true (0) while still inside the backoff window
    local f c l now wait
    f="$(fail_path "$1")"
    [ -f "$f" ] || return 1
    c=""; l=""
    read -r c l < "$f" 2>/dev/null
    # a corrupt/non-numeric fail file must never abort the script under set -u
    case "$c" in ''|*[!0-9]*) return 1 ;; esac
    case "$l" in ''|*[!0-9]*) return 1 ;; esac
    now="$(date +%s)"
    wait=$(( 60 * (1 << ( c > 5 ? 5 : c - 1 )) ))   # 1,2,4,8,16,30 min …
    [ "$wait" -gt 1800 ] && wait=1800
    [ $(( now - l )) -lt "$wait" ]
}

emit_stale_or_err() { # provider reason — serve last-good cache (marked stale), else error
    local f now mtime age
    f="$(cache_path "$1")"
    if [ -f "$f" ]; then
        mtime=$(stat -c %Y "$f" 2>/dev/null) || mtime=0
        now=$(date +%s); age=$(( now - mtime ))
        jq -c --arg sr "$2" --argjson age "$age" \
           '. + {stale:true, staleReason:$sr, staleAgeSec:$age}' "$f" 2>/dev/null && exit 0
    fi
    emit_err "$1" "$2"
}

# ==============================================================================
# Token resolvers (presence checks never print secret values)
# ==============================================================================

CLAUDE_CRED="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"

claude_token() { # [source]  -> prints access token
    local src="${1:-auto}" cred
    case "$src" in
        auto|"") cred="$CLAUDE_CRED" ;;
        *)       cred="$src" ;;
    esac
    case "$cred" in
        *.json) [ -r "$cred" ] || return 1
                jq -r '.claudeAiOauth.accessToken // empty' "$cred" 2>/dev/null ;;
        *)      [ -r "$cred" ] || return 1
                head -n1 "$cred" | tr -d '[:space:]' ;;
    esac
}

claude_token_expired() { # [source]
    local src="${1:-auto}" cred exp now_ms
    case "$src" in auto|"") cred="$CLAUDE_CRED" ;; *.json) cred="$src" ;; *) return 1 ;; esac
    exp=$(jq -r '.claudeAiOauth.expiresAt // empty' "$cred" 2>/dev/null)
    [ -n "$exp" ] || return 1
    now_ms=$(( $(date +%s) * 1000 ))
    [ "$exp" -lt "$now_ms" ]
}

codex_auth_file() { printf '%s/auth.json' "${CODEX_HOME:-$HOME/.codex}"; }

opencode_auth_file() {
    printf '%s/opencode/auth.json' "${XDG_DATA_HOME:-$HOME/.local/share}"
}

copilot_token() { # prints a gho_/ghu_ style token from env or the copilot config files
    local v f t
    for v in "${COPILOT_GITHUB_TOKEN:-}" "${GH_TOKEN:-}" "${GITHUB_TOKEN:-}"; do
        [ -n "$v" ] && { printf '%s' "$v"; return 0; }
    done
    for f in "$HOME/.config/github-copilot/apps.json" \
             "$HOME/.config/github-copilot/oauth.json" \
             "$HOME/.copilot/config.json"; do
        [ -r "$f" ] || continue
        t="$(jq -r '
            [.. | objects | (.oauth_token // .accessToken // .token // empty)]
            | map(select(type=="string"
                  and (startswith("gho_") or startswith("ghu_")
                       or startswith("ghp_") or startswith("ghs_"))))
            | .[0] // empty' "$f" 2>/dev/null)"
        [ -n "$t" ] && { printf '%s' "$t"; return 0; }
    done
    return 1
}

gemini_creds() { printf '%s/.gemini/oauth_creds.json' "$HOME"; }

# ==============================================================================
# detect — filesystem-only probe, prints key presence (never secret values)
# ==============================================================================
detect_one() { # provider -> {"detected":bool,"reason":"..."}
    case "$1" in
        claude)
            if [ -r "$CLAUDE_CRED" ] && jq -e '.claudeAiOauth.accessToken' "$CLAUDE_CRED" >/dev/null 2>&1
            then echo '{"detected":true,"reason":"ok"}'
            else echo '{"detected":false,"reason":"no_credentials"}'; fi ;;
        codex)
            local f; f="$(codex_auth_file)"
            if [ -r "$f" ] && jq -e '.tokens.access_token and .tokens.account_id' "$f" >/dev/null 2>&1
            then echo '{"detected":true,"reason":"ok"}'
            else echo '{"detected":false,"reason":"no_credentials"}'; fi ;;
        opencode)
            local f; f="$(opencode_auth_file)"
            if [ -r "$f" ] && jq -e '."opencode-go".key | strings | length > 0' "$f" >/dev/null 2>&1
            then echo '{"detected":true,"reason":"ok"}'
            else echo '{"detected":false,"reason":"no_credentials"}'; fi ;;
        copilot)
            if copilot_token >/dev/null 2>&1
            then echo '{"detected":true,"reason":"ok"}'
            else echo '{"detected":false,"reason":"no_credentials"}'; fi ;;
        gemini)
            # The free "Login with Google" tier stopped serving on 2026-06-18, so even
            # when creds exist the usage read is unavailable -> detected but retired.
            if [ -r "$(gemini_creds)" ]
            then echo '{"detected":true,"reason":"tier_retired"}'
            else echo '{"detected":false,"reason":"no_credentials"}'; fi ;;
    esac
}

do_detect() {
    printf '{"providers":{"claude":%s,"codex":%s,"opencode":%s,"copilot":%s,"gemini":%s}}\n' \
        "$(detect_one claude)" "$(detect_one codex)" "$(detect_one opencode)" \
        "$(detect_one copilot)" "$(detect_one gemini)"
    exit 0
}

# ==============================================================================
# Provider fetchers
# ==============================================================================

normalize_claude_body() { # response-file [captured-at]
    jq -c --arg fa "${2:-$ISO_NOW}" '
        def slug:
            ascii_downcase | gsub("[^a-z0-9]+"; "-") | gsub("(^-|-$)"; "");
        def modern_windows:
            [(.limits // [])[]
             | select((.percent // null) != null)
             | (.scope.model.display_name // "") as $model
             | if .kind == "session" then
                   { id:"session", label:"Session", cap:"5H", extra:false,
                     pct:(.percent|round), reset:(.resets_at // null) }
               elif .kind == "weekly_all" then
                   { id:"weekly", label:"Weekly", cap:"7D", extra:false,
                     pct:(.percent|round), reset:(.resets_at // null) }
               elif .kind == "weekly_scoped" and ($model|length) > 0 then
                   { id:("weeklyScoped-" + ($model|slug)),
                     label:("Weekly · " + $model), cap:"7D", extra:false,
                     pct:(.percent|round), reset:(.resets_at // null) }
               else empty end]
            | unique_by(.id);
        modern_windows as $modern
        | {
            ok:true, provider:"claude", label:"Claude",
            plan:(.subscription_type // .subscriptionType // null),
            gauges: (if ($modern|length) > 0 then $modern else
                ([
                    { id:"session", label:"Session", cap:"5H", extra:false,
                      pct:((.five_hour.utilization // 0)|round), reset:(.five_hour.resets_at // null) },
                    { id:"weekly", label:"Weekly", cap:"7D", extra:false,
                      pct:((.seven_day.utilization // 0)|round), reset:(.seven_day.resets_at // null) }
                 ]
                 + (if (.seven_day_sonnet != null and .seven_day_sonnet.utilization != null)
                    then [{ id:"weeklySonnet", label:"Weekly · Sonnet", cap:"7D", extra:true,
                            pct:(.seven_day_sonnet.utilization|round), reset:(.seven_day_sonnet.resets_at // null) }]
                    else [] end)) end),
            fetchedAt:$fa
        }
    ' "$1" 2>/dev/null
}

normalize_codex_body() { # response-file [captured-at]
    jq -c --arg fa "${2:-$ISO_NOW}" '
        def num(v):
            if v == null then null
            elif (v|type) == "number" then v
            elif (v|type) == "string" and (v|test("^[0-9]+$")) then (v|tonumber)
            else null end;
        def slug:
            ascii_downcase | gsub("[^a-z0-9]+"; "-") | gsub("(^-|-$)"; "");
        def title_key:
            gsub("([a-z0-9])([A-Z])"; "\\1 \\2")
            | gsub("[_-]+"; " ")
            | split(" ")
            | map(select(length > 0) | ((.[0:1] | ascii_upcase) + .[1:]))
            | join(" ");
        def list(v): if (v|type) == "array" then v else [] end;
        def unique_ids:
            reduce .[] as $item ([];
                if any(.[]; .id == $item.id) then . else . + [$item] end);
        def window_seconds(w): num(w.limit_window_seconds // w.limitWindowSeconds);
        def cap_of(w; fallback):
            window_seconds(w) as $seconds
            | if $seconds == null then fallback
              elif ($seconds % 86400) == 0 then (($seconds / 86400 | floor | tostring) + "D")
              elif ($seconds % 3600) == 0 then (($seconds / 3600 | floor | tostring) + "H")
              else fallback end;
        def label_of_window(w; fallback; scoped):
            window_seconds(w) as $seconds
            | if $seconds == 18000 then (if scoped then "5-hour" else "Session" end)
              elif $seconds != null and $seconds >= 604800 then "Weekly"
              elif $seconds != null and $seconds >= 86400 then cap_of(w; fallback)
              else fallback end;
        def reset_of(w):
            ((w.reset_at // w.resetAt) as $ra
             | if $ra != null then
                   (if ($ra|type) == "number" then ($ra|todate) else $ra end)
               elif (w.reset_after_seconds // w.resetAfterSeconds) != null then
                   ((now + (w.reset_after_seconds // w.resetAfterSeconds))|todate)
               else null end);
        def rate_groups:
            . as $root
            | ([{ id:"base", name:"",
                  rate:($root.rate_limit // $root.rateLimit // $root.rate_limits // $root.rateLimits) }]
               + [list($root.additional_rate_limits // $root.additionalRateLimits)[]
                  | { id:(.metered_feature // .meteredFeature // .limit_name // .limitName // "additional"),
                      name:(.limit_name // .limitName // .metered_feature // .meteredFeature // "Additional limit"),
                      rate:(.rate_limit // .rateLimit) }]
               + [$root | to_entries[]
                  | select(.key != "rate_limit" and .key != "rateLimit"
                           and (.key | test("(_rate_limit|RateLimit)$")))
                  | select((.value | type) == "object")
                  | { id:.key, name:(.key | title_key), rate:.value }])
            | map(select((.rate | type) == "object"));
        def windows_of(group):
            [group.rate | to_entries[]
             | select((.value | type) == "object")
             | . as $entry
             | num($entry.value.used_percent // $entry.value.usedPercent) as $pct
             | select($pct != null)
             | ($entry.key | gsub("(_window|Window)$"; "")) as $role
             | label_of_window($entry.value; ($role | title_key); group.name != "") as $window_label
             | { id:(if group.id == "base" then ($role | slug)
                     else ((group.id | slug) + "-" + ($role | slug)) end),
                 label:(if group.name == "" then $window_label
                        else (group.name + " · " + $window_label) end),
                 cap:cap_of($entry.value; ""), extra:false,
                 pct:($pct | round), reset:reset_of($entry.value),
                 limited:((group.rate.allowed == false) or (group.rate.limit_reached == true)
                          or (group.rate.limitReached == true)) }];
        (.rate_limit // .rate_limits // .) as $rl
        | ($rl.secondary // $rl.secondary_window // $rl.secondaryWindow // .secondary // .secondary_window // .secondaryWindow) as $s
        | num($rl.banked_refreshes // $rl.bankedRefreshes
              // $rl.refreshes_banked // $rl.refreshesBanked
              // $rl.banked_refresh_count // $rl.bankedRefreshCount
              // .rate_limit_reset_credits.available_count
              // .rateLimitResetCredits.availableCount
              // .banked_refreshes // .bankedRefreshes
              // .refreshes_banked // .refreshesBanked
              // .banked_refresh_count // .bankedRefreshCount
              // $s.banked_refreshes // $s.bankedRefreshes
              // $s.refreshes_banked // $s.refreshesBanked
              // $s.banked_refresh_count // $s.bankedRefreshCount) as $banked
        | { ok:true, provider:"codex", label:"Codex",
            plan:(.plan_type // .planType // null),
            bankedRefreshes:$banked,
            gauges:([rate_groups[] as $group | windows_of($group)[]] | unique_ids),
            fetchedAt:$fa }
        | if (.gauges|length) == 0 then error("no_windows") else . end
    ' "$1" 2>/dev/null
}

normalize_opencode_body() { # response-file [captured-at]
    jq -c --arg fa "${2:-$ISO_NOW}" '
        def usage_window(wid; title; window_cap; value):
            if value == null or (value.percent // null) == null then empty
            else { id:wid, label:title, cap:window_cap, extra:false,
                   pct:((value.percent | tonumber) | round),
                   reset:(value.resetsAt // value.resets_at // null),
                   limited:((value.status // "ok") == "rate-limited") }
            end;
        (.usage // .) as $usage
        | { ok:true, provider:"opencode", label:"OpenCode Go", plan:"Go",
            gauges:[usage_window("session"; "5-hour"; "5H"; $usage.rolling),
                    usage_window("weekly"; "Weekly"; "7D"; $usage.weekly),
                    usage_window("monthly"; "Monthly"; "1M"; $usage.monthly)],
            fetchedAt:$fa }
        | if (.gauges|length) == 0 then error("no_windows") else . end
    ' "$1" 2>/dev/null
}

fetch_claude() {
    local src="${1:-auto}"
    serve_fresh claude && exit 0
    in_backoff claude && emit_stale_or_err claude backoff
    take_lock claude
    serve_fresh claude && exit 0

    [ -r "$CLAUDE_CRED" ] || [ "$src" != "auto" ] || emit_err claude no_credentials
    local token; token="$(claude_token "$src")"
    [ -n "$token" ] || emit_err claude no_token

    local cc_version body http rc out
    cc_version="$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    cc_version="${cc_version:-2.1.185}"
    body="$(mktemp 2>/dev/null)" || emit_err claude mktemp
    http="$(curl -s --max-time 8 -o "$body" -w '%{http_code}' \
        "https://api.anthropic.com/api/oauth/usage" \
        -H "Authorization: Bearer ${token}" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "User-Agent: claude-code/${cc_version}" \
        -H "Content-Type: application/json" 2>/dev/null)"
    rc=$?
    [ "$rc" -eq 0 ] || { rm -f "$body"; record_fail claude; emit_stale_or_err claude "curl_${rc}"; }
    if [ "$http" != "200" ]; then
        rm -f "$body"
        if [ "$http" = "401" ] || [ "$http" = "403" ]; then     # auth: honest error, no stale/backoff
            claude_token_expired "$src" && emit_err claude token_expired
            emit_err claude "http_${http}"
        fi
        record_fail claude                                       # transient: serve stale + back off
        emit_stale_or_err claude "http_${http}"
    fi

    out="$(normalize_claude_body "$body")"
    rm -f "$body"
    clear_fail claude
    finish claude "$out"
}

fetch_codex() {
    serve_fresh codex && exit 0
    in_backoff codex && emit_stale_or_err codex backoff
    take_lock codex
    serve_fresh codex && exit 0

    local f token account
    f="$(codex_auth_file)"
    [ -r "$f" ] || emit_err codex no_credentials
    token="$(jq -r '.tokens.access_token // empty' "$f" 2>/dev/null)"
    account="$(jq -r '.tokens.account_id // empty' "$f" 2>/dev/null)"
    [ -n "$token" ] || emit_err codex no_token

    local base body http rc out
    base="${CODEX_BASE_URL:-https://chatgpt.com/backend-api}"
    body="$(mktemp 2>/dev/null)" || emit_err codex mktemp
    http="$(curl -s --max-time 8 -o "$body" -w '%{http_code}' \
        "${base}/wham/usage" \
        -H "Authorization: Bearer ${token}" \
        ${account:+-H "ChatGPT-Account-Id: ${account}"} \
        -H "User-Agent: codex_cli_rs/0.0.0" \
        -H "Accept: application/json" 2>/dev/null)"
    rc=$?
    [ "$rc" -eq 0 ] || { rm -f "$body"; record_fail codex; emit_stale_or_err codex "curl_${rc}"; }
    if [ "$http" != "200" ]; then
        rm -f "$body"
        { [ "$http" = "401" ] || [ "$http" = "403" ]; } && emit_err codex token_expired
        record_fail codex
        emit_stale_or_err codex "http_${http}"
    fi

    # Window roles have changed over time. Derive the label and cap from the
    # provider-reported duration instead of assuming primary always means 5h.
    out="$(normalize_codex_body "$body")"
    rm -f "$body"
    clear_fail codex
    finish codex "$out"
}

fetch_opencode() {
    serve_fresh opencode && exit 0
    in_backoff opencode && emit_stale_or_err opencode backoff
    take_lock opencode
    serve_fresh opencode && exit 0

    local f token
    f="$(opencode_auth_file)"
    [ -r "$f" ] || emit_err opencode no_credentials
    token="$(jq -r '."opencode-go".key // empty' "$f" 2>/dev/null)"
    [ -n "$token" ] || emit_err opencode no_token

    local base body http rc out
    base="${OPENCODE_GO_BASE_URL:-https://opencode.ai/zen/go/v1}"
    body="$(mktemp 2>/dev/null)" || emit_err opencode mktemp
    http="$(curl -s --max-time 8 -o "$body" -w '%{http_code}' \
        "${base}/usage" \
        -H "Authorization: Bearer ${token}" \
        -H "User-Agent: opencode/$(opencode --version 2>/dev/null || printf 'unknown')" \
        -H "Accept: application/json" 2>/dev/null)"
    rc=$?
    [ "$rc" -eq 0 ] || { rm -f "$body"; record_fail opencode; emit_stale_or_err opencode "curl_${rc}"; }
    if [ "$http" != "200" ]; then
        rm -f "$body"
        { [ "$http" = "401" ]; } && emit_err opencode token_expired
        { [ "$http" = "403" ]; } && emit_err opencode no_subscription
        record_fail opencode
        emit_stale_or_err opencode "http_${http}"
    fi

    out="$(normalize_opencode_body "$body")"
    rm -f "$body"
    [ -n "$out" ] || { record_fail opencode; emit_stale_or_err opencode bad_json; }
    clear_fail opencode
    finish opencode "$out"
}

fetch_copilot() {
    serve_fresh copilot && exit 0
    in_backoff copilot && emit_stale_or_err copilot backoff
    take_lock copilot
    serve_fresh copilot && exit 0

    local token; token="$(copilot_token)" || emit_err copilot no_credentials
    [ -n "$token" ] || emit_err copilot no_token

    local body http rc out
    body="$(mktemp 2>/dev/null)" || emit_err copilot mktemp
    http="$(curl -s --max-time 8 -o "$body" -w '%{http_code}' \
        "https://api.github.com/copilot_internal/user" \
        -H "Authorization: token ${token}" \
        -H "Accept: application/json" \
        -H "Editor-Version: vscode/1.95.0" \
        -H "Editor-Plugin-Version: copilot-chat/0.23.0" \
        -H "User-Agent: GitHubCopilotChat/0.23.0" 2>/dev/null)"
    rc=$?
    [ "$rc" -eq 0 ] || { rm -f "$body"; record_fail copilot; emit_stale_or_err copilot "curl_${rc}"; }
    if [ "$http" != "200" ]; then
        rm -f "$body"
        { [ "$http" = "401" ] || [ "$http" = "403" ]; } && emit_err copilot token_expired
        record_fail copilot
        emit_stale_or_err copilot "http_${http}"
    fi

    # Copilot reports premium-request quota as "percent_remaining" (or remaining vs
    # entitlement). Normalize to a used-percent gauge to match the other providers,
    # and pass the raw remaining/entitlement through so the UI can show "142 / 300".
    out="$(jq -c --arg fa "$ISO_NOW" '
        (.quota_snapshots.premium_interactions) as $pi
        | { ok:true, provider:"copilot", label:"Copilot",
            plan:(.copilot_plan // null),
            gauges: (if $pi == null then []
                     else [{ id:"premium", label:"Premium requests", cap:"PRM", extra:false,
                             pct:( if ($pi.unlimited == true) then 0
                                   elif ($pi.percent_remaining != null) then ((100 - $pi.percent_remaining)|round)
                                   elif (($pi.entitlement // 0) > 0)
                                        then ((100 - (($pi.remaining // 0) / $pi.entitlement * 100))|round)
                                   else 0 end),
                             unlimited:($pi.unlimited // false),
                             remaining:(if ($pi.unlimited == true) then null else ($pi.remaining // null) end),
                             entitlement:($pi.entitlement // null),
                             reset:((.quota_reset_date // null)
                                    | if . == null then null else (. + "T00:00:00Z") end) }]
                     end),
            fetchedAt:$fa }
        | if (.gauges|length) == 0 then error("no_quota") else . end
    ' "$body" 2>/dev/null)"
    rm -f "$body"
    clear_fail copilot
    finish copilot "$out"
}

fetch_gemini() {
    # The individual "Login with Google" free tier stopped serving on 2026-06-18.
    # We detect the account (so the widget can show an honest row) but cannot read
    # live usage for it; Enterprise / API-key paths are out of scope here.
    if [ -r "$(gemini_creds)" ]; then emit_err gemini tier_retired
    else emit_err gemini no_credentials; fi
}

# ==============================================================================
# activity — read per-session assistant activity. Claude Code activity is
# recorded by activity-hook.sh (see contents/code/activity-hook.sh). Codex
# activity is inferred from recent ~/.codex/sessions rollout JSONL files.
# Concurrent chats are tracked separately; this aggregates them into:
#   {"ok":true, "state":"<aggregate>", "count":N, "sessions":[
#      {"provider":"claude","session":"..","cwd":"..","name":"proj",
#       "state":"working","ageSec":N,"stale":bool}, ...]}
# The aggregate "state" is the most urgent across sessions (attention > working >
# idle > none). A "working"/"attention" session not refreshed for a long time
# falls back to idle (safety net for a missed stop/final event); sessions
# untouched for >8h are dropped.
# ==============================================================================
emit_claude_activity() {
    local dir="$1" now="$2"
    [ -d "$dir" ] || return 0
    cat "$dir"/*.json 2>/dev/null | jq -c --argjson now "$now" '
        (.at // 0) as $at
        | (($now - $at) | if . < 0 then 0 else . end) as $age
        | (.state // "none") as $s0
        | (if   ($s0 == "working")   and ($age > 1200)  then {s:"idle", st:true}
           elif ($s0 == "attention") and ($age > 10800) then {s:"idle", st:true}
           else {s:$s0, st:false} end) as $r
        | { provider:"claude",
            session:(.session // ""), cwd:(.cwd // ""),
            name:(((.cwd // "") | split("/") | map(select(length > 0)) | last) // ""),
            state:$r.s, ageSec:$age, stale:$r.st,
            tool:(.tool // ""),
            turnSec:( (.turnStartedAt // 0) as $ts
                      | if ($ts > 0 and ($r.s == "working" or $r.s == "attention"))
                        then ($now - $ts) else 0 end ) }
    ' 2>/dev/null || true
}

codex_session_id_from_path() {
    local b
    b="$(basename "$1" .jsonl)"
    printf '%s\n' "$b" | sed -E 's/^rollout-[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}-//'
}

iso_to_epoch() {
    local iso="$1"
    [ -n "$iso" ] || return 1
    date -d "$iso" +%s 2>/dev/null
}

emit_codex_activity() {
    local dir now
    dir="${CODEX_HOME:-$HOME/.codex}/sessions"
    now="$1"
    [ -d "$dir" ] || return 0

    find "$dir" -type f -name '*.jsonl' -mmin -480 -printf '%T@ %p\n' 2>/dev/null \
        | sort -nr | head -50 | while IFS= read -r line; do
            local f last last_type last_payload last_phase last_ts last_epoch age meta sid cwd name model surface state tool turn_ts turn_epoch turn_sec stale
            f="${line#* }"
            [ -r "$f" ] || continue

            last="$(tail -n 1 "$f" 2>/dev/null)"
            [ -n "$last" ] || continue
            last_type="$(printf '%s\n' "$last" | jq -r '.type // ""' 2>/dev/null)"
            last_payload="$(printf '%s\n' "$last" | jq -r '.payload.type // ""' 2>/dev/null)"
            last_phase="$(printf '%s\n' "$last" | jq -r '.payload.phase // ""' 2>/dev/null)"

            # Codex does not expose a SessionEnd hook. A final task_complete line is
            # the best local signal that the active turn has finished.
            if [ "$last_type" = "event_msg" ] && [ "$last_payload" = "task_complete" ]; then
                continue
            fi
            if [ "$last_type" = "response_item" ] && [ "$last_payload" = "message" ] && [ "$last_phase" = "final_answer" ]; then
                continue
            fi

            meta="$(head -n 20 "$f" 2>/dev/null | jq -sc '
                map(select(.type == "session_meta" or .type == "turn_context"))
                | { sid:(([.[].payload.session_id, .[].payload.id] | map(select(. != null and . != "")) | first) // ""),
                    cwd:([.[].payload.cwd] | map(select(. != null and . != "")) | first // ""),
                    model:([.[].payload.model] | map(select(. != null and . != "")) | last // ""),
                    surface:(([.[].payload.source, .[].payload.originator]
                              | map(select(. != null and . != "")) | first) // "") }
            ' 2>/dev/null)"
            sid="$(printf '%s\n' "$meta" | jq -r '.sid // empty' 2>/dev/null)"
            [ -n "$sid" ] || sid="$(codex_session_id_from_path "$f")"
            cwd="$(printf '%s\n' "$meta" | jq -r '.cwd // empty' 2>/dev/null)"
            model="$(printf '%s\n' "$meta" | jq -r '.model // empty' 2>/dev/null)"
            surface="$(printf '%s\n' "$meta" | jq -r '.surface // empty' 2>/dev/null)"
            name=""
            [ -n "$cwd" ] && name="$(basename "$cwd")"

            last_ts="$(printf '%s\n' "$last" | jq -r '.timestamp // empty' 2>/dev/null)"
            last_epoch="$(iso_to_epoch "$last_ts" || true)"
            [ -n "$last_epoch" ] || last_epoch="$(stat -c %Y "$f" 2>/dev/null || echo "$now")"
            age=$((now - last_epoch))
            [ "$age" -lt 0 ] && age=0
            [ "$age" -gt 28800 ] && continue

            state="working"
            stale=false
            if [ "$age" -gt 1200 ]; then
                state="idle"
                stale=true
            fi

            tool="$(tail -n 200 "$f" 2>/dev/null | jq -sr '
                [ .[] | select(.type == "response_item" and .payload.type == "function_call")
                  | .payload.name ] | last // ""
            ' 2>/dev/null)"
            turn_ts="$(tail -n 1000 "$f" 2>/dev/null | jq -sr '
                [ .[] | select(.type == "event_msg" and .payload.type == "task_started")
                  | .timestamp ] | last // ""
            ' 2>/dev/null)"
            turn_epoch="$(iso_to_epoch "$turn_ts" || true)"
            turn_sec=0
            if [ -n "$turn_epoch" ] && [ "$state" = "working" ]; then
                turn_sec=$((now - turn_epoch))
                [ "$turn_sec" -lt 0 ] && turn_sec=0
            fi

            jq -cn --arg session "$sid" --arg cwd "$cwd" --arg name "$name" \
                   --arg model "$model" --arg surface "$surface" \
                   --arg state "$state" --arg tool "$tool" \
                   --argjson age "$age" --argjson stale "$stale" --argjson turnSec "$turn_sec" \
                '{provider:"codex", session:$session, cwd:$cwd, name:$name,
                  model:$model, surface:$surface, state:$state, ageSec:$age,
                  stale:$stale, tool:$tool, turnSec:$turnSec}'
        done
}

do_activity() {
    local dir legacy_dir now tmp out=""
    dir="${XDG_CACHE_HOME:-$HOME/.cache}/crewbeacon-claude-activity"
    legacy_dir="${XDG_CACHE_HOME:-$HOME/.cache}/conqrex-claude-activity"
    now="$(date +%s)"
    tmp="$(mktemp 2>/dev/null)" || { printf '{"ok":true,"state":"none","count":0,"sessions":[]}\n'; exit 0; }
    emit_claude_activity "$dir" "$now" >> "$tmp"
    [ "$legacy_dir" = "$dir" ] || emit_claude_activity "$legacy_dir" "$now" >> "$tmp"
    emit_codex_activity "$now" >> "$tmp"

    out="$(jq -sc '
            map(select(.state != "none" and .ageSec <= 28800))
            | group_by(.provider + ":" + .session)
            | map(sort_by(.ageSec) | .[0])
            | sort_by(.ageSec)
            | { ok:true,
                count: length,
                state: ( if   any(.[]; .state == "attention") then "attention"
                         elif any(.[]; .state == "working")   then "working"
                         elif length > 0                       then "idle"
                         else "none" end ),
                sessions: . }
        ' "$tmp" 2>/dev/null)"
    rm -f "$tmp"
    [ -n "$out" ] || out='{"ok":true,"state":"none","count":0,"sessions":[]}'
    printf '%s\n' "$out"
    exit 0
}

# ==============================================================================
# statusline — print a compact human one-liner from the cached envelopes, for
# dropping into a Claude Code statusLine command, tmux, polybar, etc. Reads only
# the per-provider cache the widget already populates (no network, no auth).
#   usage.sh statusline           ->  Claude 5H 19% · 7D 62%   Codex 5H 5% · 7D 12%
#   usage.sh statusline claude    ->  Claude 5H 19% · 7D 62%
# ==============================================================================
do_statusline() {
    local want="${1:-}" provs line="" sep="" p f seg
    if [ -n "$want" ]; then provs="$want"; else provs="claude codex opencode copilot"; fi
    for p in $provs; do
        f="$(cache_path "$p")"
        [ -f "$f" ] || continue
        seg="$(jq -r 'if (.ok != true) then empty else
            (.label) + " " +
            ([.gauges[] | select((.extra // false) | not) | "\(.cap) \(.pct)%"] | join(" · "))
            end' "$f" 2>/dev/null)"
        [ -n "$seg" ] && { line="${line}${sep}${seg}"; sep="   "; }
    done
    printf '%s\n' "$line"
    exit 0
}

# quota-catalog — expose only sanitized, normalized window metadata from the
# caches for the settings page. This performs no network request and never
# reads or emits provider credentials.
do_quota_catalog() {
    local p f item sep=""
    printf '{"providers":{'
    for p in claude codex opencode copilot gemini; do
        f="$(cache_path "$p")"
        [ -r "$f" ] || continue
        item="$(jq -c '
            select(.ok == true and (.gauges | type) == "array")
            | {label:(.label // ""), gauges:[.gauges[]
                | {id:(.id // ""), label:(.label // "Quota"), cap:(.cap // ""),
                   extra:(.extra // false)}
                | select(.id != "")]}
        ' "$f" 2>/dev/null)"
        [ -n "$item" ] || continue
        printf '%s"%s":%s' "$sep" "$p" "$item"
        sep=,
    done
    printf '}}\n'
    exit 0
}

# ==============================================================================
# hooks — install / remove / inspect the Claude Code activity hooks in
# ~/.claude/settings.json so the config page can offer a one-click setup. The
# six events point at this package's activity-hook.sh (resolved next to us).
# Merges are non-destructive (other hooks/settings preserved) and idempotent.
# ==============================================================================
HOOK_SCRIPT="$SELF_DIR/activity-hook.sh"

hooks_status() {
    if [ ! -f "$SETTINGS_FILE" ]; then echo '{"status":"missing","present":0,"mine":0,"total":6}'; exit 0; fi
    jq -c --arg h "$HOOK_SCRIPT" '
        (.hooks // {}) as $H
        | ["UserPromptSubmit","PreToolUse","PostToolUse","Stop","Notification","SessionEnd"] as $ev
        | ([ $ev[] | (($H[.] // []) | any(.[]?; (.hooks[]?.command // "") | contains("activity-hook.sh"))) ]
            | map(select(.)) | length) as $present
        | ([ $ev[] | (($H[.] // []) | any(.[]?; (.hooks[]?.command // "") | contains($h))) ]
            | map(select(.)) | length) as $mine
        | { present:$present, mine:$mine, total:6,
            status:(if $mine == 6 then "installed"
                    elif $present == 6 then "foreign"
                    elif $present > 0 then "partial"
                    else "missing" end) }
    ' "$SETTINGS_FILE" 2>/dev/null || echo '{"status":"error","present":0,"mine":0,"total":6}'
    exit 0
}

hooks_install() {
    mkdir -p "$(dirname "$SETTINGS_FILE")" 2>/dev/null
    [ -f "$SETTINGS_FILE" ] || printf '{}\n' > "$SETTINGS_FILE"
    cp -f "$SETTINGS_FILE" "${SETTINGS_FILE}.crewbeacon-bak" 2>/dev/null
    jq --arg prompt "bash '$HOOK_SCRIPT' prompt" \
       --arg pre    "bash '$HOOK_SCRIPT' pretool" \
       --arg work   "bash '$HOOK_SCRIPT' working" \
       --arg idle   "bash '$HOOK_SCRIPT' idle" \
       --arg att    "bash '$HOOK_SCRIPT' attention" \
       --arg end    "bash '$HOOK_SCRIPT' end" '
        def entry(cmd): { hooks: [ { type:"command", command:cmd } ] };
        def add(ev; cmd): .hooks[ev] = ((.hooks[ev] // []) + [ entry(cmd) ]);
        # strip any prior activity-hook.sh entries, drop emptied events, re-add fresh
        .hooks = ((.hooks // {})
            | with_entries(.value |= map(select(
                ((.hooks // []) | any(.[]?; (.command // "") | contains("activity-hook.sh"))) | not)))
            | with_entries(select(.value | length > 0)))
        | add("UserPromptSubmit"; $prompt)
        | add("PreToolUse"; $pre) | add("PostToolUse"; $work)
        | add("Stop"; $idle) | add("Notification"; $att) | add("SessionEnd"; $end)
    ' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp" 2>/dev/null \
        && mv -f "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE" \
        && echo '{"ok":true,"action":"install"}' \
        || { rm -f "${SETTINGS_FILE}.tmp" 2>/dev/null; echo '{"ok":false,"action":"install"}'; }
    exit 0
}

hooks_remove() {
    [ -f "$SETTINGS_FILE" ] || { echo '{"ok":true,"action":"remove"}'; exit 0; }
    cp -f "$SETTINGS_FILE" "${SETTINGS_FILE}.crewbeacon-bak" 2>/dev/null
    jq '
        .hooks = ((.hooks // {})
            | with_entries(.value |= map(select(
                ((.hooks // []) | any(.[]?; (.command // "") | contains("activity-hook.sh"))) | not)))
            | with_entries(select(.value | length > 0)))
        | if ((.hooks // {}) | length) == 0 then del(.hooks) else . end
    ' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp" 2>/dev/null \
        && mv -f "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE" \
        && echo '{"ok":true,"action":"remove"}' \
        || { rm -f "${SETTINGS_FILE}.tmp" 2>/dev/null; echo '{"ok":false,"action":"remove"}'; }
    exit 0
}

# ==============================================================================
# Dispatch
# ==============================================================================
PROVIDER="${1:-claude}"
case "$PROVIDER" in
    detect)        do_detect ;;
    activity)      do_activity ;;
    quota-catalog) do_quota_catalog ;;
    statusline)    shift; do_statusline "${1:-}" ;;
    _normalize-claude) shift; normalize_claude_body "$1" "${2:-$ISO_NOW}" ;;
    _normalize-codex)  shift; normalize_codex_body "$1" "${2:-$ISO_NOW}" ;;
    _normalize-opencode) shift; normalize_opencode_body "$1" "${2:-$ISO_NOW}" ;;
    hooks-status)  hooks_status ;;
    hooks-install) hooks_install ;;
    hooks-remove)  hooks_remove ;;
    claude)        shift; fetch_claude "${1:-auto}" ;;
    codex)         fetch_codex ;;
    opencode)      fetch_opencode ;;
    copilot)       fetch_copilot ;;
    gemini)        fetch_gemini ;;
    *)             emit_err "$PROVIDER" unknown_provider ;;
esac
