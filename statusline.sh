#!/usr/bin/env bash
# claude-statusline: a compact, zero-config status line for Claude Code
# https://github.com/domvsca/claude-statusline · MIT License
#
#   Opus 5.5 (max) │ ● headroom:8787 │ ≈$12.35 1h12m │ ctx ━━━━━───── 46% of 1M ❄ │ 7d ━━━━────── 41% ↻3d2h
#   ~/Code/my-app │ main* │ 5b1c2d3e-4f5a-6b7c-8d9e-0f1a2b3c4d5e
#
#   Opus 5.5 (max)   model and effort level; ⚡fast when fast mode is on
#   ● headroom:8787  API calls go through the local proxy on that port (from ANTHROPIC_BASE_URL):
#                    green ● = Headroom is ready · yellow ! = Headroom runs but is not ready (starting
#                    up, or one of its checks fails, such as reaching the API) · red ✗ = nothing
#                    answers, so the calls fail · dim "proxy:PORT" = a local proxy that is not
#                    Headroom · yellow "no headroom" = Headroom is installed but this session
#                    bypasses it
#   ≈$12.35 1h12m    estimated session cost at API list prices, and session time
#   ctx 46% of 1M    context window used, and its size for the model in use:
#                    green <60%, yellow 60-79%, red 80%+
#   ❄                the prompt cache has expired: the next message re-sends the context at full price
#   7d 41% ↻3d2h     subscription usage over 7 days, with the time to its reset (↻); a 5h window is
#                    shown the same way when Claude Code sends one. The colour is the usage
#                    projected to the end of the window at the current pace: green <85%,
#                    yellow 85-99%, red 100%+ (you would run out before the reset)
#   ━━━━━─────       each percentage gets a bar in its colour when the terminal is wide enough
#   ~/Code/my-app    the folder Claude Code is working in (~ = your home folder)
#   main*            git branch (* = uncommitted changes)
#   5b1c2d3e-…       session id
#
# Narrow terminal ($COLUMNS): the bars shrink from 10 cells to 4, then go. After that the first line
# drops the cents ("headroom" becomes "hr"), then the session time, then ↻, then the context size.
# The second line cuts the session id to 8 characters, then shortens the path from the left
# (…/Code/my-app).
#
# Input: the JSON Claude Code sends on stdin (https://code.claude.com/docs/en/statusline).
# Needs bash 3.2+ and jq; git and curl are optional.

IFS= read -r -d '' input || true

if ! command -v jq >/dev/null 2>&1; then
  printf 'statusline: jq not found'
  exit 0
fi

# Byte semantics everywhere; the visible width is computed in code points further down
export LC_ALL=C
tmp=${TMPDIR:-/tmp}
tmp=${tmp%/}

# One jq call extracts everything. Decimals and times (now) are handled in jq,
# so bash only sees integers. @sh quotes every value for a safe eval.
eval "$(printf '%s' "$input" | jq -r '
  # usage window -> % used, seconds to reset, % projected at the end of the window
  def win($len):
    if .used_percentage == null then {u: "", eta: "", proj: ""}
    else
      .used_percentage as $u
      | (if .resets_at == null then null else .resets_at - now end) as $rem
      | (if $rem == null then null
         else 1 - $rem / $len | if . < 0 then 0 elif . > 1 then 1 else . end
         end) as $el
      | { u: ($u | round),
          eta: (if $rem != null and $rem > 0 then $rem | floor else "" end),
          # in the first 20% of a window divide by 0.2 anyway: no alarms after a few minutes
          proj: (if $el == null then "" else $u / ([$el, 0.2] | max) | round end) }
    end;
  (.rate_limits.five_hour // {} | win(18000)) as $h5
  | (.rate_limits.seven_day // {} | win(604800)) as $d7
  | { model:   (.model.display_name // "?"),
      effort:  (.effort.level // ""),
      fast:    (.fast_mode == true),
      cwd:     (.workspace.current_dir // .cwd // ""),
      sid:     (.session_id // ""),
      cents:   ((.cost.total_cost_usd // 0) * 100 | round),
      dur:     ((.cost.total_duration_ms // 0) / 1000 | floor),
      # the percentage comes from Claude Code, which divides by the window of the model in use
      ctx:     (.context_window.used_percentage | if . == null then "" else round end),
      # window size in tokens -> 200k, 1M
      ctx_max: (.context_window.context_window_size
                | if type != "number" or . <= 0 then ""
                  elif . >= 1000000 then "\(. / 100000 | round / 10)M"
                  else "\(. / 1000 | round)k" end),
      cold:    ((.prompt_cache.caching_observed == true) and (.prompt_cache.warm == false)),
      rl5: $h5.u, rl5_eta: $h5.eta, rl5_proj: $h5.proj,
      rl7: $d7.u, rl7_eta: $d7.eta, rl7_proj: $d7.proj,
      now: (now | floor) }
  | to_entries[] | "\(.key)=\(.value | tostring | @sh)"
' 2>/dev/null)"

# the working folder as shown: ~ for $HOME, and no control characters, which would break the line
path=${cwd:-}
path=${path//[[:cntrl:]]/?}
home=${HOME:-}
home=${home%/}
if [ -n "$home" ]; then
  case "$path" in
    "$home") path="~" ;;
    "$home"/*) path="~${path#"$home"}" ;;
  esac
fi
: "${model:=?}" "${cwd:=.}" "${cents:=0}" "${dur:=0}" "${now:=0}"

# Claude Code draws the status line in grey. A colour replaces the grey, dim makes it fainter,
# bold only changes the weight.
ESC=$'\033'
RESET="${ESC}[0m"; DIM="${ESC}[2m"; BOLD="${ESC}[1m"
RED="${ESC}[31m"; GREEN="${ESC}[32m"; YELLOW="${ESC}[33m"
MAGENTA="${ESC}[35m"; CYAN="${ESC}[36m"

# The functions below never run in a subshell, so none of them costs a fork: a result goes into the
# variable named by $1, and the pieces of a line are appended to $out.

# colour of a % used (context, or a usage window without a reset time): green <60, yellow 60-79, red 80+
pct_color() {
  if [ "$2" -ge 80 ]; then printf -v "$1" '%s' "$RED"
  elif [ "$2" -ge 60 ]; then printf -v "$1" '%s' "$YELLOW"
  else printf -v "$1" '%s' "$GREEN"; fi
}

# colour of a usage window: $2 = % used, $3 = % projected at the end of the window
rl_color() {
  if [ -z "$3" ]; then pct_color "$1" "$2"
  elif [ "$3" -ge 100 ]; then printf -v "$1" '%s' "$RED"
  elif [ "$3" -ge 85 ]; then printf -v "$1" '%s' "$YELLOW"
  else printf -v "$1" '%s' "$GREEN"; fi
}

# seconds -> 3d4h | 1h05m | 42m
fmt_dur() {
  local s=$2
  if [ "$s" -ge 86400 ]; then
    if [ $((s % 86400 / 3600)) -gt 0 ]; then printf -v "$1" '%dd%dh' $((s / 86400)) $((s % 86400 / 3600))
    else printf -v "$1" '%dd' $((s / 86400)); fi
  elif [ "$s" -ge 3600 ]; then printf -v "$1" '%dh%02dm' $((s / 3600)) $((s % 3600 / 60))
  else printf -v "$1" '%dm' $((s / 60)); fi
}

# A line is built twice over: $out carries the colour codes, $plain is the same text without them.
# The width is measured on $plain, because stripping the codes from $out is slow in bash 3.2.
out="" plain=""

# put TEXT [COLOUR]: append TEXT to the line, in COLOUR when one is given
put() {
  plain+=$1
  if [ -n "${2:-}" ]; then out+="$2$1${RESET}"; else out+=$1; fi
}

sep() { put " │ " "$DIM"; }

# width of the text $2: its code points (UTF-8 continuation bytes don't count)
lo=$'\x80' hi=$'\xbf'
width() {
  local c=${2//[!$lo-$hi]/}
  printf -v "$1" '%d' $(( ${#2} - ${#c} ))
}

# append a bar of $cells cells: $1 = % filled, $2 = colour of the filled part.
# Under LC_ALL=C a substring counts bytes, and each of these glyphs is 3 bytes
BAR_ON="━━━━━━━━━━" BAR_OFF="──────────"
cells=10
bar() {
  local n=$(( ($1 * cells + 50) / 100 ))
  [ "$n" -gt "$cells" ] && n=$cells
  [ "$n" -gt 0 ] && put "${BAR_ON:0:n*3}" "$2"
  [ "$n" -lt "$cells" ] && put "${BAR_OFF:0:(cells-n)*3}" "$DIM"
}

case "$effort" in
  max)   effort_c="${BOLD}${MAGENTA}" ;;
  xhigh) effort_c="${MAGENTA}" ;;
  high)  effort_c="${CYAN}" ;;
  low)   effort_c="${DIM}" ;;
  *)     effort_c="" ;;
esac

# git branch (short SHA when detached) and * for uncommitted changes,
# cached for 5 s per folder because git status can be slow in big repositories
branch="" dirty=0
if command -v git >/dev/null 2>&1; then
  key=${cwd//[!A-Za-z0-9]/_}
  [ ${#key} -gt 150 ] && key=${key: -150}
  git_cache="$tmp/claude-statusline-git-$key"
  g_ts="" g_dirty="" g_branch=""
  [ -r "$git_cache" ] && read -r g_ts g_dirty g_branch < "$git_cache"
  case "$g_ts" in ''|*[!0-9]*) g_ts=-999 ;; esac
  age=$((now - g_ts))
  if [ "$age" -ge 0 ] && [ "$age" -lt 5 ]; then
    branch=$g_branch dirty=$g_dirty
  else
    branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short -q HEAD 2>/dev/null ||
             git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
    if [ -n "$branch" ] && [ -n "$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)" ]; then
      dirty=1
    fi
    printf '%s %s %s\n' "$now" "$dirty" "$branch" > "$git_cache" 2>/dev/null
  fi
fi

# Proxy. The script inherits the environment of the claude process, so ANTHROPIC_BASE_URL is
# where this session sends its API calls. A local URL is probed on /readyz (Headroom's readiness
# endpoint: 200 when it can serve the calls, 503 when it cannot) at most every 15 s per port;
# the result is shared by all sessions.
px_port="" px_state="" px_hp="" px_label=proxy hr_bypassed=0
case "${ANTHROPIC_BASE_URL:-}" in
  http://127.0.0.1:*|http://localhost:*|https://127.0.0.1:*|https://localhost:*)
    px_hp=${ANTHROPIC_BASE_URL#*://}; px_hp=${px_hp%%/*}
    px_port=${px_hp##*:}
    case "$px_port" in *[!0-9]*) px_port="" ;; esac
    ;;
esac
if [ -n "$px_port" ]; then
  px_cache="$tmp/claude-statusline-proxy-$px_port"
  c_ts="" c_state=""
  [ -r "$px_cache" ] && read -r c_ts c_state < "$px_cache"
  case "$c_ts" in ''|*[!0-9]*) c_ts=-999 c_state="" ;; esac
  px_state=$c_state
  age=$((now - c_ts))
  if [ -z "$px_state" ] || [ "$age" -lt 0 ] || [ "$age" -ge 15 ]; then
    if command -v curl >/dev/null 2>&1; then
      res=$(curl -sk --connect-timeout 0.2 -m 0.5 -w '\n%{http_code}' \
        "${ANTHROPIC_BASE_URL%%://*}://$px_hp/readyz" 2>/dev/null)
      case $? in
        0)
          case "${res%$'\n'*}" in
            *headroom*) if [ "${res##*$'\n'}" = 200 ]; then px_state=headroom; else px_state=notready; fi ;;
            *) px_state=proxy ;;
          esac ;;
        # no answer in time: a busy worker, or Headroom checking its upstream. Keep the last answer
        28) [ -n "$px_state" ] || px_state=slow ;;
        *) px_state=down ;;
      esac
    else
      [ -n "$px_state" ] || px_state=unknown
    fi
    printf '%s %s\n' "$now" "$px_state" > "$px_cache" 2>/dev/null
  fi
  case "$px_state" in
    headroom|notready) px_label=headroom ;;
    proxy) ;;
    *) [ "${HEADROOM_PORT:-}" = "$px_port" ] && px_label=headroom ;;   # Headroom sets HEADROOM_PORT
  esac
elif [ -d "$HOME/.headroom" ] || command -v headroom >/dev/null 2>&1; then
  hr_bypassed=1
fi

printf -v cost_full '%d.%02d' $((cents / 100)) $((cents % 100))
cost_short=$(( (cents + 50) / 100 ))
dur_txt=""
[ "$dur" -ge 60 ] && fmt_dur dur_txt "$dur"
ctx_c=""
[ -n "$ctx" ] && pct_color ctx_c "$ctx"

# append one usage window: $1 label, $2 %, $3 seconds to reset, $4 projection, $5 = 1 for the bar,
# $6 = 1 for ↻
window() {
  local c eta
  rl_color c "$2" "$4"
  put "$1 "
  if [ "$5" = 1 ]; then bar "$2" "$c"; put " "; fi
  put "$2%" "$c"
  if [ "$6" = 1 ] && [ -n "$3" ]; then fmt_dur eta "$3"; put " ↻${eta}" "$DIM"; fi
}

# the first line at compactness level $1:
#   0 with bars · 1 full text · 2 no cents, "hr" for "headroom" · 3 no session time · 4 no ↻ ·
#   5 no context size
build() {
  local lvl=$1 bars=0 etas=0 hr=headroom lbl
  [ "$lvl" -lt 1 ] && bars=1
  [ "$lvl" -lt 4 ] && etas=1
  [ "$lvl" -ge 2 ] && hr=hr
  out="" plain=""
  put "$model" "$BOLD"
  if [ -n "$effort" ]; then put " ("; put "$effort" "$effort_c"; put ")"; fi
  [ "$fast" = true ] && put " ⚡fast" "$CYAN"
  if [ -n "$px_port" ]; then
    lbl=$px_label; [ "$lbl" = headroom ] && lbl=$hr
    sep
    if [ "$px_state" = down ]; then put "✗ ${lbl}:${px_port}" "$RED"
    elif [ "$px_state" = notready ]; then put "! ${lbl}:${px_port}" "$YELLOW"
    elif [ "$px_label" = headroom ]; then put "●" "$GREEN"; put " ${lbl}:${px_port}"
    else put "${lbl}:${px_port}" "$DIM"; fi
  elif [ "$hr_bypassed" = 1 ]; then
    sep; put "no ${hr}" "$YELLOW"
  fi
  sep
  if [ "$lvl" -lt 2 ]; then put "≈\$${cost_full}"; else put "≈\$${cost_short}"; fi
  [ -n "$dur_txt" ] && [ "$lvl" -lt 3 ] && put " ${dur_txt}" "$DIM"
  if [ -n "$ctx" ]; then
    sep; put "ctx "
    if [ "$bars" = 1 ]; then bar "$ctx" "$ctx_c"; put " "; fi
    put "${ctx}%" "$ctx_c"
    [ -n "$ctx_max" ] && [ "$lvl" -lt 5 ] && put " of ${ctx_max}" "$DIM"
    [ "$cold" = true ] && put " ❄" "$CYAN"
  elif [ -n "$ctx_max" ]; then
    sep; put "ctx ${ctx_max}"   # before the first answer there is no percentage yet
  fi
  # each window can be missing: Claude Code sends the ones the plan has, and drops one once it resets
  if [ -n "$rl5" ]; then sep; window 5h "$rl5" "$rl5_eta" "$rl5_proj" "$bars" "$etas"; fi
  if [ -n "$rl7" ]; then
    if [ -n "$rl5" ]; then put " · " "$DIM"; else sep; fi
    window 7d "$rl7" "$rl7_eta" "$rl7_proj" "$bars" "$etas"
  fi
}

# the second line at compactness level $1:
#   0 full · 1 session id cut to 8 characters · 2 path shortened from the left, folder by folder
build2() {
  local lvl=$1 p=$path t=$path id=$sid rest="" w
  [ "$lvl" -ge 1 ] && id=${sid:0:8}
  if [ "$lvl" -ge 2 ] && [ -n "$p" ]; then
    # what follows the path, as plain text: only its width matters here
    [ -n "$branch" ] && rest+=" │ ${branch}"
    [ "$dirty" = 1 ] && rest+="*"
    [ -n "$id" ] && rest+=" │ ${id}"
    while width w "${p}${rest}"; [ "$w" -gt "$avail" ]; do
      case "$t" in */?*) t=${t#*/}; p="…/$t" ;; *) break ;; esac
    done
  fi
  out="" plain=""
  # the last folder stands out
  case "$p" in
    "") ;;
    */?*) put "${p%/*}/"; put "${p##*/}" "$CYAN" ;;
    *) put "$p" "$CYAN" ;;
  esac
  if [ -n "$branch" ]; then
    [ -n "$plain" ] && sep
    put "$branch" "$MAGENTA"
    [ "$dirty" = 1 ] && put "*" "$YELLOW"
  fi
  if [ -n "$id" ]; then
    [ -n "$plain" ] && sep
    put "$id" "$DIM"
  fi
}

# Claude Code passes the terminal width in $COLUMNS: compact each line until it fits
cols=${COLUMNS:-0}
case "$cols" in ''|*[!0-9]*) cols=0 ;; esac
avail=$(( cols > 0 ? cols - 5 : 1000000 ))
w=0
for lvl in 1 2 3 4 5; do
  build "$lvl"
  width w "$plain"
  [ "$w" -le "$avail" ] && break
done
# the full text fits: with the room that is left, draw a bar next to each percentage, 4 to 10 cells wide
nbars=0
[ -n "$ctx" ] && nbars=$((nbars + 1))
[ -n "$rl5" ] && nbars=$((nbars + 1))
[ -n "$rl7" ] && nbars=$((nbars + 1))
if [ "$lvl" = 1 ] && [ "$nbars" -gt 0 ]; then
  cells=$(( (avail - w) / nbars - 1 ))
  [ "$cells" -gt 10 ] && cells=10
  [ "$cells" -ge 4 ] && build 0
fi
line=$out
for lvl in 0 1 2; do
  build2 "$lvl"
  width w "$plain"
  [ "$w" -le "$avail" ] && break
done
printf '%s' "$line"
if [ -n "$out" ]; then printf '\n%s' "$out"; fi
