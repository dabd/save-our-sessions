#!/usr/bin/env bash
# After a tmux restart, map each restored pane to the AI-agent session id it was
# running, by position. Reads the resurrect sidecar first, then falls back to
# the newest matching row in the persistent log. Prints, per pane, the resume
# command to run (`claude --resume <id>` or `codex resume <id>`). Agent-neutral.
# Does not auto-run anything.
set -euo pipefail

sidecar="${TMUX_AGENT_SIDECAR:-${TMUX_CLAUDE_SIDECAR:-$HOME/.local/share/tmux/resurrect/agent-ids.last}}"
log="${TMUX_AGENT_LOG:-${TMUX_CLAUDE_LOG:-$HOME/.local/share/tmux/claude-sessions.log}}"

# resume_cmd <agent_kind> <id> <launcher> -> the command string to relaunch that
# session. The launcher is the wrapper that pins the right config dir (e.g.
# claude-personal); kind selects the resume syntax (claude uses --resume, codex
# a `resume` subcommand). A codex pane that only carries the generic "claude"
# launcher default is remapped to "codex".
resume_cmd() {
  local kind="$1" id="$2" launcher="${3:-}"
  case "$kind" in
    codex)
      [ -n "$launcher" ] && [ "$launcher" != claude ] || launcher=codex
      printf '%s resume %s' "$launcher" "$id" ;;
    *)
      [ -n "$launcher" ] || launcher=claude
      printf '%s --resume %s' "$launcher" "$id" ;;
  esac
}

# lookup <session> <window> <pane> -> "<agent_kind>\t<id>\t<launcher>" or empty.
# Sidecar is the 7-column agent format (kind $5, id $6, launcher $7). The
# persistent log is Claude-only by construction (kind "claude"), launcher in $8;
# rows predating the launcher column default to "claude".
lookup() {
  local s="$1" w="$2" p="$3" hit=""
  if [ -f "$sidecar" ]; then
    hit="$(awk -F'\t' -v s="$s" -v w="$w" -v p="$p" \
      '$1==s && $2==w && $3==p { print $5 "\t" $6 "\t" ($7==""?"claude":$7); exit }' "$sidecar")"
  fi
  if [ -z "$hit" ] && [ -f "$log" ]; then
    hit="$(awk -F'\t' -v s="$s" -v w="$w" -v p="$p" \
      '$3==s && $4==w && $5==p { id=$2; lchr=($8==""?"claude":$8) }
       END { if (id != "") printf "claude\t%s\t%s", id, lchr }' "$log")"
  fi
  printf '%s' "$hit"
}

tab=$'\t'
fmt="#{session_name}${tab}#{window_index}${tab}#{pane_index}${tab}#{window_name}"

tmux list-panes -a -F "$fmt" \
| while IFS=$'\t' read -r s w p name; do
    hit="$(lookup "$s" "$w" "$p")"
    if [ -n "$hit" ]; then
      IFS=$'\t' read -r kind id launcher <<<"$hit"
      printf '%s:%s.%s (%s) -> %s\n' "$s" "$w" "$p" "$name" "$(resume_cmd "$kind" "$id" "$launcher")"
    fi
  done
