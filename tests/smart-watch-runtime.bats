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
  export STAMP_FILE="$BATS_TEST_TMPDIR/sleeptime"
  echo 1000 >"$STAMP_FILE"
  mkdir -p "$BUSY_DIR" "$CLAUDE_PROJECTS_DIR/proj"
  {
    harness_preamble
    echo 'BUSY_DIR="'"$BUSY_DIR"'"'
    echo 'STAMP_FILE="'"$STAMP_FILE"'"'
    echo 'CLAUDE_PROJECTS_DIR="'"$CLAUDE_PROJECTS_DIR"'"'
    echo 'AGENT_ACTIVITY_DIRS=("'"$CLAUDE_PROJECTS_DIR"'")'
    echo 'SMART_IDLE_SECONDS=2'
    echo 'SMART_STALE_MARKER_MINS=15'
    echo 'SMART_TIMEOUT_SECS=0'
    echo 'TIMEOUT_HOURS=6'
    echo 'USE_SPINNER=false'
    echo 'USE_BUILTIN_SLEEP=false'
    echo 'LOG_ENABLED=false'
    echo 'CPU_GUARD=false'
    echo 'AGENT_CPU_BUSY_PCT=20'
    echo 'AGENT_CPU_BUSY_SAMPLES=2'
    echo 'AGENT_PROCESS_NAMES=(claude codex)'
    echo 'BOLD="" DIM="" GREEN="" YELLOW="" CYAN="" RESET=""'
    echo 'print_ok()   { echo "OK $1"; }'
    echo 'print_warn() { echo "WARN $1"; }'
    echo 'clear_line() { :; }'
    echo 'log_event()  { :; }'
    echo 'micro_sleep(){ sleep "$1"; }'
    echo 'sleep_stamp() { cat "$STAMP_FILE" 2>/dev/null; }'
    sed -n '/^elapsed_label() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
    sed -n '/^transcript_for_session() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
    sed -n '/^transcript_active_within() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
    sed -n '/^newest_agent_activity() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
    sed -n '/^agent_cpu_centiseconds() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
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

@test "continuing agent output blocks sleep even with no marker present" {
  # The hooks-are-broken safety net. No marker exists, so a
  # marker-only watcher would sleep immediately; it is the stream of
  # writes that has to hold it off. Keep writing for longer than the
  # idle window and the loop must never conclude.
  local f="$CLAUDE_PROJECTS_DIR/proj/unmarked.jsonl"
  echo '{}' >"$f"
  (
    local i=0
    while ((i < 16)); do
      echo '{}' >>"$f"
      sleep 0.5
      i=$((i + 1))
    done
  ) &
  local writer_pid=$!
  drive_loop_bg "$BATS_TEST_TMPDIR/out"
  sleep 6
  stop_loop
  kill "$writer_pid" 2>/dev/null || true
  wait "$writer_pid" 2>/dev/null || true
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
  # Drive the real binary with the documented env knob rather than
  # sed-patching a copy of it: the copy has to be re-taught the source
  # layout every time that line moves, and it tests a file that is not
  # the one users run.
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

  run env SAC_IDLE_SECONDS=1 bash "$REPO_ROOT/sleep-after-claude" \
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

@test "a Mac that slept on its own stands the watcher down instead of re-sleeping it" {
  # Lid closed at midnight, opened at nine. The wall clock kept running
  # through the suspension, so without this the timeout branch fires
  # instantly and puts the machine straight back to sleep in your hands.
  touch "$BUSY_DIR/still-busy"
  echo '{}' >"$CLAUDE_PROJECTS_DIR/proj/still-busy.jsonl"
  (sleep 2 && echo 2000 >"$STAMP_FILE") &
  local bump_pid=$!
  run drive_loop
  wait "$bump_pid" 2>/dev/null || true
  assert_contains "$output" "slept while goodnight was watching"
  assert_contains "$output" "LOOP_RETURNED rc=3"
}

@test "an unchanged sleep stamp does not stand the watcher down" {
  run drive_loop
  assert_not_contains "$output" "slept while goodnight was watching"
  assert_contains "$output" "LOOP_RETURNED rc=0"
}

@test "the session-log scan is skipped while a marker already says busy" {
  # The scan stats every session log under every activity root, and
  # those accumulate forever. It must not run when its answer cannot
  # change the outcome.
  block="$(sed -n '/^smart_watch_loop() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude")"
  assert_contains "$block" 'if [[ "$busy" != "0" ]]; then'
  assert_contains "$block" 'last_activity=$now'
  assert_contains "$block" 'activity_ts="$(newest_agent_activity)"'
}

@test "sleep follows ONE idle window after the last write, not two" {
  # The boolean "was anything written recently" check only went false
  # once a log had already been quiet for a full --idle, and the
  # countdown then started from there — so the wait was ~2x--idle.
  # With SMART_IDLE_SECONDS=2, a log written at T must sleep near T+2,
  # not near T+4.
  echo '{}' >"$CLAUDE_PROJECTS_DIR/proj/recent.jsonl"
  local t0 t1 elapsed
  t0=$(date +%s)
  run drive_loop
  t1=$(date +%s)
  elapsed=$((t1 - t0))
  [ "$status" -eq 0 ]
  assert_contains "$output" "LOOP_RETURNED rc=0"
  # Generous ceiling; the doubled behaviour took >=4s plus poll slack.
  [ "$elapsed" -lt 4 ]
}

@test "an agent burning CPU holds the watch open with no marker and no writes" {
  # The Codex case: a long tool call that writes nothing while it runs.
  # Marker directory empty, session logs untouched — only CPU says work
  # is happening, and that has to be enough to stay awake.
  local ticker="$BATS_TEST_TMPDIR/cpu_ticks"
  echo 0 >"$ticker"
  shim pgrep 'echo 4242'
  # Each sample reports 10 more CPU-seconds than the last: far above the
  # 20%-of-a-core threshold, so every tick reads as busy.
  shim ps "n=\$(cat '$ticker'); n=\$((n + 10)); echo \$n >'$ticker'; printf ' 0:%02d.00\\n' \$n"
  # A longer idle window here so the two-sample debounce occupies the
  # same small fraction of it that it does in production (10s of 300),
  # rather than all of it.
  run bash -c "
    source '$BATS_TEST_TMPDIR/loop.sh'
    CPU_GUARD=true
    SMART_IDLE_SECONDS=6
    smart_watch_loop &
    lp=\$!
    sleep 12
    kill \$lp 2>/dev/null
    wait \$lp 2>/dev/null
    echo DONE
  "
  assert_not_contains "$output" "All agents idle"
  assert_contains "$output" "DONE"
}

@test "an idle agent does not hold the watch open" {
  # Same shape, but cumulative CPU barely moves — the measured idle
  # floor is ~5% of a core, well under the threshold. This must still
  # sleep, or the guard would simply never let the machine rest.
  shim pgrep 'echo 4242'
  shim ps "printf ' 0:10.00\\n'"
  run bash -c "
    source '$BATS_TEST_TMPDIR/loop.sh'
    CPU_GUARD=true
    smart_watch_loop
    echo \"LOOP_RETURNED rc=\$?\"
  "
  assert_contains "$output" "All agents idle"
  assert_contains "$output" "LOOP_RETURNED rc=0"
}
