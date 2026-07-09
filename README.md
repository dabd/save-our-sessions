# save-our-sessions

SOS. Recover Claude Code sessions after a tmux restart.

The tmux server dies. You lose which `claude` session ran in which window. This plugin records the mapping as each session starts. After a restart it maps restored panes back to their sessions.

## Install

```
/plugin marketplace add dabd/save-our-sessions
/plugin install tmux-session-recovery@save-our-sessions
```

One plugin: **[tmux-session-recovery](plugins/tmux-session-recovery/)**. It stamps each pane with its session id and logs it by pane position. Position survives a restart, so recovery works even when many sessions share a directory. The [plugin README](plugins/tmux-session-recovery/README.md) has the details.

## Recover

After a crash there is no live Claude to ask. Recovery is a plain command. Alias it:

```bash
alias sos="$HOME/projects/mystuff/save-our-sessions/plugins/tmux-session-recovery/scripts/tmux-agent-recover.sh"
```

Run `sos` in any restored pane. It prints one `claude --resume <id>` per window on stdout, the unplaced-sessions report on stderr. It drives nothing.

## Wire the snapshot (tmux-resurrect)

Recovery pairs with [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect). Snapshot each pane's id at every resurrect save. In `tmux.conf`:

```tmux
set -g @resurrect-hook-post-save-all '"$HOME/path/to/save-our-sessions/plugins/tmux-session-recovery/scripts/tmux-agent-snapshot.sh"'
```

Point at the script directly, not via `run-shell`. resurrect runs the hook with `eval` in a plain shell, and a `\t` in a tmux format string stays literal, so the inline version fails.

## License

MIT.
