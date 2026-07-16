#!/bin/zsh
set -euo pipefail

PLIST="$HOME/Library/LaunchAgents/com.codexcompanion.daemon.plist"
launchctl bootout "gui/$(id -u)/com.codexcompanion.daemon" >/dev/null 2>&1 || true
rm -f "$PLIST"
rm -rf "$HOME/Library/Application Support/CodexCompanion/bin"
print "Removed Codex Companion daemon. Voice profiles and Keychain pairing key were preserved."
