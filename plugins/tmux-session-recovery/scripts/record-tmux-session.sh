#!/usr/bin/env bash
# Claude Code SessionStart hook. Records which Claude session id is running in
# the current tmux pane, for recovery after a tmux restart. No-op outside tmux.
# Never fails the session start: always exits 0.
set -uo pipefail

input="$(cat)"   # stdin JSON from Claude Code

# Session id is the documented stdin field; cwd stored verbatim (do not slug it:
# Claude replaces both '/' and '.' with '-' in its projects dir names).
sid="$(printf '%s' "$input" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("session_id",""))' 2>/dev/null)"
cwd="$(printf '%s' "$input" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("cwd",""))' 2>/dev/null)"

# Launcher: the command that reattaches this session to the right config dir.
# Sessions under distinct CLAUDE_CONFIG_DIRs are stored separately, so a bare
# `claude --resume` cannot reach a session recorded under a different dir. The
# launcher name is the config dir's basename with its leading dot stripped
# (~/.claude -> claude, ~/.claude-personal -> claude-personal), which matches
# the shell wrappers that pin each dir. CLAUDE_CONFIG_DIR is in the hook's env.
cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
launcher="$(basename "$cfg")"; launcher="${launcher#.}"
[ -n "$launcher" ] || launcher="claude"

# Third-party backend wrappers (e.g. claude-kimi) share a config dir with the
# plain profile but set ANTHROPIC_BASE_URL to a non-Anthropic host. Resuming
# under the plain launcher would silently reopen the session on the Anthropic
# backend, so derive the launcher from the host's second-level label instead:
# claude-<label>, matching the wrapper naming convention.
if [ -n "${ANTHROPIC_BASE_URL:-}" ] &&
   ! printf '%s' "$ANTHROPIC_BASE_URL" | grep -q 'api\.anthropic\.com'; then
  label="$(printf '%s' "$ANTHROPIC_BASE_URL" |
           sed -E 's#^https?://(api\.)?([^./]+).*#\2#')"
  [ -n "$label" ] && launcher="claude-$label"
fi

# Outside tmux, or no id: nothing to record.
[ -n "${TMUX_PANE:-}" ] || exit 0
[ -n "$sid" ] || exit 0
command -v tmux >/dev/null 2>&1 || exit 0

# Stamp the live pane (server-queryable bindings). @agent_launcher lets the
# resurrect snapshot carry the launcher into the sidecar.
tmux set -p -t "$TMUX_PANE" @claude_session_id "$sid" 2>/dev/null || true
tmux set -p -t "$TMUX_PANE" @agent_launcher "$launcher" 2>/dev/null || true

# Append an immutable positional row (survives a hard crash with no resurrect
# save). Launcher is the trailing column; older rows without it default to
# `claude` on recovery.
pos="$(tmux display-message -p -t "$TMUX_PANE" \
  '#{session_name}'$'\t''#{window_index}'$'\t''#{pane_index}'$'\t''#{window_name}' 2>/dev/null)"
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
log="${TMUX_CLAUDE_LOG:-$HOME/.local/share/tmux/claude-sessions.log}"
mkdir -p "$(dirname "$log")" 2>/dev/null || true
printf '%s\t%s\t%s\t%s\t%s\n' "$ts" "$sid" "$pos" "$cwd" "$launcher" >> "$log"

exit 0
