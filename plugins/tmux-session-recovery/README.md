# tmux-session-recovery

Record which Claude Code session id runs in each tmux pane. An unexpected tmux restart no longer loses the mapping. After a restart you resume each window with the session it was running, even when many sessions share one directory.

## The problem

You run several `claude` sessions across tmux windows. The server dies: a crash, a reboot, an accidental `kill-server`. You lose which session id ran in which window.

Tracing logs by hand recovers it slowly. Matching by working directory fails when many sessions share a directory. They all land in one `~/.claude/projects/<dir>/` folder.

## How it works

Recording happens at session start, not at kill time. A tmux hook cannot read a dead pane's environment. A shell trap does not fire on a hard kill. Capturing "when the session ends" is unreliable, so a Claude Code `SessionStart` hook fires on start or resume and does two things:

1. Stamps the pane with the tmux options `@claude_session_id` and `@agent_launcher`, both queryable from the tmux server.
2. Appends one row to `~/.local/share/tmux/claude-sessions.log`, keyed by pane position (`session_name`, `window_index`, `pane_index`, `window_name`) plus the working directory and the launcher. Position is the key that survives a restart. That is what recovers the mapping when several sessions share a directory.

The session id comes from the hook's stdin JSON (`session_id`). The working directory is stored verbatim, never turned into a Claude projects slug. Claude replaces both `/` and `.` with `-`, so reconstructing the slug is error-prone.

The launcher is the command that reattaches the session to the right config dir. Sessions under distinct `CLAUDE_CONFIG_DIR`s are stored separately, so a bare `claude --resume` cannot reach one recorded under a different dir. The launcher is the config dir's basename with its leading dot stripped: `~/.claude` gives `claude`, `~/.claude-personal` gives `claude-personal`, matching the shell wrappers that pin each dir. `CLAUDE_CONFIG_DIR` is read from the hook's environment.

## Install

```
/plugin marketplace add dabd/save-our-sessions
/plugin install tmux-session-recovery@save-our-sessions
```

Run more than one Claude config via `CLAUDE_CONFIG_DIR`, say a work `~/.claude` and a personal `~/.claude-personal`? Enable the plugin in each. Config dirs are isolated. A plugin enabled in one does not apply to the other.

## Verify

From inside a tmux pane, feed the hook a synthetic event:

```bash
echo '{"session_id":"test-uuid-1234","cwd":"/tmp","hook_event_name":"SessionStart","source":"startup"}' \
  | "$CLAUDE_PLUGIN_ROOT/scripts/record-tmux-session.sh"
tmux show -p @claude_session_id          # -> @claude_session_id test-uuid-1234
tail -1 ~/.local/share/tmux/claude-sessions.log
```

Outside tmux the hook is a no-op and exits 0. It never blocks a session start.

## Configuration

- `TMUX_CLAUDE_LOG` overrides the log path. Default `~/.local/share/tmux/claude-sessions.log`.

## Recovery after a restart

The capture half is this plugin. tmux-resurrect closes the loop.

`scripts/tmux-agent-snapshot.sh` runs at every resurrect save. It writes each pane's id by position to `~/.local/share/tmux/resurrect/agent-ids.last`. Wire it as the `@resurrect-hook-post-save-all` hook (see the repository README).

`scripts/tmux-agent-recover.sh` runs after a restart. It prints the resume command per restored pane, matched by position, with the append log as a fallback.

The scripts are agent-neutral. A pane is recovered if it carries `@agent_session_id` (with `@agent_kind`, default `claude`), or the legacy `@claude_session_id` the SessionStart hook sets. The reader dispatches by kind and launcher: `<launcher> --resume <id>` for claude (e.g. `claude-personal --resume <id>`), `<launcher> resume <id>` for codex. Rows and sidecar entries predating the launcher column default to `claude`, so old logs still recover.

### Completeness report

Position-keyed recovery can only restore what was live at snapshot time. If a window was later reused by a second session, the first session is stamped over and appears in no restored position: recovery would restore it nowhere and say nothing. To close that gap the reader emits, on stderr, every session the recorder saw that was **not** placed into a restored window, is still resumable (a transcript exists under a known config dir), and was seen recently. stdout stays the clean per-pane placement list, safe to pipe into `tmux send-keys`; the report is advisory on stderr.

- `TMUX_AGENT_RECENT_DAYS` bounds the report's lookback. Default `3`.
- `TMUX_AGENT_PROJECT_DIRS` (colon-separated `<configdir>/projects` paths) overrides where the resumable check looks for transcripts. Defaults to the active `CLAUDE_CONFIG_DIR` plus `~/.claude` and `~/.claude-personal`.

Both scripts honor `TMUX_AGENT_SIDECAR` to override the sidecar path. Default `~/.local/share/tmux/resurrect/agent-ids.last`.

## License

MIT. See `LICENSE`.
