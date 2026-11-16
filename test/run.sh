#!/usr/bin/env bash
# Tests for statusline.sh. Run: bash test/run.sh
# Each case feeds a JSON payload to the script in a clean environment and checks the output.
set -u
cd "$(dirname "$0")/.." || exit 1
root=$PWD
pass=0 fail=0
work=$(mktemp -d)
srv=""
cleanup() { if [ -n "$srv" ]; then kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null; fi; rm -rf "$work"; }
trap cleanup EXIT

base_path="$(dirname "$(command -v jq)"):/usr/bin:/bin"
now=$(date +%s)
esc=$'\033'
mkdir -p "$work/tmp" "$work/home" "$work/home-hr/.headroom" "$work/nobin"

# a git repository on branch main with an uncommitted file
repo="$work/my-app"
git init -q "$repo" 2>/dev/null && git -C "$repo" symbolic-ref HEAD refs/heads/main && touch "$repo/new-file"

# run JSON [VAR=value ...]: sets $out (raw), $txt (no colours), $err (stderr)
run() {
  local json=$1; shift
  out=$(printf '%s' "$json" | env -i HOME="$work/home" PATH="$base_path" TMPDIR="$work/tmp" "$@" \
        /bin/bash "$root/statusline.sh" 2>"$work/stderr")
  txt=$(printf '%s' "$out" | sed "s/${esc}\[[0-9;]*m//g")
  err=$(cat "$work/stderr")
}
ok()    { pass=$((pass + 1)); printf 'ok    %s\n' "$1"; }
bad()   { fail=$((fail + 1)); printf 'FAIL  %s\n      got: %s\n' "$1" "$2"; }
has()   { case "$txt" in *"$2"*) ok "$1" ;; *) bad "$1 (expected: $2)" "$txt" ;; esac; }
hasnt() { case "$txt" in *"$2"*) bad "$1 (unexpected: $2)" "$txt" ;; *) ok "$1" ;; esac; }
color() { case "$out" in *"$2"*) ok "$1" ;; *) bad "$1" "$(printf '%s' "$out" | cat -v)" ;; esac; }
quiet() { if [ -z "$err" ]; then ok "$1: nothing on stderr"; else bad "$1: stderr" "$err"; fi; }
lo=$'\x80' hi=$'\xbf'
width() ( LC_ALL=C; s=$1; c=${s//[!$lo-$hi]/}; echo $(( ${#s} - ${#c} )) )

# payload RATE_LIMITS [EXTRA_FIELDS]
payload() {
  printf '{"model":{"display_name":"Opus 5.5"},"effort":{"level":"max"},'
  printf '"workspace":{"current_dir":"%s","project_dir":"%s"},' "$repo" "$repo"
  printf '"cost":{"total_cost_usd":12.3456,"total_duration_ms":4320000},'
  printf '"context_window":{"used_percentage":45.6},"rate_limits":%s%s}' "$1" "${2:-}"
}
# Payloads live in variables: bash 3.2 brace-expands "{a,b}" written inside "$(... "...")"
d7=$((3 * 86400 + 3 * 3600 + 1800))   # 3d3h30m left
rl_ok="{\"five_hour\":{\"used_percentage\":23.5,\"resets_at\":$((now + 4980))},\"seven_day\":{\"used_percentage\":41.2,\"resets_at\":$((now + d7))}}"
rl_pace="{\"five_hour\":{\"used_percentage\":52,\"resets_at\":$((now + 7200))},\"seven_day\":{\"used_percentage\":41.2,\"resets_at\":$((now + 518400))}}"
rl_frac="{\"five_hour\":{\"used_percentage\":23.5,\"resets_at\":$((now + 4980)).5},\"seven_day\":{\"used_percentage\":41.2,\"resets_at\":$((now + d7)).25}}"
rl_7d="{\"seven_day\":{\"used_percentage\":41.2,\"resets_at\":$((now + d7))}}"

echo "# full line"
run "$(payload "$rl_ok")"
quiet "full line"
has "model and effort" "Opus 5.5 (max)"
has "project" "| my-app |"
has "branch with uncommitted changes" "| main* |"
has "cost and session time" "≈\$12.35 1h12m"
has "context" "ctx 46%"
has "5h with reset" "5h 24% ↻1h2"
has "7d with reset" "7d 41% ↻3d3h"
hasnt "no proxy segment without Headroom" "headroom"
color "effort max in bold magenta" "${esc}[1m${esc}[35mmax"

echo "# usage projection"
run "$(payload "$rl_pace")"
color "5h 52% three hours in: yellow" "5h ${esc}[33m52%"
color "7d 41% after one day: red" "7d ${esc}[31m41%"
run "$(payload '{"five_hour":{"used_percentage":65}}')"
color "no reset time: colour by usage" "5h ${esc}[33m65%"

echo "# windows and timestamps"
run "$(payload "$rl_frac")"
quiet "fractional resets_at"
has "fractional resets_at still shown" "5h 24% ↻"
run "$(payload "$rl_7d")"
hasnt "5h window gone" "5h"
has "7d alone" "| 7d 41%"

echo "# prompt cache"
run "$(payload "$rl_ok" ',"prompt_cache":{"warm":false,"caching_observed":true}')"
has "expired cache" "❄"
run "$(payload "$rl_ok" ',"prompt_cache":{"warm":true,"caching_observed":true}')"
hasnt "warm cache" "❄"

echo "# start of session and bad input"
run '{"model":{"display_name":"Opus 5.5"},"workspace":{"current_dir":"/","project_dir":"/"},"cost":{"total_cost_usd":0,"total_duration_ms":5000},"context_window":{"used_percentage":null}}'
quiet "start of session"
has "zero cost" "≈\$0.00"
run 'not json'
quiet "invalid JSON"
has "placeholder model" "?"
txt=$(printf '{}' | env -i HOME="$work/home" PATH="$work/nobin" /bin/bash "$root/statusline.sh" 2>&1)
has "jq missing" "statusline: jq not found"

echo "# proxy segment"
run "$(payload "$rl_ok")" ANTHROPIC_BASE_URL=https://api.anthropic.com
hasnt "remote URL, Headroom not installed: nothing" "headroom"
run "$(payload "$rl_ok")" HOME="$work/home-hr"
has "Headroom installed but bypassed" "| no headroom |"
color "bypassed in yellow" "${esc}[33mno headroom"
run "$(payload "$rl_ok")" ANTHROPIC_BASE_URL=http://127.0.0.1:9
quiet "closed local port"
has "closed local port" "| proxy:9 ✗ |"
color "closed port in red" "${esc}[31mproxy:9 ✗"
rm -f "$work"/tmp/claude-statusline-proxy-*
run "$(payload "$rl_ok")" ANTHROPIC_BASE_URL=http://127.0.0.1:9 HEADROOM_PORT=9
has "closed port named by HEADROOM_PORT" "| headroom:9 ✗ |"
if command -v python3 >/dev/null 2>&1; then
  mkdir -p "$work/www"
  printf '{"service":"headroom-proxy","status":"healthy"}' > "$work/www/livez"
  python3 -u -m http.server 0 --bind 127.0.0.1 --directory "$work/www" > "$work/srv.log" 2>&1 &
  srv=$!
  port=""
  for _ in $(seq 1 50); do
    port=$(sed -n 's/.*port \([0-9][0-9]*\).*/\1/p' "$work/srv.log" | head -1)
    [ -n "$port" ] && break
    sleep 0.1
  done
  if [ -n "$port" ]; then
    rm -f "$work"/tmp/claude-statusline-proxy-*
    run "$(payload "$rl_ok")" ANTHROPIC_BASE_URL="http://127.0.0.1:$port"
    color "Headroom answering: green" "${esc}[32mheadroom:$port"
    rm -f "$work/www/livez" "$work"/tmp/claude-statusline-proxy-*
    run "$(payload "$rl_ok")" ANTHROPIC_BASE_URL="http://localhost:$port/v1"
    color "another local proxy: dim" "${esc}[2mproxy:$port"
    printf '%s down\n' "$now" > "$work/tmp/claude-statusline-proxy-$port"
    run "$(payload "$rl_ok")" ANTHROPIC_BASE_URL="http://127.0.0.1:$port"
    has "a fresh cached result is reused" "proxy:$port ✗"
  else
    echo "skip  could not start the test HTTP server"
  fi
else
  echo "skip  python3 not found: live proxy checks not tested"
fi

echo "# narrow terminals"
run "$(payload "$rl_ok")" COLUMNS=70 HOME="$work/home-hr"
has "compact cost" "≈\$12 "
has "short Headroom label" "| no hr |"
hasnt "no countdowns" "↻"
for c in 200 120 100 90 80 70; do
  run "$(payload "$rl_ok")" COLUMNS=$c HOME="$work/home-hr"
  w=$(width "$txt")
  if [ "$w" -le $((c - 5)) ]; then ok "COLUMNS=$c fits ($w columns)"; else bad "COLUMNS=$c is $w columns" "$txt"; fi
done

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
