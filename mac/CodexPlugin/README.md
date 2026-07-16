# Codex Companion Hooks

This local Codex plugin forwards `SessionStart`, `UserPromptSubmit`,
`PermissionRequest`, and `Stop` JSON events to `codex-companion hook`.

The plugin intentionally does not install itself. After building the macOS
executable, make `codex-companion` available on `PATH`, or set
`CODEX_COMPANION_BIN` to its absolute path. The repository marketplace at
`.agents/plugins/marketplace.json` exposes this directory as a local plugin.
Restart the Codex desktop app, install **Codex Companion Hooks**, then review
and trust its hook definition with `/hooks`. Until the hook is trusted, Codex
will skip it.

If the executable is absent, the forwarding script consumes the event and
exits successfully so Codex work is never interrupted.
