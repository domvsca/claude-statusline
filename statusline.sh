#!/usr/bin/env bash
# claude-statusline: a compact, zero-config status line for Claude Code
# https://github.com/domvsca/claude-statusline · MIT License
#
#   Opus 5.5 (max) | headroom:8787 | my-app | main* | ≈$12.35 1h12m | ctx 46% ❄ | 5h 24% ↻1h22m · 7d 41% ↻3d2h
#
#   Opus 5.5 (max)  model and effort level; ⚡fast when fast mode is on
#   headroom:8787   API calls go through the local proxy on that port (from ANTHROPIC_BASE_URL):
#                   green = Headroom answers · red ✗ = nothing answers, so the calls fail ·
#                   dim "proxy:PORT" = a local proxy that is not Headroom ·
#                   yellow "no headroom" = Headroom is installed but this session bypasses it
#   my-app | main*  project and git branch (* = uncommitted changes)
#   ≈$12.35 1h12m   estimated session cost at API list prices, and session time
#   ctx 46%         context window used: green <60%, yellow 60-79%, red 80%+
#   ❄               the prompt cache has expired: the next message re-sends the context at full price
#   5h / 7d         subscription usage windows with time to reset (↻). The colour is the usage
#                   projected to the end of the window at the current pace: green <85%,
#                   yellow 85-99%, red 100%+ (you would run out before the reset)
#
# Narrow terminal ($COLUMNS): drops ↻, then cents ("headroom" becomes "hr"), then the project
# name when a branch is shown, then the session time.
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
shopt -s extglob
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
      cwd:     (.workspace.current_dir // .cwd // "."),
      project: (.workspace.repo.name // ((.workspace.project_dir // "") | split("/") | last) // ""),
      cents:   ((.cost.total_cost_usd // 0) * 100 | round),
      dur:     ((.cost.total_duration_ms // 0) / 1000 | floor),
      ctx:     (.context_window.used_percentage | if . == null then "" else round end),
      cold:    ((.prompt_cache.caching_observed == true) and (.prompt_cache.warm == false)),
      rl5: $h5.u, rl5_eta: $h5.eta, rl5_proj: $h5.proj,
      rl7: $d7.u, rl7_eta: $d7.eta, rl7_proj: $d7.proj,
      now: (now | floor) }
  | to_entries[] | "\(.key)=\(.value | tostring | @sh)"
' 2>/dev/null)"
: "${model:=?}" "${cwd:=.}" "${cents:=0}" "${dur:=0}" "${now:=0}"

ESC=$'\033'
RESET="${ESC}[0m"; DIM="${ESC}[2m"; BOLD="${ESC}[1m"
RED="${ESC}[31m"; GREEN="${ESC}[32m"; YELLOW="${ESC}[33m"
MAGENTA="${ESC}[35m"; CYAN="${ESC}[36m"

# % used (context, or a usage window without a reset time): green <60, yellow 60-79, red 80+
pct_color() {
  if [ "$1" -ge 80 ]; then printf '%s' "$RED"
  elif [ "$1" -ge 60 ]; then printf '%s' "$YELLOW"
  else printf '%s' "$GREEN"; fi
}

# usage window: $1 = % used, $2 = % projected at the end of the window
rl_color() {
  if [ -z "$2" ]; then pct_color "$1"
  elif [ "$2" -ge 100 ]; then printf '%s' "$RED"
  elif [ "$2" -ge 85 ]; then printf '%s' "$YELLOW"
  else printf '%s' "$GREEN"; fi
}

# seconds -> 3d4h | 1h05m | 42m, written into the variable named $1
fmt_dur() {
  local s=$2
  if [ "$s" -ge 86400 ]; then
    if [ $((s % 86400 / 3600)) -gt 0 ]; then printf -v "$1" '%dd%dh' $((s / 86400)) $((s % 86400 / 3600))
    else printf -v "$1" '%dd' $((s / 86400)); fi
  elif [ "$s" -ge 3600 ]; then printf -v "$1" '%dh%02dm' $((s / 3600)) $((s % 3600 / 60))
  else printf -v "$1" '%dm' $((s / 60)); fi
}

# visible width in $2: drop colour codes, then count code points (UTF-8 continuation bytes don't count)
lo=$'\x80' hi=$'\xbf'
vis_width() {
  local s=${1//$'\033['*([0-9;])m/}
  local c=${s//[!$lo-$hi]/}
  printf -v "$2" '%d' $(( ${#s} - ${#c} ))
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
branch_txt=$branch
[ "$dirty" = 1 ] && branch_txt="${branch}${YELLOW}*${RESET}"

# Proxy. The script inherits the environment of the claude process, so ANTHROPIC_BASE_URL is
# where this session sends its API calls. A local URL is probed on /livez (Headroom's liveness
# endpoint) at most every 15 s per port; the result is shared by all sessions.
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
        "${ANTHROPIC_BASE_URL%%://*}://$px_hp/livez" 2>/dev/null)
      case $? in
        0)
          case "${res%$'\n'*}" in
            *headroom*) if [ "${res##*$'\n'}" = 200 ]; then px_state=headroom; else px_state=down; fi ;;
            *) px_state=proxy ;;
          esac ;;
        28) [ -n "$px_state" ] || px_state=slow ;;   # slow but reachable, e.g. a single busy worker
        *) px_state=down ;;
      esac
    else
      [ -n "$px_state" ] || px_state=unknown
    fi
    printf '%s %s\n' "$now" "$px_state" > "$px_cache" 2>/dev/null
  fi
  case "$px_state" in
    headroom) px_label=headroom ;;
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

# one usage window: $1 label, $2 %, $3 seconds to reset, $4 projection, $5 = 1 to show ↻
rl_seg() {
  local s eta
  s="$1 $(rl_color "$2" "$4")$2%${RESET}"
  if [ "$5" = 1 ] && [ -n "$3" ]; then fmt_dur eta "$3"; s+="${DIM} ↻${eta}${RESET}"; fi
  printf '%s' "$s"
}

# the whole line at compactness level $1:
#   0 full · 1 no ↻ · 2 no cents, "hr" for "headroom" · 3 no project (when a branch is shown) · 4 no time
build() {
  local lvl=$1 sep=" ${DIM}|${RESET} " l rl="" show_eta=0 hr=headroom lbl
  [ "$lvl" -lt 1 ] && show_eta=1
  [ "$lvl" -ge 2 ] && hr=hr
  l=$model
  [ -n "$effort" ] && l+=" (${effort_c}${effort}${RESET})"
  [ "$fast" = true ] && l+=" ${CYAN}⚡fast${RESET}"
  if [ -n "$px_port" ]; then
    lbl=$px_label; [ "$lbl" = headroom ] && lbl=$hr
    if [ "$px_state" = down ]; then l+="${sep}${RED}${lbl}:${px_port} ✗${RESET}"
    elif [ "$px_label" = headroom ]; then l+="${sep}${GREEN}${lbl}:${px_port}${RESET}"
    else l+="${sep}${DIM}${lbl}:${px_port}${RESET}"; fi
  elif [ "$hr_bypassed" = 1 ]; then
    l+="${sep}${YELLOW}no ${hr}${RESET}"
  fi
  if [ -n "$project" ] && { [ "$lvl" -lt 3 ] || [ -z "$branch" ]; }; then l+="${sep}${project}"; fi
  [ -n "$branch" ] && l+="${sep}${branch_txt}"
  if [ "$lvl" -lt 2 ]; then l+="${sep}≈\$${cost_full}"; else l+="${sep}≈\$${cost_short}"; fi
  [ -n "$dur_txt" ] && [ "$lvl" -lt 4 ] && l+=" ${dur_txt}"
  if [ -n "$ctx" ]; then
    l+="${sep}ctx $(pct_color "$ctx")${ctx}%${RESET}"
    [ "$cold" = true ] && l+=" ${CYAN}❄${RESET}"
  fi
  # 5h and 7d can each be missing: Claude Code drops a window once it resets
  [ -n "$rl5" ] && rl=$(rl_seg 5h "$rl5" "$rl5_eta" "$rl5_proj" "$show_eta")
  if [ -n "$rl7" ]; then
    [ -n "$rl" ] && rl+=" ${DIM}·${RESET} "
    rl+=$(rl_seg 7d "$rl7" "$rl7_eta" "$rl7_proj" "$show_eta")
  fi
  [ -n "$rl" ] && l+="${sep}${rl}"
  printf '%s' "$l"
}

# Claude Code passes the terminal width in $COLUMNS: compact the line until it fits
cols=${COLUMNS:-0}
case "$cols" in ''|*[!0-9]*) cols=0 ;; esac
avail=$(( cols > 0 ? cols - 5 : 1000000 ))
for lvl in 0 1 2 3 4; do
  line=$(build "$lvl")
  vis_width "$line" w
  [ "$w" -le "$avail" ] && break
done
printf '%s' "$line"
