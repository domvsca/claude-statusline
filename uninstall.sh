#!/usr/bin/env bash
# Removes claude-statusline: unsets statusLine when it points at the script, then deletes the script.
# Uses $CLAUDE_CONFIG_DIR when set, ~/.claude otherwise.
set -eu

config=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
target="$config/statusline.sh"
settings="$config/settings.json"
stamp=$(date +%Y%m%d-%H%M%S)

if [ -f "$settings" ] && command -v jq >/dev/null 2>&1; then
  cur=$(jq -r '.statusLine.command // empty' "$settings")
  if [ "$cur" = 'bash ~/.claude/statusline.sh' ] || [ "$cur" = "bash '$target'" ]; then
    cp -p "$settings" "$settings.bak-$stamp"
    jq 'del(.statusLine)' "$settings" > "$settings.tmp-$$"
    cat "$settings.tmp-$$" > "$settings"
    rm -f "$settings.tmp-$$"
    echo "statusLine removed from settings.json (backup: $settings.bak-$stamp)"
  elif [ -n "$cur" ]; then
    echo "statusLine runs something else ($cur): left as is"
  fi
fi

# delete the script only if it is ours (or a link left dangling by a deleted clone)
if [ -L "$target" ] && [ ! -e "$target" ]; then
  rm -f "$target" && echo "removed $target"
elif [ -e "$target" ] && grep -q 'claude-statusline' "$target" 2>/dev/null; then
  rm -f "$target" && echo "removed $target"
fi

if ls "$settings".bak-* >/dev/null 2>&1; then
  echo "earlier settings are in $settings.bak-* if you want a previous status line back"
fi
