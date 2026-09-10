#!/usr/bin/env bats
# F-07 regression tests — log_event warn-once behavior.
#
# These tests run the real sleep-after-claude `log_event` function in
# isolation by extracting it via awk. This keeps the test coupled to
# the real implementation (not a copy) and will fail if the extracted
# function drifts from the expected contract.

load 'lib/common'

setup() {
  setup_sandbox
  # Extract log_event and the rotation helper it calls, plus their
  # companion state flags. Pulled from the real script so the test
  # fails if the implementation drifts from the contract.
  {
    harness_preamble
    echo 'LOG_WRITE_FAILED=false'
    echo 'LOG_ROTATE_CHECKED=false'
    echo 'LOG_MAX_BYTES=2097152'
    sed -n '/^maybe_rotate_log() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
    sed -n '/^log_event() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
  } >"$BATS_TEST_TMPDIR/log_event.sh"
  # Sanity: must have extracted both functions.
  grep -q '^log_event() {' "$BATS_TEST_TMPDIR/log_event.sh"
  grep -q '^maybe_rotate_log() {' "$BATS_TEST_TMPDIR/log_event.sh"
}

@test "F-07: log_event writes successfully to a writable path" {
  logpath="$BATS_TEST_TMPDIR/ok.log"
  run bash -c "LOG_ENABLED=true LOG_FILE='$logpath'; source '$BATS_TEST_TMPDIR/log_event.sh'; log_event HELLO; log_event WORLD"
  [ "$status" -eq 0 ]
  [ -f "$logpath" ]
  run cat "$logpath"
  assert_contains "$output" "HELLO"
  assert_contains "$output" "WORLD"
}

@test "F-07: log_event warns exactly once on repeated write failures" {
  logpath="/nonexistent/readonly/dir/x.log"
  run bash -c "
    LOG_ENABLED=true LOG_FILE='$logpath'
    source '$BATS_TEST_TMPDIR/log_event.sh'
    log_event one
    log_event two
    log_event three
  " 2>&1
  [ "$status" -eq 0 ]
  # Exactly one occurrence of the warning.
  count="$(printf '%s\n' "$output" | grep -c 'log write failed:' || true)"
  [ "$count" -eq 1 ]
  assert_contains "$output" "subsequent failures will be silent"
}

@test "F-07: log_event produces no output when LOG_ENABLED=false" {
  # Note: log_event's return status when disabled is not part of its
  # contract — no caller checks it. We only assert that no user-visible
  # output is produced and no log file is created.
  logpath="$BATS_TEST_TMPDIR/disabled.log"
  run bash -c "
    LOG_ENABLED=false LOG_FILE='$logpath'
    source '$BATS_TEST_TMPDIR/log_event.sh'
    log_event whatever || true
  " 2>&1
  [ -z "$output" ]
  [ ! -f "$logpath" ]
}

@test "F-07: log_event suppresses the shell's own redirection error" {
  # The fix uses `{ echo ...; } 2>/dev/null` to catch bash's
  # "No such file or directory" error that it emits BEFORE the inner
  # 2>/dev/null takes effect. Verify no such raw error leaks through.
  logpath="/nonexistent/missing/dir/x.log"
  run bash -c "
    LOG_ENABLED=true LOG_FILE='$logpath'
    source '$BATS_TEST_TMPDIR/log_event.sh'
    log_event one
  " 2>&1
  assert_not_contains "$output" "No such file or directory"
}
