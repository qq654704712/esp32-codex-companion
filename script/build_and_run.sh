#!/usr/bin/env bash
set -euo pipefail

# This is the single development entrypoint used by the Codex Run action.
# It intentionally delegates to the release installer: the dashboard and its
# launch agent must share one signed application bundle and one complete set of
# privacy declarations.  Maintaining a second, ad-hoc .app staging path here
# caused macOS to associate a stale TCC crash with the current Companion.

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAC_DIR="$ROOT_DIR/mac"
APP_BUNDLE="$ROOT_DIR/dist/CodexCompanion.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/CodexCompanion"

install_companion() {
  "$MAC_DIR/scripts/install-companion.sh"
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    install_companion
    open_app
    ;;
  --debug|debug)
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
    swift build --package-path "$MAC_DIR" --product CodexCompanion
    BUILD_DIR="$(swift build --package-path "$MAC_DIR" --show-bin-path)"
    lldb -- "$BUILD_DIR/CodexCompanion"
    ;;
  --logs|logs)
    install_companion
    open_app
    /usr/bin/log stream --info --style compact --predicate 'process == "CodexCompanion"'
    ;;
  --telemetry|telemetry)
    install_companion
    open_app
    /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.codexcompanion.app"'
    ;;
  --verify|verify)
    install_companion
    open_app
    sleep 2
    /usr/bin/pgrep -f 'CodexCompanion\.app/Contents/MacOS/CodexCompanion($| )' >/dev/null
    /usr/sbin/lsof -nP -iTCP:49152 -sTCP:LISTEN | /usr/bin/grep -q '49152 (LISTEN)'
    /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
