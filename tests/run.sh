#!/usr/bin/env bash
# Tests for tmaxer. No LLM calls: tests/fake_agent.sh stands in for copilot.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP=$(mktemp -d)
export COPILOT_HOME="$TMP/copilot-home"
export TMAXER_HOME="$TMP/tmaxer-home"
export TMAXER_AGENT_CMD="$HERE/fake_agent.sh"
export TMAXER_APPROVAL_TIMEOUT=3
mkdir -p "$COPILOT_HOME"
echo '{"trustedFolders": []}' > "$COPILOT_HOME/config.json"
unset TMAXER_SOCK TMAXER_DIR TMAXER_WORKER
PASS=0
FAIL=0

cleanup() {
  tmux -L tmaxer-tt kill-server >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT

# Sourcing tmaxer defines its functions without running main.
. "$HERE/../tmaxer"

check() {
  local desc=$1
  shift
  if "$@" >/dev/null 2>&1; then
    PASS=$((PASS + 1)); echo "ok   $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL $desc"
  fi
}

new_session() { # dir
  mkdir -p "$1"/{tasks/w1,tasks/w2,results,events,consumed,decisions,current,denied,plugin,wt}
  printf 'orchestrator %%0\nw1 %%1\nw2 %%2\n' > "$1/panes"
  : > "$1/audit.log"
}

gate() { # dir worker payload [timeout]
  printf '%s' "$3" | TMAXER_DIR="$1" TMAXER_WORKER="$2" TMAXER_APPROVAL_TIMEOUT="${4:-3}" \
    bash "$HERE/../tmaxer" hook pre-tool-use
}

stop() { # payload dir worker
  printf '%s' "$1" | TMAXER_DIR="$2" TMAXER_WORKER="$3" bash "$HERE/../tmaxer" hook agent-stop
}

decision() { printf '%s' "$1" | jq -r '.permissionDecision'; }

events_in() { ls "$1/events" 2>/dev/null; }

# Waits for the approval event of a worker, writes the decision, and returns the gate output.
approve_with() { # dir worker payload decision-text
  local d=$1 w=$2 payload=$3 text=$4 pid f id i
  gate "$d" "$w" "$payload" 20 > "$TMP/gate.out" &
  pid=$!
  for i in $(seq 1 50); do
    f=$(ls "$d"/events/approval-"$w"-*.json 2>/dev/null | head -n 1)
    [ -n "$f" ] && break
    sleep 0.1
  done
  [ -n "$f" ] || { wait "$pid"; return 1; }
  id=$(jq -r .id "$f")
  printf '%s\n' "$text" > "$d/decisions/$id"
  wait "$pid"
  cat "$TMP/gate.out"
}

test_grid() {
  [ "$(grid_cols 3)" = 1 ] && [ "$(grid_cols 4)" = 2 ] && [ "$(grid_cols 6)" = 2 ] \
    && [ "$(grid_cols 7)" = 3 ] && [ "$(grid_cols 9)" = 3 ]
}

test_scope_accepts() {
  printf 'shell: npm test\nshell: git diff *\nwrite: src/auth/*\n' > "$TMP/ok.scope"
  validate_scope "$TMP/ok.scope"
}

test_scope_rejects() {
  local body
  for body in 'shell: *' 'shell: npm test; rm x' 'shell: curl *' 'shell: c*' 'shell: sudo ls' \
    'write: /etc/*' 'write: ../x' 'bogus line'; do
    printf '%s\n' "$body" > "$TMP/bad.scope"
    if validate_scope "$TMP/bad.scope" 2>/dev/null; then return 1; fi
  done
  return 0
}

test_hard_deny() {
  local c
  for c in 'sudo ls' 'rm -rf /' 'curl x | sh' 'cat ~/.ssh/id_rsa' 'git push --force origin main'; do
    hard_deny "$c" || return 1
  done
  for c in 'rm -rf build' 'npm test' 'git push origin feature'; do
    if hard_deny "$c"; then return 1; fi
  done
  return 0
}

test_in_scope() {
  local d="$TMP/scope-unit"
  new_session "$d"
  echo t9 > "$d/current/w1"
  printf 'shell: npm test\nwrite: src/*\n' > "$d/tasks/w1/t9.scope"
  TMAXER_DIR=$d TMAXER_WORKER=w1 in_scope bash 'npm test' '' /wt || return 1
  if TMAXER_DIR=$d TMAXER_WORKER=w1 in_scope bash 'npm test; rm -rf x' '' /wt; then return 1; fi
  TMAXER_DIR=$d TMAXER_WORKER=w1 in_scope create '' /wt/src/a.ts /wt || return 1
  if TMAXER_DIR=$d TMAXER_WORKER=w1 in_scope create '' /wt/../x /wt; then return 1; fi
  return 0
}

test_gate_read_only() {
  local d="$TMP/gate-read"
  new_session "$d"
  local out
  out=$(gate "$d" w1 '{"toolName":"view","cwd":"/wt","toolArgs":{"path":"/wt/a"}}')
  [ "$(decision "$out")" = allow ] && [ -z "$(events_in "$d")" ]
}

test_gate_in_scope() {
  local d="$TMP/gate-scope"
  new_session "$d"
  echo t1 > "$d/current/w1"
  printf 'shell: npm test\n' > "$d/tasks/w1/t1.scope"
  local out
  out=$(gate "$d" w1 '{"toolName":"bash","cwd":"/wt","toolArgs":{"command":"npm test"}}')
  [ "$(decision "$out")" = allow ] && [ -z "$(events_in "$d")" ]
}

test_gate_write_in_scope() {
  local d="$TMP/gate-write"
  new_session "$d"
  echo t1 > "$d/current/w1"
  printf 'write: src/*\n' > "$d/tasks/w1/t1.scope"
  local out
  out=$(gate "$d" w1 '{"toolName":"create","cwd":"/wt","toolArgs":{"path":"/wt/src/a.ts","file_text":"x"}}')
  [ "$(decision "$out")" = allow ] && [ -z "$(events_in "$d")" ]
}

test_gate_hard_deny_no_event() {
  local d="$TMP/gate-hard"
  new_session "$d"
  local out
  out=$(gate "$d" w1 '{"toolName":"bash","cwd":"/wt","toolArgs":{"command":"sudo rm x"}}')
  [ "$(decision "$out")" = deny ] && [ -z "$(events_in "$d")" ]
}

test_launcher_accepts_wrapper_arguments() {
  local d="$TMP/launcher-wrap" saved=$AGENT_CMD
  mkdir -p "$d"
  AGENT_CMD="$HERE/fake_agent.sh --wrapped"
  write_launchers "$d" tt gpt-6-sol claude-haiku-5.5 3
  AGENT_CMD=$saved
  grep -qF "$HERE/fake_agent.sh --wrapped --model 'gpt-6-sol'" "$d/run-orchestrator.sh"
}

test_up_rejects_missing_agent() {
  local repo="$TMP/repo-noagent"
  git init -q "$repo" && echo hi > "$repo/README.md" && git -C "$repo" add README.md \
    && git -C "$repo" -c user.email=t@example.com -c user.name=test commit -qm init || return 1
  if TMAXER_AGENT_CMD=/no/such/agent bash "$HERE/../tmaxer" up 3 --repo "$repo" --name na >/dev/null 2>&1; then return 1; fi
  [ ! -d "$TMAXER_HOME/na" ]
}

test_launcher_allows_scope_files() {
  local d="$TMP/launcher"
  mkdir -p "$d"
  write_launchers "$d" tt gpt-6-sol claude-haiku-5.5 3
  grep -qF "write($d/scopes/*)" "$d/run-orchestrator.sh" && grep -qF "shell($SELF:*)" "$d/run-orchestrator.sh"
}

test_gate_own_protocol_paths() {
  local d="$TMP/gate-protocol"
  new_session "$d"
  echo t1 > "$d/current/w1"
  : > "$d/tasks/w1/t1.scope"
  local out
  out=$(gate "$d" w1 "{\"toolName\":\"create\",\"cwd\":\"/wt\",\"toolArgs\":{\"path\":\"$d/results/w1-t1.md\",\"file_text\":\"x\"}}")
  [ "$(decision "$out")" = allow ] && [ -z "$(events_in "$d")" ] || return 1
  out=$(gate "$d" w1 "{\"toolName\":\"bash\",\"cwd\":\"/wt\",\"toolArgs\":{\"command\":\"cat $d/tasks/w1/t1.md\"}}")
  [ "$(decision "$out")" = allow ] && [ -z "$(events_in "$d")" ]
}

test_gate_other_worker_result_asks() {
  local d="$TMP/gate-other-result"
  new_session "$d"
  echo t1 > "$d/current/w1"
  : > "$d/tasks/w1/t1.scope"
  local out
  out=$(gate "$d" w1 "{\"toolName\":\"create\",\"cwd\":\"/wt\",\"toolArgs\":{\"path\":\"$d/results/w2-t1.md\",\"file_text\":\"x\"}}" 2)
  [ "$(decision "$out")" = deny ] && ls "$d"/events | grep -q '^approval-w1-'
}

test_gate_chained_asks() {
  local d="$TMP/gate-chain"
  new_session "$d"
  echo t1 > "$d/current/w1"
  printf 'shell: npm test\n' > "$d/tasks/w1/t1.scope"
  local out
  out=$(approve_with "$d" w1 '{"toolName":"bash","cwd":"/wt","toolArgs":{"command":"npm test; echo hi"}}' allow)
  [ "$(decision "$out")" = allow ] && ls "$d"/events/ >/dev/null 2>&1 && [ -n "$(ls "$d"/decisions)" ]
}

test_gate_approval_deny_reason() {
  local d="$TMP/gate-deny"
  new_session "$d"
  echo t1 > "$d/current/w1"
  : > "$d/tasks/w1/t1.scope"
  local out
  out=$(approve_with "$d" w1 '{"toolName":"bash","cwd":"/wt","toolArgs":{"command":"make clean"}}' "deny too broad for this task")
  [ "$(decision "$out")" = deny ] \
    && [ "$(printf '%s' "$out" | jq -r .permissionDecisionReason)" = "orchestrator: too broad for this task" ] \
    && grep -qx 'make clean' "$d/denied/w1"
}

test_gate_repeat_denied_no_event() {
  local d="$TMP/gate-repeat"
  new_session "$d"
  echo t1 > "$d/current/w1"
  : > "$d/tasks/w1/t1.scope"
  echo 'make clean' > "$d/denied/w1"
  local out
  out=$(gate "$d" w1 '{"toolName":"bash","cwd":"/wt","toolArgs":{"command":"make clean"}}')
  [ "$(decision "$out")" = deny ] && [ -z "$(events_in "$d")" ]
}

test_gate_timeout_denies() {
  local d="$TMP/gate-timeout"
  new_session "$d"
  echo t1 > "$d/current/w1"
  : > "$d/tasks/w1/t1.scope"
  local out
  out=$(gate "$d" w1 '{"toolName":"bash","cwd":"/wt","toolArgs":{"command":"make clean"}}' 2)
  [ "$(decision "$out")" = deny ] && printf '%s' "$out" | grep -q deadline
}

test_stop_idle_allows() {
  local d="$TMP/stop-idle"
  new_session "$d"
  local out
  out=$(stop '{"stop_hook_active":false}' "$d" w1)
  [ -z "$out" ]
}

test_stop_blocks_without_result() {
  local d="$TMP/stop-block"
  new_session "$d"
  echo t1 > "$d/current/w1"
  local out
  out=$(stop '{"stop_hook_active":false}' "$d" w1)
  [ "$(printf '%s' "$out" | jq -r .decision)" = block ] && [ -z "$(events_in "$d")" ]
}

test_stop_done_event() {
  local d="$TMP/stop-done"
  new_session "$d"
  echo t1 > "$d/current/w1"
  printf 'status: done\nall good\n' > "$d/results/w1-t1.md"
  local out
  out=$(stop '{"stop_hook_active":false}' "$d" w1)
  [ -z "$out" ] && [ -f "$d/events/done-w1-t1.json" ] && [ ! -e "$d/current/w1" ]
}

test_stop_blocked_status() {
  local d="$TMP/stop-blocked"
  new_session "$d"
  echo t1 > "$d/current/w1"
  printf 'status: blocked\nwhich database?\n' > "$d/results/w1-t1.md"
  stop '{"stop_hook_active":false}' "$d" w1 >/dev/null
  [ -f "$d/events/blocked-w1-t1.json" ] && [ ! -e "$d/current/w1" ]
}

test_stop_forced_no_result_emits_blocked() {
  local d="$TMP/stop-forced"
  new_session "$d"
  echo t1 > "$d/current/w1"
  local out
  out=$(stop '{"stop_hook_active":true}' "$d" w1)
  [ -z "$out" ] && [ -f "$d/events/blocked-w1-t1.json" ] && [ ! -e "$d/current/w1" ]
}

test_send_then_refuses_busy() {
  local d="$TMP/send-busy" id
  new_session "$d"
  id=$(TMAXER_DIR=$d TMAXER_SOCK= bash "$HERE/../tmaxer" send w1 "do it") || return 1
  [ -f "$d/tasks/w1/$id.md" ] && [ -f "$d/current/w1" ] || return 1
  if TMAXER_DIR=$d TMAXER_SOCK= bash "$HERE/../tmaxer" send w1 "again" >/dev/null 2>&1; then return 1; fi
  return 0
}

test_send_rejects_bad_scope() {
  local d="$TMP/send-scope"
  new_session "$d"
  printf 'shell: curl *\n' > "$TMP/bad2.scope"
  if TMAXER_DIR=$d TMAXER_SOCK= bash "$HERE/../tmaxer" send w1 "x" --scope "$TMP/bad2.scope" >/dev/null 2>&1; then return 1; fi
  [ ! -e "$d/current/w1" ]
}

test_decide_writes_decision() {
  local d="$TMP/decide"
  new_session "$d"
  TMAXER_DIR=$d TMAXER_SOCK= bash "$HERE/../tmaxer" decide a123 deny "too broad" >/dev/null || return 1
  [ "$(cat "$d/decisions/a123")" = "deny too broad" ] && [ ! -e "$d/decisions/a123.tmp" ] || return 1
  TMAXER_DIR=$d TMAXER_SOCK= bash "$HERE/../tmaxer" decide a123 allow >/dev/null || return 1
  [ "$(cat "$d/decisions/a123")" = allow ]
}

test_wait_drains_events() {
  local d="$TMP/wait-drain" out
  new_session "$d"
  printf '{"kind":"done"}\n' > "$d/events/done-w1-t1.json"
  out=$(TMAXER_DIR=$d TMAXER_SOCK= bash "$HERE/../tmaxer" wait) || return 1
  [ "$(printf '%s' "$out" | jq -r .kind)" = done ] && [ -f "$d/consumed/done-w1-t1.json" ] && [ -z "$(events_in "$d")" ]
}

test_wait_without_events_fails() {
  local d="$TMP/wait-empty"
  new_session "$d"
  if TMAXER_DIR=$d TMAXER_SOCK= bash "$HERE/../tmaxer" wait >/dev/null 2>&1; then return 1; fi
  return 0
}

test_up_validates_n() {
  if bash "$HERE/../tmaxer" up 2 --repo "$TMP" >/dev/null 2>&1; then return 1; fi
  if bash "$HERE/../tmaxer" up 10 --repo "$TMP" >/dev/null 2>&1; then return 1; fi
  return 0
}

test_ctrl_d_orchestrator_ends_session() {
  local repo="$TMP/repo-ctrld"
  git init -q "$repo" || return 1
  echo hi > "$repo/README.md"
  git -C "$repo" add README.md && git -C "$repo" -c user.email=t@example.com -c user.name=test commit -qm init || return 1
  bash "$HERE/../tmaxer" up 3 --repo "$repo" --name tc >/dev/null || return 1
  tmux -L tmaxer-tc send-keys -t '%0' C-d
  for i in $(seq 1 30); do
    tmux -L tmaxer-tc has-session -t tmaxer-tc 2>/dev/null || break
    sleep 1
  done
  tmux -L tmaxer-tc has-session -t tmaxer-tc 2>/dev/null && { echo "session still running" >&2; return 1; }
  [ ! -d "$TMAXER_HOME/tc/wt/w1" ] || { echo "worktree kept" >&2; return 1; }
  [ "$(grep -c "tc/wt" "$COPILOT_HOME/config.json")" = 0 ] || { echo "trust entries kept" >&2; return 1; }
  return 0
}

test_up_refuses_reused_branch() {
  local repo="$TMP/repo-branch"
  git init -q "$repo" || return 1
  echo hi > "$repo/README.md"
  git -C "$repo" add README.md && git -C "$repo" -c user.email=t@example.com -c user.name=test commit -qm init || return 1
  git -C "$repo" branch tmaxer/zz/review || return 1
  if bash "$HERE/../tmaxer" up 3 --repo "$repo" --name zz >/dev/null 2>&1; then return 1; fi
  [ ! -d "$TMAXER_HOME/zz" ]
}

test_layout_pane_died_and_down() {
  local repo="$TMP/repo" pane panes trusted
  git init -q "$repo" || return 1
  echo hi > "$repo/README.md"
  git -C "$repo" add README.md && git -C "$repo" -c user.email=t@example.com -c user.name=test commit -qm init || return 1
  bash "$HERE/../tmaxer" up 4 --repo "$repo" --name tt >/dev/null || return 1
  panes=$(tmux -L tmaxer-tt list-panes -t tmaxer-tt | wc -l | tr -d ' ')
  [ "$panes" = 5 ] || { echo "expected 5 panes, got $panes" >&2; return 1; }
  [ "$(wc -l < "$TMAXER_HOME/tt/panes" | tr -d ' ')" = 5 ] || return 1
  trusted=$(python3 -c "import json; print(sum(1 for x in json.load(open('$COPILOT_HOME/config.json'))['trustedFolders'] if '/wt/' in x))")
  [ "$trusted" = 5 ] || { echo "expected 5 trusted worktrees, got $trusted" >&2; return 1; }
  pane=$(awk '$1 == "w1" {print $2}' "$TMAXER_HOME/tt/panes")
  tmux -L tmaxer-tt send-keys -t "$pane" C-c
  sleep 3
  ls "$TMAXER_HOME/tt/events" | grep -q '^pane-died-w1-' || { echo "no pane-died event" >&2; return 1; }
  grep -q "Session: open" "$TMAXER_HOME/tt/orchestrator-prompt.md" || { echo "no goal prompt" >&2; return 1; }
  bash "$HERE/../tmaxer" down --name tt >/dev/null || return 1
  [ ! -d "$TMAXER_HOME/tt" ] && ls "$TMAXER_HOME"/archive/ | grep -q "^tt-" && [ ! -d "$TMAXER_HOME/tt/wt/w1" ] && ! tmux -L tmaxer-tt has-session -t tmaxer-tt 2>/dev/null
}

check "grid columns for 3, 4, 6, 7, 9 workers" test_grid
check "scope file accepts valid rules" test_scope_accepts
check "scope file rejects unsafe rules" test_scope_rejects
check "hard-deny patterns" test_hard_deny
check "in_scope matches commands and paths" test_in_scope
check "gate allows read-only tools without events" test_gate_read_only
check "gate allows in-scope shell without events" test_gate_in_scope
check "gate allows in-scope writes without events" test_gate_write_in_scope
check "gate denies hard-deny commands without events" test_gate_hard_deny_no_event
check "orchestrator launcher allows writes to scope files" test_launcher_allows_scope_files
check "launchers pass wrapper arguments through" test_launcher_accepts_wrapper_arguments
check "up rejects a missing agent command" test_up_rejects_missing_agent
check "gate lets a worker read its task and write its own result" test_gate_own_protocol_paths
check "gate asks before another worker's result path" test_gate_other_worker_result_asks
check "gate asks the orchestrator for chained commands" test_gate_chained_asks
check "gate returns the orchestrator's deny reason" test_gate_approval_deny_reason
check "gate refuses repeats of denied commands" test_gate_repeat_denied_no_event
check "gate denies at its deadline" test_gate_timeout_denies
check "agent-stop allows when no task is active" test_stop_idle_allows
check "agent-stop blocks until a result exists" test_stop_blocks_without_result
check "agent-stop emits done for status: done" test_stop_done_event
check "agent-stop emits blocked for status: blocked" test_stop_blocked_status
check "agent-stop emits blocked when forced without a result" test_stop_forced_no_result_emits_blocked
check "send writes a task and refuses a busy worker" test_send_then_refuses_busy
check "send rejects unsafe scope files" test_send_rejects_bad_scope
check "decide writes an atomic decision file" test_decide_writes_decision
check "wait prints and consumes queued events" test_wait_drains_events
check "wait fails when nothing is queued" test_wait_without_events_fails
check "up rejects N outside 3..9" test_up_validates_n
check "up refuses a branch name left by an earlier session" test_up_refuses_reused_branch
check "tmux layout, trust, pane-died event, and down" test_layout_pane_died_and_down
check "Ctrl-D in the orchestrator ends the whole session" test_ctrl_d_orchestrator_ends_session

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
