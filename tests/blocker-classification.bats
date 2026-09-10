#!/usr/bin/env bats
# Blocker classification + termination-prompt tests.

load 'lib/common'

setup() {
  setup_sandbox
  # Extract the classifier + hint functions in isolation.
  sed -n '/^SYSTEM_MANAGED_BLOCKERS_REGEX=/,/^}$/p' "$REPO_ROOT/sleep-after-claude" \
    | sed -n '1,/^}$/p' > "$BATS_TEST_TMPDIR/classify.sh"
  sed -n '/^classify_blocker() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude" >> "$BATS_TEST_TMPDIR/classify.sh"
  sed -n '/^system_blocker_hint() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude" >> "$BATS_TEST_TMPDIR/classify.sh"
  [ -s "$BATS_TEST_TMPDIR/classify.sh" ]
}

@test "classify_blocker: cameracaptured is system-managed" {
  run bash -c "source '$BATS_TEST_TMPDIR/classify.sh'; classify_blocker cameracaptured"
  [ "$status" -eq 0 ]
  [ "$output" = "system" ]
}

@test "classify_blocker: user apps like zoom are user-killable" {
  run bash -c "source '$BATS_TEST_TMPDIR/classify.sh'; classify_blocker 'zoom.us'"
  [ "$output" = "user" ]
  run bash -c "source '$BATS_TEST_TMPDIR/classify.sh'; classify_blocker Discord"
  [ "$output" = "user" ]
  run bash -c "source '$BATS_TEST_TMPDIR/classify.sh'; classify_blocker Slack"
  [ "$output" = "user" ]
}

@test "classify_blocker: launchd and kernel_task are system-managed" {
  run bash -c "source '$BATS_TEST_TMPDIR/classify.sh'; classify_blocker launchd"
  [ "$output" = "system" ]
  run bash -c "source '$BATS_TEST_TMPDIR/classify.sh'; classify_blocker kernel_task"
  [ "$output" = "system" ]
}

@test "system_blocker_hint: camera hint mentions quitting the camera app" {
  run bash -c "source '$BATS_TEST_TMPDIR/classify.sh'; system_blocker_hint cameracaptured"
  [ "$status" -eq 0 ]
  assert_contains "$output" "Camera"
  assert_contains "$output" "quit"
}

@test "system_blocker_hint: unknown name yields a generic guidance line" {
  run bash -c "source '$BATS_TEST_TMPDIR/classify.sh'; system_blocker_hint someNeverSeenDaemon"
  [ "$status" -eq 0 ]
  assert_contains "$output" "System-managed"
}

@test "runningboardd is treated as a benign system daemon, not a blocker" {
  # runningboardd holds PreventUserIdleSystemSleep as routine process
  # lifecycle bookkeeping and releases it at sleep time. Reporting it as
  # a blocker made every single run show a false alarm.
  run bash -c "
    $(harness_preamble)
    $(sed -n '/^SYSTEM_DAEMONS_REGEX=/p' "$REPO_ROOT/sleep-after-claude")
    [[ 'runningboardd' =~ \$SYSTEM_DAEMONS_REGEX ]] && echo SYSTEM || echo BLOCKER"
  assert_contains "$output" "SYSTEM"
}

@test "runningboardd is never offered as a terminable user app" {
  # It is root-owned and launchd-supervised: killing it would fail, and
  # macOS would respawn it anyway.
  run bash -c "
    $(harness_preamble)
    $(sed -n '/^SYSTEM_MANAGED_BLOCKERS_REGEX=/p' "$REPO_ROOT/sleep-after-claude")
    $(sed -n '/^classify_blocker() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude")
    classify_blocker runningboardd"
  [ "$output" = "system" ]
}

@test "system-managed blockers all carry an actionable hint" {
  for name in runningboardd powerd cameracaptured; do
    run bash -c "
      $(harness_preamble)
      $(sed -n '/^system_blocker_hint() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude")
      system_blocker_hint $name"
    [ -n "$output" ]
    assert_not_contains "$output" "System-managed — quit the app"
  done
}

@test "our own caffeinate holding PreventSystemSleep is releasable, not a blocker" {
  # `caffeinate -dims` holds exactly this assertion (the `s`), and
  # goodnight terminates it before sleeping. Calling it un-releasable
  # fired a red "releasing caffeinate alone will not be sufficient"
  # panel on every run — while the blockers it listed *were* caffeinate.
  run bash -c "
    $(sed -n '/^caffeinate_is_releasable() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude")
    caffeinate_is_releasable \$\$ && echo YES || echo NO"
  assert_contains "$output" "YES"
  block="$(sed -n '/^scan_assertions() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude")"
  assert_contains "$block" 'caffeinate" ]] && caffeinate_is_releasable "$apid"'
}

@test "a live caffeinate owned by someone else stays a blocker" {
  # PID 1 is launchd, owned by root. It survives our kill, so it is
  # genuinely un-releasable.
  run bash -c "
    $(sed -n '/^caffeinate_is_releasable() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude")
    caffeinate_is_releasable 1 && echo YES || echo NO"
  assert_contains "$output" "NO"
}

@test "a caffeinate that already exited is clear, not an obstacle" {
  # It holds nothing and blocks nothing. Treating a process that died
  # between the pmset scan and this check as un-releasable would invent
  # a blocker that cannot be cleared because it is not there.
  run bash -c "
    $(sed -n '/^caffeinate_is_releasable() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude")
    caffeinate_is_releasable 999999 && echo YES || echo NO
    caffeinate_is_releasable 'bogus' && echo YES || echo NO"
  assert_not_contains "$output" "NO"
}

@test "the unattended blocker message says why it did not ask" {
  # "No one to prompt" is confusing when the user is at the keyboard
  # watching: they passed a flag meaning "do not ask me".
  block="$(sed -n '/^prompt_and_handle_blockers() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude")"
  assert_contains "$block" 'not asking because'
  assert_contains "$block" 'reason=flag'
  assert_contains "$block" 'no TTY to prompt on'
  assert_contains "$block" 'reason=no-tty'
}
