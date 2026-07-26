#!/usr/bin/env bash
# tmux-resurrect post-save-all hook. Snapshots each pane's AI-agent session id by
# position, alongside the resurrect save, so a restored pane can find which
# session it was running. Panes with no session id are dropped.
#
# Agent-neutral. A pane is recorded if it carries either:
#   @agent_session_id  (+ optional @agent_kind, default "claude")  -- preferred
#   @claude_session_id (legacy, set by the Claude SessionStart hook) -- kind "claude"
# @agent_launcher (default "claude") is the wrapper that reattaches the session
# to its config dir, so a session under a non-default CLAUDE_CONFIG_DIR resumes
# with the right command (e.g. claude-personal) instead of a bare `claude`.
#
# Wire it in tmux.conf (resurrect runs the value with eval in a plain shell, so
# point at the script directly, NOT via run-shell):
#   set -g @resurrect-hook-post-save-all '"/path/to/tmux-agent-snapshot.sh"'
set -euo pipefail

out="${TMUX_AGENT_SIDECAR:-${TMUX_CLAUDE_SIDECAR:-$HOME/.local/share/tmux/resurrect/agent-ids.last}}"
mkdir -p "$(dirname "$out")" 2>/dev/null || true

# Codex fires no SessionStart hook on `codex resume`, so a resumed pane would
# stay unstamped (or keep a stale stamp) forever. Backfill from live process
# state before every snapshot; best-effort, never blocks the save.
"$(dirname "$0")/stamp-live-codex-panes.sh" >/dev/null 2>&1 || true

tab=$'\t'
# Columns: session_name, window_index, pane_index, window_name, agent_kind,
#          session_id, agent_launcher
# Prefer @agent_session_id/@agent_kind; fall back to the legacy @claude_session_id.
fmt="#{session_name}${tab}#{window_index}${tab}#{pane_index}${tab}#{window_name}${tab}"
fmt+="#{?@agent_kind,#{@agent_kind},claude}${tab}"
fmt+="#{?@agent_session_id,#{@agent_session_id},#{@claude_session_id}}${tab}"
fmt+="#{?@agent_launcher,#{@agent_launcher},claude}"

# Keep only panes whose resolved session id (field 6) is non-empty.
tmux list-panes -a -F "$fmt" | awk -F'\t' 'NF==7 && $6 != "" { print }' > "$out"

# Window-MRU sidecar: each window's @lf focus stamp by position, so the MRU
# picker order can be restored after a server restart (@lf/@clk are server
# state; tmux-resurrect does not save user options). Windows never focused
# since the hook installed carry no @lf and are dropped.
mru="${TMUX_MRU_SIDECAR:-$HOME/.local/share/tmux/resurrect/window-mru.last}"
tmux list-windows -a -F "#{session_name}${tab}#{window_index}${tab}#{?@lf,#{@lf},}" \
  | awk -F'\t' 'NF==3 && $3 != "" { print }' > "$mru"
