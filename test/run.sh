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
nl=$'\n'
sid=0a1b2c3d-4e5f-6a7b-8c9d-0e1f2a3b4c5d
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
# line2 NAME EXPECTED: the second line of the output, as a whole
line2() { if [ "${txt#*"$nl"}" = "$2" ] && [ "$txt" != "${txt#*"$nl"}" ]; then ok "$1"; else bad "$1 (expected second line: $2)" "$txt"; fi; }
lo=$'\x80' hi=$'\xbf'
width() ( LC_ALL=C; s=$1; c=${s//[!$lo-$hi]/}; echo $(( ${#s} - ${#c} )) )

# payload RATE_LIMITS [EXTRA_FIELDS]
payload() {
  printf '{"session_id":"%s","model":{"display_name":"Opus 5.5"},"effort":{"level":"max"},' "$sid"
  printf '"workspace":{"current_dir":"%s","project_dir":"%s"},' "$repo" "$repo"
  printf '"cost":{"total_cost_usd":12.3456,"total_duration_ms":4320000},'
  printf '"context_window":{"used_percentage":45.6,"context_window_size":1000000},"rate_limits":%s%s}' "$1" "${2:-}"
}
# Payloads live in variables: bash 3.2 brace-expands "{a,b}" written inside "$(... "...")"
d7=$((3 * 86400 + 3 * 3600 + 1800))   # 3d3h30m left
rl_ok="{\"five_hour\":{\"used_percentage\":23.5,\"resets_at\":$((now + 4980))},\"seven_day\":{\"used_percentage\":41.2,\"resets_at\":$((now + d7))}}"
rl_pace="{\"five_hour\":{\"used_percentage\":52,\"resets_at\":$((now + 7200))},\"seven_day\":{\"used_percentage\":41.2,\"resets_at\":$((now + 518400))}}"
rl_frac="{\"five_hour\":{\"used_percentage\":23.5,\"resets_at\":$((now + 4980)).5},\"seven_day\":{\"used_percentage\":41.2,\"resets_at\":$((now + d7)).25}}"
rl_7d="{\"seven_day\":{\"used_percentage\":41.2,\"resets_at\":$((now + d7))}}"
start="{\"model\":{\"display_name\":\"Opus 5.5\"},\"workspace\":{\"current_dir\":\"/\",\"project_dir\":\"/\"},\"cost\":{\"total_cost_usd\":0,\"total_duration_ms\":5000},\"context_window\":{\"used_percentage\":null,\"context_window_size\":200000}}"
deep="{\"session_id\":\"$sid\",\"model\":{\"display_name\":\"Opus 5.5\"},\"workspace\":{\"current_dir\":\"/srv/aaaaaaaaaa/bbbbbbbbbb/cccccccccc/my-app\"}}"
full='{"workspace":{"current_dir":"/"},"context_window":{"used_percentage":100,"context_window_size":200000}}'
low='{"workspace":{"current_dir":"/"},"context_window":{"used_percentage":2,"context_window_size":200000}}'

echo "# first line"
run "$(payload "$rl_ok")"
quiet "full output"
has "model and effort" "Opus 5.5 (max)"
has "cost and session time" "≈\$12.35 1h12m"
has "context: bar, percentage and window size" "ctx ━━━━━───── 46% of 1M"
has "5h with bar and reset" "5h ━━──────── 24% ↻1h2"
has "7d with bar and reset" "7d ━━━━────── 41% ↻3d3h"
hasnt "no proxy segment without Headroom" "headroom"
color "model in bold" "${esc}[1mOpus 5.5${esc}[0m"
color "effort max in bold magenta" "${esc}[1m${esc}[35mmax"
color "bar: filled part in the colour of the percentage, the rest dim" \
  "ctx ${esc}[32m━━━━━${esc}[0m${esc}[2m─────${esc}[0m ${esc}[32m46%"

echo "# second line"
line2 "path, branch with uncommitted changes, session id" "$repo │ main* │ $sid"
color "last folder in cyan" "/${esc}[36mmy-app${esc}[0m"
color "branch in magenta, * in yellow" "${esc}[35mmain${esc}[0m${esc}[33m*"
color "session id in dim" "${esc}[2m$sid"
run "$(payload "$rl_ok")" HOME="$work"
line2 "home folder shown as ~" "~/my-app │ main* │ $sid"
run "$deep" COLUMNS=60
line2 "narrow: short session id" "/srv/aaaaaaaaaa/bbbbbbbbbb/cccccccccc/my-app │ 0a1b2c3d"
run "$deep" COLUMNS=40
line2 "narrower: path shortened from the left" "…/cccccccccc/my-app │ 0a1b2c3d"
quiet "narrower"

echo "# usage projection"
run "$(payload "$rl_pace")"
color "5h 52% three hours in: yellow, bar included" "5h ${esc}[33m━━━━━${esc}[0m${esc}[2m─────${esc}[0m ${esc}[33m52%"
color "7d 41% after one day: red" "${esc}[31m41%"
run "$(payload '{"five_hour":{"used_percentage":65}}')"
color "no reset time: colour by usage" "${esc}[33m65%"

echo "# windows and timestamps"
run "$(payload "$rl_frac")"
quiet "fractional resets_at"
has "fractional resets_at still shown" "24% ↻"
run "$(payload "$rl_7d")"
hasnt "5h window gone" "5h"
has "7d alone" "│ 7d ━━━━────── 41%"

echo "# bars"
run "$full"
has "100%: the bar is full" "ctx ━━━━━━━━━━ 100% of 200k"
color "100% in red" "${esc}[31m100%"
run "$low"
has "2%: the bar is empty" "ctx ────────── 2% of 200k"
quiet "empty bar"

echo "# prompt cache"
run "$(payload "$rl_ok" ',"prompt_cache":{"warm":false,"caching_observed":true}')"
has "expired cache" "❄"
run "$(payload "$rl_ok" ',"prompt_cache":{"warm":true,"caching_observed":true}')"
hasnt "warm cache" "❄"

echo "# start of session and bad input"
run "$start"
quiet "start of session"
has "zero cost" "≈\$0.00"
has "window size before the first answer" "│ ctx 200k"
hasnt "no percentage, no bar" "━"
line2 "no branch, no session id: the path alone" "/"
run 'not json'
quiet "invalid JSON"
has "placeholder model" "?"
run "{\"session_id\":\"$sid\"}"
quiet "no folder in the payload"
hasnt "second line does not start with a separator" "$nl │"
has "session id without a path" "$sid"
txt=$(printf '{}' | env -i HOME="$work/home" PATH="$work/nobin" /bin/bash "$root/statusline.sh" 2>&1)
has "jq missing" "statusline: jq not found"

echo "# proxy segment"
run "$(payload "$rl_ok")" ANTHROPIC_BASE_URL=https://api.anthropic.com
hasnt "remote URL, Headroom not installed: nothing" "headroom"
run "$(payload "$rl_ok")" HOME="$work/home-hr"
has "Headroom installed but bypassed" "│ no headroom │"
color "bypassed in yellow" "${esc}[33mno headroom"
run "$(payload "$rl_ok")" ANTHROPIC_BASE_URL=http://127.0.0.1:9
quiet "closed local port"
has "closed local port" "│ ✗ proxy:9 │"
color "closed port in red" "${esc}[31m✗ proxy:9${esc}[0m"
rm -f "$work"/tmp/claude-statusline-proxy-*
run "$(payload "$rl_ok")" ANTHROPIC_BASE_URL=http://127.0.0.1:9 HEADROOM_PORT=9
has "closed port named by HEADROOM_PORT" "│ ✗ headroom:9 │"
if command -v python3 >/dev/null 2>&1; then
  mkdir -p "$work/www"
  # a tiny HTTP server: GET /name answers with the file www/name, whose first word is the status code
  python3 -u -c '
import http.server, os, sys
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            with open(os.path.join(sys.argv[1], self.path.strip("/"))) as f:
                code, body = f.read().split(" ", 1)
        except (OSError, ValueError):
            code, body = "404", "not found"
        self.send_response(int(code))
        self.end_headers()
        self.wfile.write(body.encode())
    def log_message(self, *args):
        pass
server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
print("port", server.server_address[1], flush=True)
server.serve_forever()
' "$work/www" > "$work/srv.log" 2>&1 &
  srv=$!
  port=""
  for _ in $(seq 1 50); do
    port=$(sed -n 's/.*port \([0-9][0-9]*\).*/\1/p' "$work/srv.log" | head -1)
    [ -n "$port" ] && break
    sleep 0.1
  done
  if [ -n "$port" ]; then
    printf '200 {"service":"headroom-proxy","status":"healthy","ready":true}' > "$work/www/readyz"
    rm -f "$work"/tmp/claude-statusline-proxy-*
    run "$(payload "$rl_ok")" ANTHROPIC_BASE_URL="http://127.0.0.1:$port"
    color "Headroom ready: green dot" "${esc}[32m●${esc}[0m headroom:$port"
    printf '503 {"service":"headroom-proxy","status":"unhealthy","ready":false}' > "$work/www/readyz"
    rm -f "$work"/tmp/claude-statusline-proxy-*
    run "$(payload "$rl_ok")" ANTHROPIC_BASE_URL="http://127.0.0.1:$port"
    color "Headroom not ready: yellow" "${esc}[33m! headroom:$port${esc}[0m"
    rm -f "$work/www/readyz" "$work"/tmp/claude-statusline-proxy-*
    run "$(payload "$rl_ok")" ANTHROPIC_BASE_URL="http://localhost:$port/v1"
    color "another local proxy: dim" "${esc}[2mproxy:$port"
    printf '%s down\n' "$now" > "$work/tmp/claude-statusline-proxy-$port"
    run "$(payload "$rl_ok")" ANTHROPIC_BASE_URL="http://127.0.0.1:$port"
    has "a fresh cached result is reused" "✗ proxy:$port"
  else
    echo "skip  could not start the test HTTP server"
  fi
else
  echo "skip  python3 not found: live proxy checks not tested"
fi

echo "# narrow terminals"
run "$(payload "$rl_ok")" COLUMNS=120 HOME="$work/home-hr"
has "bars take the room that is left" "ctx ━━━──── 46% of 1M"
has "nothing else is dropped for them" "│ no headroom │ ≈\$12.35 1h12m │"
run "$(payload "$rl_ok")" COLUMNS=110 HOME="$work/home-hr"
hasnt "no room for bars of 4 cells: no bars" "━"
has "full text without bars" "│ no headroom │ ≈\$12.35 1h12m │ ctx 46% of 1M │ 5h 24% ↻"
run "$(payload "$rl_ok")" COLUMNS=90 HOME="$work/home-hr"
has "then the cents go, and headroom becomes hr" "│ no hr │ ≈\$12 1h12m │"
has "countdowns are still there" "7d 41% ↻3d3h"
run "$(payload "$rl_ok")" COLUMNS=85 HOME="$work/home-hr"
hasnt "then the session time" "1h12m"
has "countdowns outlive the session time" "7d 41% ↻3d3h"
run "$(payload "$rl_ok")" COLUMNS=70 HOME="$work/home-hr"
hasnt "then the countdowns" "↻"
has "context size still shown" "│ ≈\$12 │ ctx 46% of 1M │ 5h 24% · 7d 41%"
run "$(payload "$rl_ok")" COLUMNS=65 HOME="$work/home-hr"
hasnt "context size goes last" "of 1M"
for c in 200 120 110 100 90 85 80 70; do
  run "$(payload "$rl_ok")" COLUMNS=$c HOME="$work/home-hr"
  fits=1 widths=""
  while IFS= read -r ln; do
    w=$(width "$ln")
    widths="$widths $w"
    [ "$w" -le $((c - 5)) ] || fits=0
  done <<EOF
$txt
EOF
  if [ "$fits" = 1 ]; then ok "COLUMNS=$c fits (columns:$widths)"; else bad "COLUMNS=$c: columns$widths" "$txt"; fi
done

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
