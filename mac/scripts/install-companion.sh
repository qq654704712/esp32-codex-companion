#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
MAC_DIR=${SCRIPT_DIR:h}
INSTALL_DIR="$HOME/Library/Application Support/CodexCompanion/bin"
INSTALL_BIN="$INSTALL_DIR/codex-companion"
# Keep the launch agent inside the original, developer-signed application
# bundle. TCC binds Accessibility consent to this bundle identifier/team; a
# freshly-created ad-hoc copy under ~/Applications would be a different
# identity even with the same display name.
APP_DIR="$MAC_DIR/../dist/CodexCompanion.app"
APP_CONTENTS="$APP_DIR/Contents"
APP_BIN="$APP_CONTENTS/MacOS/CodexCompanion"
APP_INFO="$APP_CONTENTS/Info.plist"
PLIST="$HOME/Library/LaunchAgents/com.codexcompanion.daemon.plist"

export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
swift build --package-path "$MAC_DIR" -c release --product codex-companion
swift build --package-path "$MAC_DIR" -c release --product CodexCompanion
BUILD_DIR=$(swift build --package-path "$MAC_DIR" -c release --show-bin-path)

# Never replace or re-sign an application bundle while its UI is still mapped
# into a running process.  That leaves a stale executable sharing the same
# bundle identity as the freshly installed daemon and can surface as an
# unrelated “unexpectedly quit” dialog.  The background agent is stopped
# first, then any visible Companion instance is given a short, clean exit.
launchctl bootout "gui/$(id -u)/com.codexcompanion.daemon" >/dev/null 2>&1 || true
RUNNING_PIDS=(${(f)$(/usr/bin/pgrep -f 'CodexCompanion\.app/Contents/MacOS/CodexCompanion($| )' 2>/dev/null || true)})
for pid in "${RUNNING_PIDS[@]}"; do
  kill -TERM "$pid" >/dev/null 2>&1 || true
done
if (( ${#RUNNING_PIDS[@]} > 0 )); then
  for _ in {1..20}; do
    /usr/bin/pgrep -f 'CodexCompanion\.app/Contents/MacOS/CodexCompanion($| )' >/dev/null 2>&1 || break
    sleep 0.1
  done
fi

mkdir -p "$INSTALL_DIR" "$HOME/Library/LaunchAgents" "$APP_CONTENTS/MacOS"
cp "$BUILD_DIR/codex-companion" "$INSTALL_BIN"
chmod 700 "$INSTALL_BIN"
cp "$BUILD_DIR/CodexCompanion" "$APP_BIN"
chmod 700 "$APP_BIN"
rm -f "$APP_INFO"
/usr/bin/plutil -create xml1 "$APP_INFO"
/usr/bin/plutil -insert CFBundleName -string "Codex Companion" "$APP_INFO"
/usr/bin/plutil -insert CFBundleDisplayName -string "Codex Companion" "$APP_INFO"
/usr/bin/plutil -insert CFBundleIdentifier -string "com.codexcompanion.app" "$APP_INFO"
/usr/bin/plutil -insert CFBundleExecutable -string "CodexCompanion" "$APP_INFO"
/usr/bin/plutil -insert CFBundlePackageType -string "APPL" "$APP_INFO"
# The first shipped 0.2.0 (2) build was terminated by TCC before the Bluetooth
# usage description existed.  Publish the repaired build as a new version so
# macOS does not continue associating that historical crash notification with
# the currently running binary.
/usr/bin/plutil -insert CFBundleShortVersionString -string "0.2.1" "$APP_INFO"
/usr/bin/plutil -insert CFBundleVersion -string "3" "$APP_INFO"
/usr/bin/plutil -insert LSMinimumSystemVersion -string "14.0" "$APP_INFO"
/usr/bin/plutil -insert NSBluetoothAlwaysUsageDescription -string "Codex Companion uses Bluetooth to connect to your ESP32 companion device." "$APP_INFO"
/usr/bin/plutil -insert NSMicrophoneUsageDescription -string "Codex Companion receives wireless audio through its Codex Mic input device." "$APP_INFO"
/usr/bin/plutil -insert NSLocalNetworkUsageDescription -string "Codex Companion discovers your paired ESP32 companion on the local network." "$APP_INFO"
/usr/bin/plutil -insert NSBonjourServices -json '["_codex-companion._tcp"]' "$APP_INFO"
SIGNING_IDENTITY=$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/awk -F '"' '/Apple Development:/ {print $2; exit}')
if [[ -n "$SIGNING_IDENTITY" ]]; then
  /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" "$APP_DIR" >/dev/null
else
  /usr/bin/codesign --force --sign - "$APP_DIR" >/dev/null
fi

rm -f "$PLIST"
/usr/bin/plutil -create xml1 "$PLIST"
/usr/bin/plutil -insert Label -string com.codexcompanion.daemon "$PLIST"
/usr/bin/plutil -insert ProgramArguments -json "[\"$APP_BIN\",\"--daemon\"]" "$PLIST"
/usr/bin/plutil -insert RunAtLoad -bool true "$PLIST"
/usr/bin/plutil -insert KeepAlive -bool true "$PLIST"
/usr/bin/plutil -insert ProcessType -string Interactive "$PLIST"
# macOS Local Network Privacy does not automatically attribute a user
# LaunchAgent to its containing app. Associate this agent with the signed UI
# bundle so Bonjour permission is requested, displayed, and persisted under
# “Codex Companion” rather than being silently policy-denied.
/usr/bin/plutil -insert AssociatedBundleIdentifiers -json '["com.codexcompanion.app"]' "$PLIST"
/usr/bin/plutil -insert StandardOutPath -string "$HOME/Library/Logs/CodexCompanion.log" "$PLIST"
/usr/bin/plutil -insert StandardErrorPath -string "$HOME/Library/Logs/CodexCompanion.log" "$PLIST"
launchctl bootstrap "gui/$(id -u)" "$PLIST"
print "Installed $APP_DIR and started com.codexcompanion.daemon"
