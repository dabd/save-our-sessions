---
name: recovering-tmux-sessions
description: Use when a user asks a running Claude to recover, resume, or restore Claude/Codex sessions after a tmux server died (reboot, MDM restart, crash, kill-server) and tmux-resurrect restored the window layout but the panes are dead shells. For driving recovery from a live agent, not the bare `sos` command.
---

# Recovering tmux sessions

## Starting the replacement server (do this first)

If the dead server is being replaced from inside a live agent session, the new server
captures that agent's environment and every restored pane inherits it. Agent-specific
vars (`CODEX_HOME`, `CLAUDE_CONFIG_DIR`, `CLAUDE_*`, `CODEX_*`) then silently retarget
every resume: wrong config home, phantom trust prompts, "no saved session" for ids that
exist. Shell functions that hard-pin their config dir survive; anything that reads the
inherited env breaks.

Start the server with those vars stripped, then scrub the tmux global environment as a
second layer, and verify before restoring:

```bash
env $(env | grep -oE '^(CLAUDE|CODEX)[A-Z_]*' | sed 's/^/-u /') tmux start-server
for v in $(env | grep -oE '^(CLAUDE|CODEX)[A-Z_]*'); do tmux set-environment -g -u "$v"; done
tmux show-environment -g | grep -E 'CLAUDE|CODEX'   # must print nothing
```

With a clean server env, resumes need no per-command config pinning - the launcher
routing below is sufficient.

The `save-our-sessions` reader (`scripts/tmux-agent-recover.sh`, aliased `sos`) maps each
restored pane back to the session it ran and prints the resume command. Read the script
once; its comments cover the output format, launcher, cwd prefix, and unplaced report.
This skill adds the judgment the script cannot express: drive from a live agent, verify,
report.

## Recipe

1. **Run the reader by absolute path** (`sos` is interactive-shell only; your Bash tool is
   not), capturing once into files: `"$REC" >placed.txt 2>unplaced.txt`. Re-running later
   misses sessions you just launched, and new windows renumber panes - work from the snapshot.
2. **Read both files, classify every line** before any keystroke: own pane (skip), codex
   (check syntax), claude (drive), unplaced (defer to new windows).
3. **Drive each placed pane** (guards below). stdout lines are safe to drive; stderr
   (unplaced) needs a new window and a decision.
4. **Verify** each driven pane, then **report** launched / waiting-on-prompt / failed counts.
   Never report "all recovered" from the send loop alone.

## Sending into a pane

```bash
tmux send-keys -t "$target" C-u            # clear restored partial input
tmux send-keys -t "$target" -l -- "$cmd"   # -l literal: '&&', ';', keywords not reinterpreted
tmux send-keys -t "$target" Enter          # separate keystroke
```

Send **verbatim**, including any leading `cd <dir> && ` - resume is cwd-scoped and fails
without it. The pane is a live shell, so claude runs as its child; no `zsh -ic` wrapper needed.

## Guards (every placed pane)

| Guard | Why |
|---|---|
| Skip your own pane (`$TMUX_PANE`) | Resuming into it types over your input and kills this session |
| Skip panes whose `pane_current_command` is not a shell | Don't clobber a running agent; keeps the sweep idempotent |
| Keep the `cd` prefix | Resume is cwd-scoped; stripping it gives "No conversation found" |
| Stagger sends (~0.4s, batch large fleets) | ~40 simultaneous launches thrash CPU and API limits |

## Gotchas the reader cannot tell you

- **Codex mislabeled as `claude --resume`.** The log is claude-only, so a codex pane that
  falls back to the log (not the sidecar) is emitted as claude. If the window name reads
  like codex work, resume with `codex resume <id>` (same id, codex verb).
- **Resume can block on "Do you trust the files in this folder?"** Fires for a dir not yet
  trusted under that config (common in `$HOME` and personal). A security gate: surface it,
  let the user press it, never auto-confirm.
- **Your own session shows up as unplaced (false positive).** The pre-crash sidecar predates
  it. Exclude your own `@claude_session_id` before acting on the unplaced list.
- **Recorded cwd can be stale after a directory rename.** The resume command replays the
  path recorded at save time; if the directory moved since, `cd` fails and the resume never
  runs. The transcript still exists under the project slug of the NEW path - find it by id
  (`find ~/.claude*/projects -name '<id>.jsonl'`), then resend with the corrected `cd`.
- **A resume that fails with "No conversation found" for an id missing from disk is
  unrecoverable.** That agent exited before the save; leave the pane as a clean shell and
  say so in the report rather than retrying.
- **`send-keys` can race:** clear-then-command sometimes swallows the command. If a pane
  stays a shell after driving, resend with a pause between clear, command, and Enter.

## Config routing (work vs personal)

The reader emits the launcher per session (`claude` vs `claude-personal`) - drive it verbatim.
Two catches:

- A personal session recorded before the launcher column defaults to bare `claude` and fails
  with "No conversation found". Confirm its home (`compgen -G "$HOME/.claude-personal/projects/*/<id>.jsonl"`)
  and resume with `claude-personal --resume <id>` from its original dir.
- The `claude` shell function may hard-pin `CLAUDE_CONFIG_DIR`, so an inline override is
  ignored. Target personal via the real binary: `env CLAUDE_CONFIG_DIR=~/.claude-personal ~/.local/bin/claude ...`.

## Unplaced sessions (stderr)

Resumable but no restored window maps to them (a window was reused, displacing the first).
No pane to drive: open a fresh window per session, route by launcher, drive it. Placement is
a judgment call - confirm the target tmux session with the user, don't guess. Widen the
lookback with `TMUX_AGENT_RECENT_DAYS=14` if an expected session is missing.

## Verify

Re-read each target (`tmux capture-pane -p -t <target> | tail`). Still a shell prompt,
"No conversation found", or "No such file or directory" means it failed: stale dir
short-circuited `cd &&`, wrong launcher, or a send race. Report the exact panes needing the
user's hand.