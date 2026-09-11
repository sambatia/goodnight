#!/usr/bin/env bats
# Blocker classification + termination-prompt tests.

load 'lib/common'

setup() {
  setup_sandbox
  # Extract the classifier + its helpers in isolation, under the shell
  # options the real script runs with.
  harness_preamble > "$BATS_TEST_TMPDIR/classify.sh"
  sed -n '/^SYSTEM_MANAGED_BLOCKERS_REGEX=/p' "$REPO_ROOT/sleep-after-claude" >> "$BATS_TEST_TMPDIR/classify.sh"
  sed -n '/^LAUNCHD_SERVICE_PIDS=""$/,/^}$/p' "$REPO_ROOT/sleep-after-claude" >> "$BATS_TEST_TMPDIR/classify.sh"
  local fn
  for fn in launchd_manages_pid classify_blocker system_blocker_hint; do
    sed -n "/^${fn}() {\$/,/^}\$/p" "$REPO_ROOT/sleep-after-claude" >> "$BATS_TEST_TMPDIR/classify.sh"
  done
  grep -q '^classify_blocker() {' "$BATS_TEST_TMPDIR/classify.sh"
  grep -q '^cache_launchd_services() {' "$BATS_TEST_TMPDIR/classify.sh"
  grep -q '^launchd_manages_pid() {' "$BATS_TEST_TMPDIR/classify.sh"

  # A launchd inventory in the real `launchctl list` shape: a header,
  # a registered-but-idle service, two supervised services, and a
  # user-launched app (which carries an `application.` label).
  # The columns are tab-separated, as launchctl really emits them — awk
  # splits on whitespace, so a fixture using a literal backslash-t
  # yields zero matching pids and every assertion below passes without
  # testing anything.
  shim launchctl "cat <<'LIST'
PID	Status	Label
-	0	com.apple.AddressBook.AssistantService
1319	0	com.apple.AddressBook.SourceSync
663	0	com.apple.sharingd
76197	0	application.com.spotify.client.138353159.138353956
LIST"
}

# Report every pid as owned by the current user. Scoped to the tests
# that need it: shadowing `ps` for the whole file would also blind
# caffeinate_is_releasable, which consults the real process table.
shim_ps_owner_is_me() {
  shim ps "echo '$(id -un)'"
}

classify() {
  bash -c "source '$BATS_TEST_TMPDIR/classify.sh'; classify_blocker \"\$@\"" _ "$@"
}

@test "classify_blocker: cameracaptured is system-managed" {
  run classify cameracaptured
  [ "$status" -eq 0 ]
  [ "$output" = "system" ]
}

@test "classify_blocker: user apps like zoom are user-killable" {
  run classify 'zoom.us'
  [ "$output" = "user" ]
  run classify Discord
  [ "$output" = "user" ]
  run classify Slack
  [ "$output" = "user" ]
}

@test "classify_blocker: launchd and kernel_task are system-managed" {
  run classify launchd
  [ "$output" = "system" ]
  run classify kernel_task
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

# ── Structural classification ─────────────────────────────────
# A name list only ever knows the daemons that have already caused a
# bad run. These tests pin the properties that make a blocker
# un-terminable, so a daemon nobody has met yet is still classified
# correctly the first time it holds an assertion.

@test "AddressBookSourceSync is system-managed once its pid is known" {
  # The regression: goodnight offered to terminate a launchd-supervised
  # Contacts sync daemon under "User apps — These can be terminated by
  # goodnight." Killing it accomplishes nothing; launchd respawns it.
  shim_ps_owner_is_me
  run classify AddressBookSourceSync 1319
  [ "$status" -eq 0 ]
  [ "$output" = "system" ]
}

@test "a launchd service is system-managed even under an unknown name" {
  # This is the whole point of asking launchd instead of a name list.
  shim_ps_owner_is_me
  run classify someDaemonNobodyHasMetYet 663
  [ "$output" = "system" ]
}

@test "a user-launched app keeps its application label and stays terminable" {
  # launchctl lists apps too, as `application.<bundle-id>.<n>.<n>`.
  # Treating mere launchd membership as system-managed would make every
  # blocker un-terminable and the menu useless.
  shim_ps_owner_is_me
  run classify Spotify 76197
  [ "$output" = "user" ]
}

@test "a process owned by another user is system-managed" {
  # We cannot signal it, so offering to terminate it would be a lie.
  shim ps "echo root"
  run classify SomeRootDaemon 4242
  [ "$output" = "system" ]
}

@test "a pid that has already exited falls back to the name list" {
  # An empty owner means the process is gone. Guessing from a pid that
  # means nothing is worse than consulting the names we do know.
  shim ps "exit 1"
  run classify cameracaptured 999999
  [ "$output" = "system" ]
  run classify Discord 999999
  [ "$output" = "user" ]
}

@test "a non-numeric pid is ignored rather than fed to ps" {
  run classify Discord "not-a-pid"
  [ "$status" -eq 0 ]
  [ "$output" = "user" ]
}

@test "launchctl being unavailable degrades to the name list, not a crash" {
  shim_ps_owner_is_me
  shim launchctl 'exit 127'
  run classify Discord 76197
  [ "$status" -eq 0 ]
  [ "$output" = "user" ]
  run classify cameracaptured 76197
  [ "$output" = "system" ]
}

@test "the blocker loop passes the pid to the classifier" {
  # classify_blocker runs inside a command substitution; the pid is
  # what makes the structural checks possible at all. A caller that
  # keeps passing the name alone silently reverts this fix.
  block="$(sed -n '/^prompt_and_handle_blockers() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude")"
  assert_contains "$block" 'classify_blocker "$name" "$pid"'
  # The launchd cache must be warmed outside the substitution: a global
  # assigned in a subshell dies with it.
  assert_contains "$block" 'cache_launchd_services'
  # And invalidated first: the inventory must be newer than the scan
  # that produced these pids.
  assert_contains "$block" 'LAUNCHD_SERVICE_PIDS_CACHED=false'
}

@test "a launchd service gets a hint that does not send the user hunting for an app" {
  # "quit the app that triggered this assertion" is useless advice for a
  # background sync daemon: there is no window to close.
  run bash -c "source '$BATS_TEST_TMPDIR/classify.sh'; system_blocker_hint AddressBookSourceSync 1319"
  [ "$status" -eq 0 ]
  assert_contains "$output" "launchd"
  assert_not_contains "$output" "quit the app"
}

@test "a system blocker with no launchd record keeps the generic hint" {
  run bash -c "source '$BATS_TEST_TMPDIR/classify.sh'; system_blocker_hint someNeverSeenDaemon 4242"
  [ "$status" -eq 0 ]
  assert_contains "$output" "quit the app"
}

@test "USER is resolved once so an unset USER cannot abort the run" {
  # Four call sites consult it, two of them `pgrep -u`. Under `set -u`
  # an unset USER aborts the script outright.
  run bash -c "
    $(harness_preamble)
    unset USER
    $(sed -n '/^USER=\"\${USER:-\$(id -un)}\"$/p' "$REPO_ROOT/sleep-after-claude")
    echo \"resolved=\$USER\""
  [ "$status" -eq 0 ]
  assert_contains "$output" "resolved=$(id -un)"
}

@test "the launchd inventory is rebuilt, not reused, on a second pass" {
  # A daemon that starts after the first inventory was taken must not be
  # classified from stale data. Observed for real: warming the cache
  # before kickstarting AddressBookSourceSync classified it as a
  # terminable user app.
  cat > "$BATS_TEST_TMPDIR/drive.sh" <<DRIVE
source '$BATS_TEST_TMPDIR/classify.sh'
# First pass: pid 5150 is not registered yet.
classify_blocker lateDaemon 5150
# The daemon registers; a caller that invalidates sees it.
printf '%s\\t0\\tcom.apple.lateDaemon\\n' 5150 >> "$BATS_TEST_TMPDIR/extra"
LAUNCHD_SERVICE_PIDS_CACHED=false
classify_blocker lateDaemon 5150
DRIVE
  : > "$BATS_TEST_TMPDIR/extra"
  shim_ps_owner_is_me
  shim launchctl "cat <<'LIST'
PID	Status	Label
663	0	com.apple.sharingd
LIST
cat '$BATS_TEST_TMPDIR/extra'"
  run bash "$BATS_TEST_TMPDIR/drive.sh"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "user" ]
  [ "${lines[1]}" = "system" ]
}
