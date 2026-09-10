#!/usr/bin/env bats
# `pmset sleepnow` exits 0 whether or not the Mac actually sleeps: if
# anything holds a PreventSystemSleep assertion, macOS declines and
# pmset still reports success. The old code took that 0 at face value,
# printed "Good night", and exited clean while the machine stayed awake
# all night leaving no trace.
#
# attempt_sleep confirms the outcome against kern.sleeptime and retries.

load 'lib/common'

setup() {
  setup_sandbox
  export STAMP_FILE="$BATS_TEST_TMPDIR/sleeptime"
  export CALLS="$BATS_TEST_TMPDIR/calls"
  echo 1000 >"$STAMP_FILE"
  : >"$CALLS"

  {
    echo 'SLEEP_MAX_ATTEMPTS=3'
    echo 'SLEEP_VERIFY_SECS=1'
    echo 'SLEEP_RETRY_BACKOFF_SECS=0'
    echo 'LOG_ENABLED=false'
    echo 'BOLD="" DIM="" RESET="" YELLOW="" RED=""'
    echo 'PREFLIGHT_BLOCKERS=()'
    echo 'log_event()       { :; }'
    echo 'print_warn()      { echo "WARN $1"; }'
    echo 'scan_assertions() { :; }'
    sed -n '/^sleep_stamp() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
    sed -n '/^wake_stamp() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
    sed -n '/^release_all_caffeinate() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
    sed -n '/^attempt_sleep() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
  } >"$BATS_TEST_TMPDIR/sleepfns.sh"
  grep -q '^attempt_sleep() {' "$BATS_TEST_TMPDIR/sleepfns.sh"

  # sysctl reports whatever the stamp file currently holds, in the real
  # `{ sec = N, usec = M } <date>` shape so the parser is exercised.
  shim sysctl "printf '{ sec = %s, usec = 123 } Wed Sep  9 11:40:36 2026\n' \"\$(cat '$STAMP_FILE')\""
  shim pgrep 'exit 1'
  shim osascript 'exit 0'
}

run_attempt() {
  bash -c "source '$BATS_TEST_TMPDIR/sleepfns.sh'; attempt_sleep test; echo RC=\$?"
}

@test "a sleep that really happens is confirmed on the first attempt" {
  # pmset succeeds and the kernel's sleep timestamp advances.
  shim pmset "echo call >>'$CALLS'; echo 2000 >'$STAMP_FILE'; exit 0"
  run run_attempt
  assert_contains "$output" "RC=0"
  [ "$(wc -l <"$CALLS" | tr -d ' ')" = "1" ]
}

@test "a refused sleep is detected and retried, then reported as failure" {
  # pmset returns 0 — as it does when an assertion blocks sleep — but
  # the kernel timestamp never moves. Taking that exit code at face
  # value is the exact bug this guards.
  shim pmset "echo call >>'$CALLS'; exit 0"
  run run_attempt
  assert_contains "$output" "RC=1"
  assert_contains "$output" "Sleep was refused"
  [ "$(wc -l <"$CALLS" | tr -d ' ')" = "3" ]
}

@test "a sleep that succeeds on retry returns success" {
  # First call refused, second works — the machine was busy, then free.
  shim pmset "
    n=\$(wc -l <'$CALLS' | tr -d ' ')
    echo call >>'$CALLS'
    if [ \"\$n\" -ge 1 ]; then echo 2000 >'$STAMP_FILE'; fi
    exit 0
  "
  run run_attempt
  assert_contains "$output" "RC=0"
  [ "$(wc -l <"$CALLS" | tr -d ' ')" = "2" ]
}

@test "osascript is the fallback when pmset itself errors" {
  shim pmset "echo call >>'$CALLS'; exit 1"
  shim osascript "echo 2000 >'$STAMP_FILE'; exit 0"
  run run_attempt
  assert_contains "$output" "RC=0"
}

@test "attempt count honours SLEEP_MAX_ATTEMPTS" {
  shim pmset "echo call >>'$CALLS'; exit 0"
  run bash -c "
    source '$BATS_TEST_TMPDIR/sleepfns.sh'
    SLEEP_MAX_ATTEMPTS=1
    attempt_sleep test
    echo RC=\$?"
  assert_contains "$output" "RC=1"
  [ "$(wc -l <"$CALLS" | tr -d ' ')" = "1" ]
}

@test "sleep_stamp parses the sysctl struct into a bare epoch second" {
  run bash -c "source '$BATS_TEST_TMPDIR/sleepfns.sh'; sleep_stamp"
  [ "$output" = "1000" ]
}

@test "an unreadable sysctl does not wedge the retry loop" {
  # Fail open to the clock-jump heuristic rather than looping forever
  # on an empty comparison.
  shim sysctl 'exit 1'
  shim pmset "echo call >>'$CALLS'; exit 0"
  run run_attempt
  assert_contains "$output" "RC=1"
  [ "$(wc -l <"$CALLS" | tr -d ' ')" = "3" ]
}
