# claude-tmux-recovery

Recover Claude Code sessions after a tmux restart.

The tmux server dies. You lose which `claude` session ran in which window. This records the mapping as sessions start, then maps restored panes back to the sessions to resume.

A Claude Code plugin marketplace with one plugin:

- **[tmux-session-recovery](plugins/tmux-session-recovery/)** stamps each tmux pane with its Claude session id and logs it by pane position. An unexpected restart no longer loses the pane-to-session mapping. Position is the key, so it works even when many sessions share one directory.

## Install

```
/plugin marketplace add dabd/claude-tmux-recovery
/plugin install tmux-session-recovery@claude-tmux-recovery
```

The [plugin README](plugins/tmux-session-recovery/README.md) covers how it works, verification, and the `CLAUDE_CONFIG_DIR` note.

## Recovery wiring (tmux-resurrect)

The plugin captures the mapping. Recovery pairs it with [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect).

1. Snapshot each pane's id alongside every resurrect save. resurrect runs the hook value with `eval` in a plain shell, so point it at the snapshot script directly (not `run-shell`). In `tmux.conf`:

   ```tmux
   set -g @resurrect-hook-post-save-all '"$HOME/path/to/claude-tmux-recovery/plugins/tmux-session-recovery/scripts/tmux-agent-snapshot.sh"'
   ```

   The script builds the format with real tab bytes and drops panes with no id. A `\t` in a tmux format string stays literal, so the inline one-liner version does not work.

2. After a restart, run `scripts/tmux-agent-recover.sh` to print the resume command per restored pane. It reads the sidecar first, then falls back to the plugin's append log. Match is by position `(session_name, window_index, pane_index)`, with `window_name` as a tiebreak. The reader is agent-neutral and config-dir-aware: it prints `<launcher> --resume <id>` for claude (e.g. `claude-personal --resume <id>` for a session recorded under `~/.claude-personal`) or `<launcher> resume <id>` for codex, based on the recorded agent kind and launcher. Entries predating the launcher column default to `claude`.

Worst-case staleness is the resurrect save interval. The append log closes the gap for a session born and killed between saves.

## License

MIT. See `LICENSE`.
