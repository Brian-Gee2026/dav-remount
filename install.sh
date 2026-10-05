#!/bin/bash
# Install dav-remount for the current user:
#   binary  → ~/.local/bin/dav-remount
#   config  → ~/.config/dav-remount/config   (prompts for URL + username if new)
#   token   → login Keychain                 (prompts, no echo)
#   agent   → ~/Library/LaunchAgents/dev.dav-remount.agent.plist
# Usage: ./install.sh [path/to/dav-remount]   (default: ./build/dav-remount, built if missing)
set -euo pipefail
cd "$(dirname "$0")"
LABEL=dev.dav-remount.agent
BIN_SRC="${1:-build/dav-remount}"
BIN="$HOME/.local/bin/dav-remount"
CFG_DIR="$HOME/.config/dav-remount"
CFG="$CFG_DIR/config"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [[ ! -x "$BIN_SRC" ]]; then
  if [[ -f Sources/main.swift ]]; then echo "no binary at $BIN_SRC — building"; ./build.sh; else
    echo "no binary at $BIN_SRC and no source tree — download a release or clone the repo" >&2; exit 1; fi
fi

mkdir -p "$HOME/.local/bin" "$CFG_DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
chmod 700 "$CFG_DIR"
install -m 755 "$BIN_SRC" "$BIN"
echo "installed $BIN ($("$BIN" --version))"

if [[ ! -f "$CFG" ]]; then
  cp config.example "$CFG"; chmod 600 "$CFG"
  if [[ -t 0 ]]; then
    read -rp "WebDAV share URL (https://host/share): " url
    read -rp "Username (as the server expects it, usually your email): " user
    read -rp "Volume name shown in Finder (blank = server default): " vol
    # keep the commented defaults, set the required keys
    sed -i '' -e "s|^url = .*|url = $url|" -e "s|^user = .*|user = $user|" "$CFG"
    [[ -n "$vol" ]] && sed -i '' -e "s|^#volume_name = .*|volume_name = $vol|" "$CFG"
  else
    echo "wrote $CFG from config.example — EDIT url= and user= then re-run" >&2; exit 1
  fi
  echo "wrote $CFG"
else
  echo "config exists: $CFG (left as is)"
fi

if ! "$BIN" has-token; then
  if [[ -t 0 ]]; then
    echo "Mint a personal access token on your identity server's Tokens page (needs the files scope), then paste it:"
    "$BIN" set-token
  else
    echo "no token stored — run: $BIN set-token" >&2
  fi
fi

sed -e "s|__BIN__|$BIN|g" -e "s|__HOME__|$HOME|g" launchd/$LABEL.plist.template > "$PLIST"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "agent loaded: $LABEL"
echo
"$BIN" status
echo
echo "Log: ~/Library/Logs/dav-remount.log   Eject for an hour: dav-remount unmount --pause 60"
