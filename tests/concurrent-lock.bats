#!/usr/bin/env bats
# F-07 regression tests — concurrent-run lock.

load 'lib/common'

setup() {
  setup_sandbox
  export GOODNIGHT_LOCK_DIR="$HOME/.local/state/goodnight/lock"
  # Extract the lock helpers in isolation.
  {
    harness_preamble
    echo 'GOODNIGHT_LOCK_DIR="'"$GOODNIGHT_LOCK_DIR"'"'
    echo 'GOODNIGHT_LOCK_ACQUIRED=false'
    echo 'BOLD="" RESET=""'
    echo 'print_error() { echo "ERR $1" >&2; }'
    echo 'print_step()  { echo "STEP $1"; }'
    echo 'print_warn()  { echo "WARN $1"; }'
    sed -n '/^acquire_goodnight_lock() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
    sed -n '/^release_goodnight_lock() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
  } >"$BATS_TEST_TMPDIR/lock.sh"
  [ -s "$BATS_TEST_TMPDIR/lock.sh" ]
}

@test "F-07: first acquire succeeds and marks lock acquired" {
  run bash -c "source '$BATS_TEST_TMPDIR/lock.sh'; acquire_goodnight_lock && echo OK: \$GOODNIGHT_LOCK_ACQUIRED"
  [ "$status" -eq 0 ]
  assert_contains "$output" "OK: true"
  [ -d "$GOODNIGHT_LOCK_DIR" ]
  [ -f "$GOODNIGHT_LOCK_DIR/pid" ]
}

@test "F-07: second acquire fails while first holder is alive" {
  # Create the lock with the current shell's PID (guaranteed alive)
  mkdir -p "$GOODNIGHT_LOCK_DIR"
  echo $$ >"$GOODNIGHT_LOCK_DIR/pid"
  run bash -c "source '$BATS_TEST_TMPDIR/lock.sh'; acquire_goodnight_lock; echo rc=\$?"
  assert_contains "$output" "Another goodnight is already running"
  assert_contains "$output" "rc=1"
}

@test "F-07: stale lock (dead holder PID) is reclaimed" {
  # Fabricate a lock with a PID that's guaranteed dead.
  mkdir -p "$GOODNIGHT_LOCK_DIR"
  echo "999999" >"$GOODNIGHT_LOCK_DIR/pid"
  run bash -c "source '$BATS_TEST_TMPDIR/lock.sh'; acquire_goodnight_lock && echo OK"
  [ "$status" -eq 0 ]
  assert_contains "$output" "Stale lock"
  assert_contains "$output" "reclaiming"
  assert_contains "$output" "OK"
}

@test "F-07: release_goodnight_lock removes the lock dir" {
  run bash -c "
    source '$BATS_TEST_TMPDIR/lock.sh'
    acquire_goodnight_lock
    [ -d '$GOODNIGHT_LOCK_DIR' ] || exit 2
    release_goodnight_lock
    [ ! -d '$GOODNIGHT_LOCK_DIR' ] && echo RELEASED
  "
  assert_contains "$output" "RELEASED"
}

@test "F-07: release is a no-op if lock wasn't acquired by this instance" {
  # Another process's lock must NOT be removed by release().
  mkdir -p "$GOODNIGHT_LOCK_DIR"
  echo "999999" >"$GOODNIGHT_LOCK_DIR/pid"
  run bash -c "
    source '$BATS_TEST_TMPDIR/lock.sh'
    # We did NOT call acquire_goodnight_lock, so GOODNIGHT_LOCK_ACQUIRED=false
    release_goodnight_lock
    [ -d '$GOODNIGHT_LOCK_DIR' ] && echo STILL_LOCKED
  "
  assert_contains "$output" "STILL_LOCKED"
}

@test "F-07: source contains acquire_goodnight_lock call in smart_watch entry" {
  # Source-level contract: smart-watch entry must guard itself with
  # the lock before starting smart_watch_loop.
  run grep -B6 -A1 'log_event "SMART_WATCH_START' "$REPO_ROOT/sleep-after-claude"
  assert_contains "$output" "acquire_goodnight_lock"
}

@test "F-07: cleanup trap releases the lock" {
  run grep -A6 '^cleanup_fd_and_tmp() {' "$REPO_ROOT/sleep-after-claude"
  assert_contains "$output" "release_goodnight_lock"
}
