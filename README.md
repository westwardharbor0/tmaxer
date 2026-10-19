# tmaxer

Run one orchestrator agent and 3–9 worker agents in tmux.

The orchestrator is a chat you talk to in the left pane. You send it requests over time. It splits each request into tasks, sends each task to an idle worker with a per-task scope, decides approvals, and merges finished branches. Workers sit in the right-hand grid. Each one runs in its own git worktree and branch.

> **Status: experimental.** Tested on macOS with the GitHub Copilot CLI. Expect rough edges.

## How it works

- **Layout:** orchestrator on the left, workers in a grid on the right (1 column for 3 workers, 2 for 4–6, 3 for 7–9).
- **Isolation:** each worker has a worktree on branch `tmaxer/<name>/w<i>`. A `review` worktree collects merges. `down` keeps the branches.
- **Messaging:** tasks and results are files. Events are queued as files. `tmaxer wait` blocks until one arrives.
- **Copilot hooks:** a `preToolUse` hook gates every worker tool call. An `agentStop` hook detects the end of a turn and requires a result file.
- **Access, in three layers:**
  1. Global hard-deny patterns: `sudo`, `rm -rf /`, piping into a shell, and credential paths. These always win.
  2. The task's scope file, written by the orchestrator from the task.
  3. An orchestrator decision for anything else. These are one-off and don't widen the scope.

Design details are in [PLAN.md](PLAN.md).

## Requirements

- bash, tmux, git, jq, python3
- GitHub Copilot CLI (`copilot`), logged in, with access to the models you choose
- A git repository with at least one commit to run against

## Quick start

```bash
git clone https://github.com/westwardharbor0/tmaxer
cd tmaxer
./tmaxer up 3 --repo /path/to/your/repo --name demo
```

`up` attaches to tmux when run in a terminal. Type your requests into the orchestrator pane.

- Press Ctrl-D in the orchestrator pane to end the whole session.
- Or run `./tmaxer down --name demo` from another terminal.

Ctrl-D in a worker pane stops only that worker. Ending the orchestrator ends the session.

## Commands

| Command | What it does |
|---|---|
| `tmaxer up N --repo PATH [--name NAME] [--orch-model M] [--worker-model M]` | Create worktrees, trust them, start the layout. N must be 3–9. |
| `tmaxer send <worker> "<task>" [--scope FILE]` | Give a worker a task. Refused while the worker is busy. |
| `tmaxer wait` | Block until a worker event arrives, then print it. |
| `tmaxer decide <approval-id> allow` | Allow one pending command. |
| `tmaxer decide <approval-id> deny <reason>` | Deny one pending command, with a reason the worker sees. |
| `tmaxer down [--name NAME]` | Stop the session, remove worktrees and trust entries, and archive its state. |

A scope file has one rule per line:

```
shell: npm test
shell: git diff *
write: src/auth/*
```

`send` rejects scopes that allow `shell: *`, shells, interpreters, `curl`, `ssh`, `rm`, `git push`, and similar. Those need a scope file written by a person.

## Environment

| Variable | Default | Purpose |
|---|---|---|
| `TMAXER_ORCH_MODEL` | `gpt-6-sol` | Orchestrator model |
| `TMAXER_WORKER_MODEL` | `claude-haiku-5.5` | Worker model |
| `TMAXER_AGENT_CMD` | `copilot` | Agent executable (tests use a fake one) |
| `TMAXER_APPROVAL_TIMEOUT` | `900` | Seconds before an unanswered approval is denied |
| `TMAXER_HOME` | `~/.tmaxer` | Where session state lives |

## Files on disk

- `~/.tmaxer/<name>/`: tasks, results, events, decisions, scopes, and `audit.log`. `down` moves this to `~/.tmaxer/archive/`.
- Git branches `tmaxer/<name>/*`: kept after `down`.
- `~/.copilot/config.json`: `up` adds the worktrees to `trustedFolders`, and `down` removes them. The file is JSONC, so tmaxer edits it with Python and keeps its comment header and file mode.

## Tests

```bash
bash tests/run.sh
```

The tests make no model calls. They use a fake agent and a temporary `COPILOT_HOME`, so your real Copilot config is not touched. The suite includes a real tmux layout run.

## Limitations

- **Cost:** the orchestrator and every worker are full agent sessions, so usage adds up quickly.
- **Not a sandbox:** the patterns above are triage, not isolation. Copilot's `--sandbox` is not wired in yet.
- **Permission prompts:** in interactive mode, Copilot still asks about some paths. Answer them in the pane.
- **Hook timeouts fail open** in Copilot. tmaxer therefore enforces its own approval deadline (`TMAXER_APPROVAL_TIMEOUT`).
- **Untested:** Linux. The script targets bash 3.2, which macOS ships.

## License

Apache License 2.0. See [LICENSE](LICENSE).
