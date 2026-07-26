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

# logged_cwd <id> -> the newest non-empty cwd (col 7) the recorder logged for
# this session, or empty. `claude --resume` is cwd-scoped: it only finds a
# session whose project slug matches the current directory. resurrect sometimes
# restores a pane to a different dir than the session ran in, so resume must run
# from the recorded cwd. The sidecar has no cwd column, hence the log lookup.
logged_cwd() {
  [ -f "$log" ] || return 0
  awk -F'\t' -v id="$1" '$2==id && $7!="" { c=$7 } END { print c }' "$log"
}

# resume_at <pane_cwd> <agent_kind> <id> <launcher> -> resume command, prefixed
# with `cd <recorded-cwd> &&` when that cwd is known and differs from the pane's
# current path. Same dir (or unknown cwd) -> bare resume, so the common case
# stays clean and paste-safe.
resume_at() {
  local pane_cwd="$1" kind="$2" id="$3" launcher="$4" cmd cwd
  cmd="$(resume_cmd "$kind" "$id" "$launcher")"
  cwd="$(logged_cwd "$id")"
  if [ -n "$cwd" ] && [ "$cwd" != "$pane_cwd" ]; then
    printf 'cd %q && %s' "$cwd" "$cmd"
  else
    printf '%s' "$cmd"
  fi
}

# lookup <session> <window> <pane> -> "<agent_kind>\t<id>\t<launcher>" or empty.
# Sidecar is the 7-column agent format (kind $5, id $6, launcher $7). The
# persistent log carries launcher in $8 and agent kind in $9; rows predating
# either column default to "claude".
lookup() {
  local s="$1" w="$2" p="$3" hit=""
  if [ -f "$sidecar" ]; then
    hit="$(awk -F'\t' -v s="$s" -v w="$w" -v p="$p" \
      '$1==s && $2==w && $3==p { print $5 "\t" $6 "\t" ($7==""?"claude":$7); exit }' "$sidecar")"
  fi
  if [ -z "$hit" ] && [ -f "$log" ]; then
    hit="$(awk -F'\t' -v s="$s" -v w="$w" -v p="$p" \
      '$3==s && $4==w && $5==p { id=$2; lchr=($8==""?"claude":$8); kind=($9==""?"claude":$9) }
       END { if (id != "") printf "%s\t%s\t%s", kind, id, lchr }' "$log")"
  fi
  printf '%s' "$hit"
}

# resumable <id> -> 0 if a transcript for this id exists under any known config
# dir, so the completeness report never lists sessions that cannot be resumed.
# Config dirs: the active one, plus common work/personal split. Override the
# search roots with TMUX_AGENT_PROJECT_DIRS (colon-separated <configdir>/projects).
project_dirs() {
  if [ -n "${TMUX_AGENT_PROJECT_DIRS:-}" ]; then
    printf '%s' "$TMUX_AGENT_PROJECT_DIRS" | tr ':' '\n'
    return
  fi
  printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" \
                "$HOME/.claude/projects" "$HOME/.claude-personal/projects"
}
resumable() {
  local id="$1" kind="${2:-claude}" d
  if [ "$kind" = codex ]; then
    # Codex transcripts: <home>/sessions/YYYY/MM/DD/rollout-<ts>-<id>.jsonl
    for d in "${CODEX_HOME:-$HOME/.codex}/sessions" \
             "$HOME/.codex/sessions" "$HOME/.codex-personal/sessions"; do
      [ -d "$d" ] || continue
      [ -n "$(find "$d" -name "rollout-*-$id.jsonl" -print -quit 2>/dev/null)" ] && return 0
    done
    return 1
  fi
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    compgen -G "$d/*/$id.jsonl" >/dev/null 2>&1 && return 0
  done < <(project_dirs | sort -u)
  return 1
}

tab=$'\t'
fmt="#{session_name}${tab}#{window_index}${tab}#{pane_index}${tab}#{window_name}${tab}#{pane_current_path}"

# Placed ids accumulate here (the loop runs in a pipeline subshell, so a file is
# the reliable way to carry the set out to the completeness pass below).
placed="$(mktemp)"; trap 'rm -f "$placed"' EXIT

tmux list-panes -a -F "$fmt" \
| while IFS=$'\t' read -r s w p name pane_cwd; do
    hit="$(lookup "$s" "$w" "$p")"
    if [ -n "$hit" ]; then
      IFS=$'\t' read -r kind id launcher <<<"$hit"
      printf '%s\n' "$id" >> "$placed"
      printf '%s:%s.%s (%s) -> %s\n' "$s" "$w" "$p" "$name" "$(resume_at "$pane_cwd" "$kind" "$id" "$launcher")"
    fi
  done

# --- Completeness report -----------------------------------------------------
# Position-keyed recovery cannot place a session that was NOT live at snapshot
# time (e.g. a window later reused by another session displaces the first). Such
# a session is silently lost unless surfaced. List every id the recorder saw
# that was NOT placed above, is still resumable, and was seen recently.
[ -f "$log" ] || exit 0

# Recency cutoff (ISO8601 sorts lexically, so a string compare suffices). Default
# 3 days; override with TMUX_AGENT_RECENT_DAYS. If `date` cannot compute it, no
# recency filter is applied (show all unplaced).
days="${TMUX_AGENT_RECENT_DAYS:-3}"
cutoff="$(date -u -v-"${days}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
       || date -u -d "${days} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '')"

# Newest log row per id -> "ts \t id \t title \t launcher \t kind", most recent
# first.
unplaced="$(awk -F'\t' -v cutoff="$cutoff" '
  { id=$2; ts=$1; title=$6; lchr=($8==""?"claude":$8); kind=($9==""?"claude":$9)
    last_ts[id]=ts; last_title[id]=title; last_lchr[id]=lchr; last_kind[id]=kind }
  END { for (id in last_ts)
          if (cutoff=="" || last_ts[id] >= cutoff)
            printf "%s\t%s\t%s\t%s\t%s\n", last_ts[id], id, last_title[id], last_lchr[id], last_kind[id] }' \
  "$log" | sort -r)"

first=1
while IFS=$'\t' read -r ts id title launcher kind; do
  [ -n "$id" ] || continue
  grep -qxF "$id" "$placed" && continue          # already placed into a window
  resumable "$id" "$kind" || continue            # no transcript -> skip
  if [ "$first" = 1 ]; then
    printf '\n--- Unplaced sessions (seen recently, resumable, not tied to a restored window) ---\n' >&2
    first=0
  fi
  # No live pane for these, so pass an empty pane cwd: any recorded cwd differs
  # and gets a `cd` prefix, since we cannot know where the user will paste it.
  printf '(unplaced, last seen %s) "%s" -> %s\n' "$ts" "$title" "$(resume_at "" "$kind" "$id" "$launcher")" >&2
done <<<"$unplaced"
