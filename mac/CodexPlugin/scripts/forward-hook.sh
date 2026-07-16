#!/bin/sh
set -eu

if [ -n "${CODEX_COMPANION_BIN:-}" ] && [ -x "$CODEX_COMPANION_BIN" ]; then
    exec "$CODEX_COMPANION_BIN" hook
fi

if command -v codex-companion >/dev/null 2>&1; then
    exec codex-companion hook
fi

USER_BIN="$HOME/Library/Application Support/CodexCompanion/bin/codex-companion"
if [ -x "$USER_BIN" ]; then
    exec "$USER_BIN" hook
fi

# Hooks must never block or break a Codex task when Companion is not installed.
cat >/dev/null
exit 0
