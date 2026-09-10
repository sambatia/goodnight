#!/usr/bin/env bats
# Auto-start caffeinate -dim behavior.

load 'lib/common'

setup() {
  setup_sandbox
  # Extract the function + its config.
  {
    harness_preamble
    echo 'AUTO_STARTED_CAFFEINATE_PID=""'
    echo 'NO_AUTO_CAFFEINATE=false'
    sed -n '/^ensure_caffeinate_running() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
  } >"$BATS_TEST_TMPDIR/ensure.sh"
  [ -s "$BATS_TEST_TMPDIR/ensure.sh" ]
}

@test "ensure_caffeinate: no-op when --no-auto-caffeinate" {
  run bash -c "
    BOLD='' DIM='' GREEN='' RESET=''
    print_ok() { echo \"OK \$1\"; }
    log_event() { :; }
    source '$BATS_TEST_TMPDIR/ensure.sh'
    # Set AFTER sourcing — the sourced file re-initializes the default.
    NO_AUTO_CAFFEINATE=true
    ensure_caffeinate_running
    echo DONE
  " 2>&1
  [ "$status" -eq 0 ]
  assert_contains "$output" "DONE"
  assert_not_contains "$output" "Started"
  assert_not_contains "$output" "caffeinate already running"
}

@test "ensure_caffeinate: does not start a second one, and says the first will be released" {
  # It leaves a pre-existing caffeinate running for the duration of the
  # watch, but captures and terminates it at sleep time — it has to,
  # since that assertion is what blocks sleep. The message has to say
  # so, or the user believes a caffeinate they rely on is untouched.
  shim pgrep 'echo 99999; exit 0' # pretend something is already running
  run bash -c "
    NO_AUTO_CAFFEINATE=false
    BOLD='' DIM='' GREEN='' YELLOW='' RESET=''
    print_ok()   { echo \"OK \$1\"; }
    print_warn() { echo \"WARN \$1\"; }
    log_event() { :; }
    export PATH='$SHIM_DIR:'\$PATH
    source '$BATS_TEST_TMPDIR/ensure.sh'
    ensure_caffeinate_running
    echo DONE
  " 2>&1
  [ "$status" -eq 0 ]
  assert_contains "$output" "caffeinate already running"
  assert_contains "$output" "will release these before it sleeps"
  assert_not_contains "$output" "Started"
}

@test "ensure_caffeinate: starts caffeinate when none running" {
  shim pgrep 'exit 1'                # none found
  shim caffeinate 'sleep 30; exit 0' # a fake caffeinate that just sleeps
  run bash -c "
    NO_AUTO_CAFFEINATE=false
    BOLD='' DIM='' GREEN='' RESET=''
    print_ok() { echo \"OK \$1\"; }
    log_event() { echo \"log: \$1\"; }
    export PATH='$SHIM_DIR:'\$PATH
    source '$BATS_TEST_TMPDIR/ensure.sh'
    ensure_caffeinate_running
    echo \"pid=\$AUTO_STARTED_CAFFEINATE_PID\"
  " 2>&1
  [ "$status" -eq 0 ]
  assert_contains "$output" "Started"
  assert_contains "$output" "log: AUTO_CAFFEINATE_STARTED"
  # Cleanup the fake caffeinate we spawned
  pkill -f 'sleep 30' 2>/dev/null || true
}

@test "F-05: --dry-run does not kill captured caffeinate processes" {
  sleep 30 &
  local caff_pid=$!

  sleep 0.2 &
  local target_pid=$!

  shim pgrep "
    if [[ \"\$*\" == *caffeinate* ]]; then
      echo '$caff_pid'
      exit 0
    fi
    exit 1
  "

  run bash "$REPO_ROOT/sleep-after-claude" \
    --pid "$target_pid" \
    --no-preflight \
    --skip-update-check \
    --allow-battery \
    --dry-run \
    --no-auto-caffeinate \
    --no-sound

  [ "$status" -eq 0 ]
  assert_contains "$output" "Dry run complete"
  kill -0 "$caff_pid" 2>/dev/null

  kill "$caff_pid" 2>/dev/null || true
  wait "$caff_pid" 2>/dev/null || true
  wait "$target_pid" 2>/dev/null || true
}

@test "F-05: --dry-run does not auto-start caffeinate" {
  sleep 0.2 &
  local target_pid=$!
  local started_file="$BATS_TEST_TMPDIR/caffeinate-started"

  shim pgrep 'exit 1'
  shim caffeinate "echo started > '$started_file'; exit 0"

  run bash "$REPO_ROOT/sleep-after-claude" \
    --pid "$target_pid" \
    --no-preflight \
    --skip-update-check \
    --allow-battery \
    --dry-run \
    --no-sound

  [ "$status" -eq 0 ]
  assert_contains "$output" "Dry run complete"
  [ ! -e "$started_file" ]

  wait "$target_pid" 2>/dev/null || true
}

@test "F-05: --sleep-now --dry-run does not release caffeinate or call pmset sleepnow" {
  sleep 30 &
  local caff_pid=$!
  local pmset_file="$BATS_TEST_TMPDIR/pmset-called"

  shim pgrep "
    if [[ \"\$*\" == *caffeinate* ]]; then
      echo '$caff_pid'
      exit 0
    fi
    exit 1
  "
  shim pmset "echo \"\$*\" > '$pmset_file'; exit 0"

  run bash "$REPO_ROOT/sleep-after-claude" \
    --sleep-now \
    --no-preflight \
    --skip-update-check \
    --allow-battery \
    --dry-run \
    --no-sound

  [ "$status" -eq 0 ]
  assert_contains "$output" "Dry run complete"
  kill -0 "$caff_pid" 2>/dev/null
  [ ! -e "$pmset_file" ]

  kill "$caff_pid" 2>/dev/null || true
  wait "$caff_pid" 2>/dev/null || true
}
