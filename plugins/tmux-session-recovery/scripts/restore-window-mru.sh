#!/usr/bin/env bash
# After a tmux-resurrect restore, re-stamp each window's @lf focus counter
# from the window-mru sidecar, so an MRU window picker (sorting on @lf)
# keeps its pre-restart order. Raises the global @clk clock to at least the
# highest restored stamp, so post-restore switches sort above restored ones.
# @clk is never lowered, which makes the script safe to re-run and safe on a
# server whose clock is already ahead. Windows that no longer exist are
# skipped. No-op when the sidecar is missing.
#
# Wire it in tmux.conf (resurrect runs the value with eval in a plain shell):
#   set -g @resurrect-hook-post-restore-all '"/path/to/restore-window-mru.sh"'
set -uo pipefail

mru="${TMUX_MRU_SIDECAR:-$HOME/.local/share/tmux/resurrect/window-mru.last}"
[ -f "$mru" ] || exit 0
command -v tmux >/dev/null 2>&1 || exit 0

max=0
while IFS=$'\t' read -r session index lf; do
  [ -n "$session" ] && [ -n "$index" ] || continue
  case "$lf" in ''|*[!0-9]*) continue ;; esac
  tmux set -w -t "${session}:${index}" @lf "$lf" 2>/dev/null || continue
  [ "$lf" -gt "$max" ] && max="$lf"
done < "$mru"

clk="$(tmux show -gv @clk 2>/dev/null)"
case "$clk" in ''|*[!0-9]*) clk=0 ;; esac
if [ "$max" -gt "$clk" ]; then
  tmux set -g @clk "$max" 2>/dev/null || true
fi

exit 0
