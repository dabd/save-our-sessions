#!/usr/bin/env bash
# Backfill: stamp already-running Codex panes with @agent_kind /
# @agent_session_id / @agent_launcher, so sessions started before the
# SessionStart hook was wired (or whose hook is not yet trusted) survive the
# next tmux restart. Safe to re-run; skips panes that are already stamped.
#
# How: a live Codex process keeps its rollout file open. For each pane, walk
# the pane's process tree, find a rollout-<ts>-<uuid>.jsonl open file via
# lsof, and derive id (filename) and launcher (which sessions dir it is
# under: ~/.codex -> codex, ~/.codex-personal -> codex-personal).
set -uo pipefail

command -v tmux >/dev/null 2>&1 || { echo "no tmux" >&2; exit 1; }
command -v lsof >/dev/null 2>&1 || { echo "no lsof" >&2; exit 1; }

# descendants <pid> -> the pid plus all its descendants
descendants() {
  local pid="$1"
  printf '%s\n' "$pid"
  local child
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    descendants "$child"
  done
}

stamped=0 skipped=0
tab=$'\t'
while IFS="$tab" read -r pane_id pane_pid existing; do
  # lsof -p takes a comma-separated pid list. Extract the newest open rollout
  # path across the pane's process tree, if any. Panes without a live Codex
  # keep whatever stamp they have (a dead pane's stamp is what recovery needs).
  rollout="$(lsof -a -p "$(descendants "$pane_pid" | paste -sd, -)" 2>/dev/null \
    | grep -oE '/[^ ]*/sessions/[0-9]{4}/[0-9]{2}/[0-9]{2}/rollout-[^ ]*\.jsonl' \
    | tail -1)"
  [ -n "$rollout" ] || continue

  # The newest open rollout may belong to a SUB-AGENT thread (a session
  # running sub-agents keeps their rollouts open too), and resuming a
  # sub-agent id lands in a read-only viewer. The first line's
  # payload.session_id is the resumable ROOT session in both cases; the
  # filename id is only the fallback.
  sid="$(head -1 "$rollout" 2>/dev/null | python3 -c \
    'import sys,json; print(json.load(sys.stdin)["payload"].get("session_id",""))' 2>/dev/null)"
  if [ -z "$sid" ]; then
    base="$(basename "$rollout" .jsonl)"
    sid="$(printf '%s' "$base" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')"
  fi
  [ -n "$sid" ] || continue

  # Idempotent, and self-healing when a pane was reused for a different
  # session: only the id matters, so re-stamp on mismatch.
  if [ "$sid" = "$existing" ]; then
    skipped=$((skipped+1))
    continue
  fi

  case "$rollout" in
    */.codex-personal/*) launcher="codex-personal" ;;
    *)                   launcher="codex" ;;
  esac

  tmux set -p -t "$pane_id" @agent_kind codex
  tmux set -p -t "$pane_id" @agent_session_id "$sid"
  tmux set -p -t "$pane_id" @agent_launcher "$launcher"

  pos="$(tmux display-message -p -t "$pane_id" \
    '#{session_name}'$'\t''#{window_index}'$'\t''#{pane_index}'$'\t''#{window_name}')"
  cwd="$(tmux display-message -p -t "$pane_id" '#{pane_current_path}')"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  log="${TMUX_AGENT_LOG:-${TMUX_CLAUDE_LOG:-$HOME/.local/share/tmux/claude-sessions.log}}"
  mkdir -p "$(dirname "$log")" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$sid" "$pos" "$cwd" "$launcher" "codex" >> "$log"

  echo "stamped $pane_id ($launcher $sid)"
  stamped=$((stamped+1))
done < <(tmux list-panes -a -F "#{pane_id}${tab}#{pane_pid}${tab}#{?@agent_session_id,#{@agent_session_id},}")

echo "done: $stamped stamped, $skipped already stamped"
