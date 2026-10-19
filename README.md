# tmaxer

tmaxer runs one orchestrator agent and up to nine worker agents in tmux. You talk to the orchestrator. It splits your requests into tasks, sends them to the workers, decides their approvals, and merges their work.

> Status: experimental. Tested on macOS with the GitHub Copilot CLI.

## Requirements

- tmux, git, jq, python3
- GitHub Copilot CLI (`copilot`), logged in
- A git repository with at least one commit

## Quick start

```bash
git clone https://github.com/westwardharbor0/tmaxer
cd tmaxer
./tmaxer up 3 --repo ~/path/to/your/repo --name demo
```

The first number is the worker count, from 3 to 9. When run from a terminal, `up` opens the tmux session:

- The orchestrator is on the left. Type your requests there.
- The workers are on the right.

## Using it

1. Describe what you want in the orchestrator pane. You can send requests one after another.
2. The orchestrator sends tasks to idle workers. Each worker works in its own git branch.
3. When a worker finishes, the orchestrator merges its branch into `tmaxer/<name>/review`.
4. If a worker needs a command outside its task scope, the orchestrator decides whether to allow it.
5. If Copilot asks you something in a pane, answer it there. Enter selects the highlighted option.

Useful tmux keys:

| Keys | Action |
|---|---|
| `Ctrl-b` then arrow | Move between panes |
| `Ctrl-b` then `z` | Zoom the current pane to full screen, press again to return |
| `Ctrl-b` then `d` | Detach, leaving the session running |

To reattach later: `tmux -L tmaxer-demo attach -t tmaxer-demo`.

## Stopping

- Press `Ctrl-D` in the orchestrator pane to end the session.
- Or run `./tmaxer down --name demo` from another terminal.

Stopping removes the worktrees and archives the session state. The branches stay, so you can review or merge them.

## Commands

You normally use the orchestrator, not these. They are there for manual control.

| Command | Purpose |
|---|---|
| `./tmaxer up N --repo PATH [--name NAME]` | Start a session. Options: `--orch-model`, `--worker-model`. |
| `./tmaxer down [--name NAME]` | Stop a session. |
| `./tmaxer send WORKER "TASK" [--scope FILE]` | Give a worker a task by hand. |
| `./tmaxer decide ID allow` | Allow a pending command. |
| `./tmaxer decide ID deny REASON` | Deny a pending command, with a reason the worker sees. |
| `./tmaxer wait` | Print the next worker event. |

## Settings

Set these as environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `TMAXER_ORCH_MODEL` | `gpt-6-sol` | Model for the orchestrator |
| `TMAXER_WORKER_MODEL` | `claude-haiku-5.5` | Model for the workers |
| `TMAXER_APPROVAL_TIMEOUT` | `900` | Seconds before an unanswered approval is denied |
| `TMAXER_HOME` | `~/.tmaxer` | Where session state is kept |

## Safety

- These are always denied, even if the orchestrator approves them: `sudo`, `rm -rf /`, piping into a shell, and reading credential folders such as `~/.ssh`.
- Each task has a scope that lists the commands and files it may use. Anything outside the scope needs an approval.
- tmaxer is not a sandbox. Allowed commands run with your user permissions.

## What it changes on your machine

- `up` adds the worktrees to `trustedFolders` in `~/.copilot/config.json`, so Copilot doesn't stop on a trust prompt. `down` removes them.
- Session state lives in `~/.tmaxer/<name>/`. A stopped session moves to `~/.tmaxer/archive/`.

## Troubleshooting

- **"already exists" or "branch exists":** choose a new `--name`. Old branches are kept, so a name that was used before can't be reused.
- **A worker seems stuck:** look at its pane. A pending approval waits up to `TMAXER_APPROVAL_TIMEOUT` seconds.
- **Usage is high:** every worker and the orchestrator is a full agent session, so each one uses your Copilot quota.

## Tests

```bash
bash tests/run.sh
```

The tests make no model calls. They use a fake agent and a temporary Copilot config folder, so your real settings are not touched.

## License

Apache License 2.0. See [LICENSE](LICENSE).
