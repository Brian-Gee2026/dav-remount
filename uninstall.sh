#!/bin/bash
# Remove the agent and binary. Keeps config and Keychain token unless --purge.
set -euo pipefail
LABEL=dev.dav-remount.agent
BIN="$HOME/.local/bin/dav-remount"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
[[ -x "$BIN" ]] && "$BIN" unmount >/dev/null 2>&1 || true
if [[ "${1:-}" == "--purge" && -x "$BIN" ]]; then "$BIN" forget-token || true; rm -rf "$HOME/.config/dav-remount"; fi
rm -f "$PLIST" "$BIN"
echo "dav-remount removed${1:+ ($1)}"
