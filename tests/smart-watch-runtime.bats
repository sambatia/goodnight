#!/usr/bin/env bats
# Behavioural tests: these actually drive smart_watch_loop against a
# scripted marker directory and transcript tree.
#
# Speed strategy: SMART_IDLE_SECONDS=2 so the countdown completes
# promptly. Transcript checks use find -mmin, whose floor is one
# minute, so tests that need "quiet" simply keep the transcript tree
# empty or backdated.

load 'lib/common'

setup() {
  setup_sandbox
  export BUSY_DIR="$HOME/.local/state/goodnight/busy"
  export CLAUDE_PROJECTS_DIR="$HOME/.claude/projects"
  mkdir -p "$BUSY_DIR" "$CLAUDE_PROJECTS_DIR/proj"
  {
    echo 'BUSY_DIR="'"$BUSY_DIR"'"'
    echo 'CLAUDE_PROJECTS_DIR="'"$CLAUDE_PROJECTS_DIR"'"'
    echo 'AGENT_ACTIVITY_DIRS=("'"$CLAUDE_PROJECTS_DIR"'")'
    echo 'SMART_IDLE_SECONDS=2'
    echo 'SMART_STALE_MARKER_MINS=15'
    echo 'SMART_TIMEOUT_SECS=0'
    echo 'TIMEOUT_HOURS=6'
    echo 'USE_SPINNER=false'
    echo 'USE_BUILTIN_SLEEP=false'
    echo 'LOG_ENABLED=false'
    echo 'BOLD="" DIM="" GREEN="" YELLOW="" CYAN="" RESET=""'
    echo 'print_ok()   { echo "OK $1"; }'
    echo 'print_warn() { echo "WARN $1"; }'
    echo 'clear_line() { :; }'
    echo 'log_event()  { :; }'
    echo 'micro_sleep(){ sleep "$1"; }'
    sed -n '/^elapsed_label() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
    sed -n '/^transcript_for_session() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
    sed -n '/^transcript_active_within() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
    sed -n '/^reap_dead_markers() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
    sed -n '/^count_busy_sessions() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
    sed -n '/^smart_watch_loop() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
  } >"$BATS_TEST_TMPDIR/loop.sh"
  [ -s "$BATS_TEST_TMPDIR/loop.sh" ]
}

drive_loop() {
  bash -c "
    source '$BATS_TEST_TMPDIR/loop.sh'
    smart_watch_loop
    echo \"LOOP_RETURNED rc=\$?\"
  "
}

# Background the loop and capture the PID of the loop process itself.
# Backgrounding a function call instead would fork a subshell and leave
# $! pointing at the wrapper, so the kill would miss the real child and
# bats would block forever waiting on an inherited pipe.
drive_loop_bg() {
  bash -c "
    source '$BATS_TEST_TMPDIR/loop.sh'
    smart_watch_loop
    echo \"LOOP_RETURNED rc=\$?\"
  " >"$1" 2>&1 &
  LOOP_PID=$!
}

stop_loop() {
  kill "$LOOP_PID" 2>/dev/null || true
  wait "$LOOP_PID" 2>/dev/null || true
}

@test "starting quiet sleeps after the idle window (no cold-start hold)" {
  # The headline behaviour change. Every agent already finished before
  # goodnight was invoked — the overwhelmingly common case — and the
  # old loop hung here indefinitely.
  run drive_loop
  [ "$status" -eq 0 ]
  assert_contains "$output" "All agents idle"
  assert_contains "$output" "LOOP_RETURNED rc=0"
}

@test "a busy marker blocks sleep until it clears" {
  touch "$BUSY_DIR/session-1"
  (sleep 1 && rm -f "$BUSY_DIR/session-1") &
  local cleanup_pid=$!
  run drive_loop
  wait "$cleanup_pid" 2>/dev/null || true
  [ "$status" -eq 0 ]
  assert_contains "$output" "All agents idle"
  assert_contains "$output" "LOOP_RETURNED rc=0"
}

@test "a marker that never clears does NOT sleep the machine" {
  # Corollary of the above: while a session is genuinely working, the
  # loop must stay put. Its transcript is fresh, so it is not reaped.
  touch "$BUSY_DIR/busy-forever"
  echo '{}' >"$CLAUDE_PROJECTS_DIR/proj/busy-forever.jsonl"
  drive_loop_bg "$BATS_TEST_TMPDIR/out"
  sleep 6
  stop_loop
  run cat "$BATS_TEST_TMPDIR/out"
  assert_not_contains "$output" "All agents idle"
  assert_not_contains "$output" "LOOP_RETURNED"
}

@test "recent agent output blocks sleep even with no marker present" {
  # The hooks-are-broken safety net. No marker exists, so a
  # marker-only watcher would sleep immediately; the transcript write
  # is what stops it.
  echo '{}' >"$CLAUDE_PROJECTS_DIR/proj/unmarked.jsonl"
  drive_loop_bg "$BATS_TEST_TMPDIR/out"
  sleep 5
  stop_loop
  run cat "$BATS_TEST_TMPDIR/out"
  assert_not_contains "$output" "LOOP_RETURNED"
}

@test "a stalled session is reaped and stops blocking sleep" {
  # Marker present, transcript silent well past the stale window: a
  # crash, or a session waiting on a permission prompt. Under the old
  # 24h reaper this pinned the Mac awake all night.
  touch "$BUSY_DIR/stalled"
  echo '{}' >"$CLAUDE_PROJECTS_DIR/proj/stalled.jsonl"
  touch -t "$(date -v-45M +%Y%m%d%H%M)" "$CLAUDE_PROJECTS_DIR/proj/stalled.jsonl"
  run drive_loop
  [ "$status" -eq 0 ]
  assert_contains "$output" "All agents idle"
  [ ! -f "$BUSY_DIR/stalled" ]
}

@test "the hard timeout fires even while a session is still busy" {
  touch "$BUSY_DIR/never-finishes"
  echo '{}' >"$CLAUDE_PROJECTS_DIR/proj/never-finishes.jsonl"
  run bash -c "
    source '$BATS_TEST_TMPDIR/loop.sh'
    SMART_TIMEOUT_SECS=3
    smart_watch_loop
    echo \"LOOP_RETURNED rc=\$?\"
  "
  assert_contains "$output" "Timeout of 6h reached"
  assert_contains "$output" "LOOP_RETURNED rc=2"
}

@test "smart mode runs end to end and reaches the sleep step" {
  sed 's/^SMART_IDLE_SECONDS="\${SAC_IDLE_SECONDS:-300}"/SMART_IDLE_SECONDS="${SAC_IDLE_SECONDS:-1}"/' \
    "$REPO_ROOT/sleep-after-claude" >"$BATS_TEST_TMPDIR/sac-fast"
  chmod +x "$BATS_TEST_TMPDIR/sac-fast"
  grep -q 'SAC_IDLE_SECONDS:-1' "$BATS_TEST_TMPDIR/sac-fast"

  mkdir -p "$HOME/.claude"
  cat >"$HOME/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "UserPromptSubmit": [
      { "matcher": "", "_managed_by": "goodnight",
        "hooks": [{ "type": "command", "command": "true # goodnight-hook" }] }
    ],
    "Stop": [
      { "matcher": "", "_managed_by": "goodnight",
        "hooks": [{ "type": "command", "command": "true # goodnight-hook" }] }
    ]
  }
}
JSON

  shim pgrep 'exit 1'
  touch "$BUSY_DIR/session-1"
  (sleep 1 && rm -f "$BUSY_DIR/session-1") &
  local cleanup_pid=$!

  run bash "$BATS_TEST_TMPDIR/sac-fast" \
    --smart \
    --no-preflight \
    --allow-battery \
    --dry-run \
    --no-repair \
    --no-log \
    --no-auto-caffeinate \
    --no-sound
  wait "$cleanup_pid" 2>/dev/null || true

  [ "$status" -eq 0 ]
  assert_contains "$output" "Dry run complete"
  assert_not_contains "$output" "PID smart not found"
}
