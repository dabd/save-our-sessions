#!/usr/bin/env bash
# Codex SessionStart hook. Records which Codex session id is running in the
# current tmux pane, for recovery after a tmux restart. No-op outside tmux.
# Never fails the session start: always exits 0.
#
# Wire it in <CODEX_HOME>/hooks.json:
#   { "hooks": { "SessionStart": [ { "matcher": "*", "hooks": [
#       { "type": "command", "command": "/path/to/record-codex-session.sh" } ] } ] } }
# Codex requires the hook to be trusted once (it prompts on the next
# interactive start after the entry is added).
set -uo pipefail

input="$(cat)"   # stdin JSON from Codex (same field names as Claude Code)

sid="$(printf '%s' "$input" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("session_id",""))' 2>/dev/null)"
cwd="$(printf '%s' "$input" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("cwd",""))' 2>/dev/null)"

# Launcher: the command that reattaches this session to the right CODEX_HOME.
# Sessions under distinct homes are stored separately, so a bare `codex resume`
# cannot reach a session recorded under a different home. The launcher name is
# the home dir's basename with its leading dot stripped (~/.codex -> codex,
# ~/.codex-personal -> codex-personal), matching the shell wrappers.
home_dir="${CODEX_HOME:-$HOME/.codex}"
launcher="$(basename "$home_dir")"; launcher="${launcher#.}"
[ -n "$launcher" ] || launcher="codex"

# Outside tmux, or no id: nothing to record.
[ -n "${TMUX_PANE:-}" ] || exit 0
[ -n "$sid" ] || exit 0
command -v tmux >/dev/null 2>&1 || exit 0

# Stamp the live pane (server-queryable bindings). The resurrect snapshot
# carries kind/id/launcher into the sidecar.
tmux set -p -t "$TMUX_PANE" @agent_kind codex 2>/dev/null || true
tmux set -p -t "$TMUX_PANE" @agent_session_id "$sid" 2>/dev/null || true
tmux set -p -t "$TMUX_PANE" @agent_launcher "$launcher" 2>/dev/null || true

# Append an immutable positional row (survives a hard crash with no resurrect
# save). Same 8 columns as the Claude recorder plus a trailing agent-kind
# column; rows without it default to `claude` on recovery.
pos="$(tmux display-message -p -t "$TMUX_PANE" \
  '#{session_name}'$'\t''#{window_index}'$'\t''#{pane_index}'$'\t''#{window_name}' 2>/dev/null)"
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
log="${TMUX_AGENT_LOG:-${TMUX_CLAUDE_LOG:-$HOME/.local/share/tmux/claude-sessions.log}}"
mkdir -p "$(dirname "$log")" 2>/dev/null || true
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$sid" "$pos" "$cwd" "$launcher" "codex" >> "$log"

exit 0
