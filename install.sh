#!/usr/bin/env bash
# Installs claude-statusline for Claude Code. Safe to run again.
#   ./install.sh          links statusline.sh from this folder: update later with `git pull`
#   ./install.sh --copy   copies it instead, so this folder can be deleted
# Uses $CLAUDE_CONFIG_DIR when set, ~/.claude otherwise.
set -eu

repo=$(cd "$(dirname "$0")" && pwd)
config=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
target="$config/statusline.sh"
settings="$config/settings.json"
stamp=$(date +%Y%m%d-%H%M%S)

mode=link
case "${1:-}" in
  --copy) mode=copy ;;
  "") ;;
  *) echo "usage: $0 [--copy]" >&2; exit 2 ;;
esac

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required: brew install jq (macOS) or sudo apt install jq (Debian/Ubuntu)" >&2
  exit 1
fi
command -v git >/dev/null 2>&1 || echo "note: git not found, the branch will not be shown"
command -v curl >/dev/null 2>&1 || echo "note: curl not found, local proxies will not be checked"

mkdir -p "$config"
[ -s "$settings" ] || echo '{}' > "$settings"
if ! jq -e 'type == "object"' "$settings" >/dev/null 2>&1; then
  echo "$settings is not a JSON object: fix it and run again" >&2
  exit 1
fi

# 1. The script. Anything else already at that path is kept as a backup.
if [ -L "$target" ] && [ "$(readlink "$target")" = "$repo/statusline.sh" ]; then
  [ "$mode" = copy ] && rm -f "$target"
elif [ -f "$target" ] && cmp -s "$target" "$repo/statusline.sh"; then
  rm -f "$target"
elif [ -e "$target" ] || [ -L "$target" ]; then
  mv "$target" "$target.bak-$stamp"
  echo "kept the previous $target as $target.bak-$stamp"
fi
chmod +x "$repo/statusline.sh"
if [ "$mode" = copy ]; then
  cp "$repo/statusline.sh" "$target"
else
  ln -sfn "$repo/statusline.sh" "$target"
fi
echo "status line script: $target ($mode)"

# 2. settings.json: point statusLine at the script and leave everything else alone
if [ "$config" = "$HOME/.claude" ]; then
  cmd='bash ~/.claude/statusline.sh'
else
  cmd="bash '$target'"
fi
old=$(jq -r '.statusLine.command // empty' "$settings")
if [ "$old" = "$cmd" ]; then
  echo "settings.json already uses it"
else
  cp -p "$settings" "$settings.bak-$stamp"
  jq --arg cmd "$cmd" '.statusLine = ((.statusLine // {}) + {type: "command", command: $cmd})' \
    "$settings" > "$settings.tmp-$$"
  cat "$settings.tmp-$$" > "$settings"
  rm -f "$settings.tmp-$$"
  echo "settings.json updated (backup: $settings.bak-$stamp)"
  if [ -n "$old" ]; then echo "the previous status line command was: $old"; fi
fi
echo "done: Claude Code shows the new status line right away"
