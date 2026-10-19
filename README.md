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

The first number is the worker count, from 3 to 9. When run from a terminal, `up` opens the tmux session. The orchestrator is on the left, and the workers are on the right.

## Using it

1. Describe what you want in the orchestrator pane. You can send requests one after another.
2. The orchestrator sends tasks to idle workers. Each worker works in its own git branch.
3. When a worker finishes, the orchestrator merges its branch into the review branch.
4. If a worker needs a command outside its task scope, the orchestrator decides whether to allow it.
5. If Copilot asks you something in a pane, answer it there. Enter selects the highlighted option.

Useful tmux keys:

| Keys | Action |
|---|---|
| `Ctrl-b` then arrow | Move between panes |
| `Ctrl-b` then `z` | Zoom the current pane to full screen. Press again to return. |

## Detach or stop

These do different things:

| Action | What happens |
|---|---|
| `Ctrl-b` then `d` (detach) | Everything keeps running. Reattach with `tmux -L tmaxer-demo attach -t tmaxer-demo`. |
| Close the terminal window | Same as detaching. The session keeps running. |
| `Ctrl-D` in the orchestrator pane | Stops the whole session. |
| `./tmaxer down --name demo` | Stops the whole session, from any terminal. |
| `Ctrl-D` in a worker pane | Stops only that worker. |

Stopping a session stops every agent, removes clean worktrees and their trust entries, and moves the session state to `~/.tmaxer/archive/`. Branches are kept.

## Worktrees and branches

A session creates one worktree and one branch per worker, plus a review worktree:

| Path | Branch |
|---|---|
| `~/.tmaxer/demo/wt/w1`, `w2`, `w3` | `tmaxer/demo/w1`, `w2`, `w3` |
| `~/.tmaxer/demo/wt/review` | `tmaxer/demo/review` |

Each one starts from your repository's current HEAD. Your own checkout and branches are not changed. The session only adds branches and worktrees.

Workers commit only when a task asks them to. Uncommitted changes are never merged.

When a session stops:

- Worktrees without uncommitted changes are removed. Files that git ignores, such as build output, go with them.
- A worktree with uncommitted changes is kept. It moves to `~/.tmaxer/archive/demo-<time>/wt/<worker>`, and `down` prints the path. It is a normal git worktree, so you can commit there.
- All branches are kept.

## Merging

1. The orchestrator merges each finished worker branch into `tmaxer/demo/review`, then runs your tests there.
2. If a merge conflicts, the orchestrator stops and asks you.
3. tmaxer never merges into your own branch. You do that.

To bring the result into your branch, run this from your repository:

```bash
git merge tmaxer/demo/review
```

You can do it while the session runs or after it stops. The branch stays either way.

## Recovery

tmaxer has no resume command. It cannot reattach a dead session or restore an agent's conversation. Here is what you can recover:

- **Terminal closed or detached:** reattach. The session never stopped.
- **You stopped the session by accident:** committed work is in the branches. Worktrees with uncommitted changes are kept in the archive.
- **Machine restarted or tmux killed:** the session is gone, but `~/.tmaxer/demo/` is still on disk. Run `./tmaxer down --name demo` to clean up. Then merge the branches you need.
- **Name reuse:** a name cannot be reused while its branches exist. Pick a new `--name`.

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

A scope file has one rule per line:

```
shell: npm test
shell: git diff *
write: src/auth/*
```

`send` rejects scopes that allow `shell: *`, shells, interpreters, `curl`, `ssh`, `rm`, `git push`, and similar. Those need a scope file written by a person.

## Settings

Set these as environment variables before `up`. Each session fixes its values when it starts, so changing a variable later does not affect a running session.

| Variable | Default | Meaning |
|---|---|---|
| `TMAXER_ORCH_MODEL` | `gpt-6-sol` | Model for the orchestrator |
| `TMAXER_WORKER_MODEL` | `claude-haiku-5.5` | Model for the workers |
| `TMAXER_APPROVAL_TIMEOUT` | `900` | Seconds before an unanswered approval is denied |
| `TMAXER_HOME` | `~/.tmaxer` | Where session state is kept |
| `TMAXER_AGENT_CMD` | `copilot` | Command that starts each agent (see below) |

The `--orch-model` and `--worker-model` options of `up` override the model variables for that session:

```bash
TMAXER_APPROVAL_TIMEOUT=600 ./tmaxer up 4 --repo ~/path/to/your/repo --worker-model claude-haiku-5.5
```

### TMAXER_AGENT_CMD

`TMAXER_AGENT_CMD` replaces the command that starts every agent: the orchestrator and all workers. The default is `copilot`.

tmaxer adds its own flags after your command. For the orchestrator, it adds the model, the directories and tool permissions it needs, and the orchestrator prompt:

```
--model MODEL --add-dir DIR --allow-tool ... -i "PROMPT"
```

For each worker, it adds the model, the hook plugin directory, and the worker prompt:

```
--model MODEL --plugin-dir DIR -i "PROMPT"
```

So your command must accept these flags and pass them on to Copilot CLI. A wrapper that does this is included in `examples/copilot-wrapper.sh`:

```bash
export TMAXER_AGENT_CMD="$PWD/examples/copilot-wrapper.sh"
./tmaxer up 3 --repo ~/path/to/your/repo --name demo
```

Rules:

- The value is split on spaces, so the path to the command must not contain spaces. Arguments are allowed, for example `TMAXER_AGENT_CMD="/path/wrapper.sh --profile work"`.
- `up` stops early if the command is not found.
- Approvals and completion detection rely on Copilot's hooks, so the command must end in Copilot CLI. Other agents are not supported.
- To see exactly what runs, read a launch script while the session is up: `cat ~/.tmaxer/demo/run-w1.sh`.

## Safety

- These are always denied, even if the orchestrator approves them: `sudo`, `rm -rf /`, piping into a shell, and reading credential folders such as `~/.ssh`.
- Each task has a scope that lists the commands and files it may use. Anything outside the scope needs an approval.
- tmaxer is not a sandbox. Allowed commands run with your user permissions.

## What it changes on your machine

- `up` adds the worktrees to `trustedFolders` in `~/.copilot/config.json`, so Copilot does not stop on a trust prompt. `down` removes them.
- Session state lives in `~/.tmaxer/<name>/`. A stopped session moves to `~/.tmaxer/archive/`.

## Troubleshooting

- **"already exists" or "branch exists":** choose a new `--name`. Old branches are kept.
- **A worker seems stuck:** look at its pane. A pending approval waits up to `TMAXER_APPROVAL_TIMEOUT` seconds.
- **Usage is high:** every worker and the orchestrator is a full agent session, so each one uses your Copilot quota.

## Tests

```bash
bash tests/run.sh
```

The tests make no model calls. They use a fake agent and a temporary Copilot config folder, so your real settings are not touched.

## License

Apache License 2.0. See [LICENSE](LICENSE).
