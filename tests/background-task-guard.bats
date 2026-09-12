#!/usr/bin/env bats
# The fourth signal: Claude background commands still running.
#
# On 2026-09-12 goodnight began its countdown to sleep while a 519-test
# bats suite was still running. All three existing signals had gone
# quiet at once, and each was right by its own definition:
#
#   busy markers  — the agent ended its turn, so the Stop hook fired and
#                   the marker was cleared. Work continued anyway.
#   transcript    — no writes for 15m24s; the agent was blocked on the
#                   command rather than producing output.
#   agent CPU     — the work lived in thousands of short-lived children.
#                   Measured that night's shape: the busy tree accounted
#                   for 11% of a core against a 12% idle floor, so the
#                   busy case read *quieter than idle*. No threshold can
#                   separate those, which is why this guard exists
#                   instead of a tuned constant.
#
# Claude Code streams each background command to
# <tasks-dir>/<project>/<session>/tasks/<id>.output and terminates the
# file with "[exited with code N]" or "[killed]".

load 'lib/common'

setup() {
  setup_sandbox
  export TASKS_DIR="$BATS_TEST_TMPDIR/tasks-root"
  mkdir -p "$TASKS_DIR/-Users-sam/session-a/tasks"
  extract_from_script "$BATS_TEST_TMPDIR/tg.sh" running_background_tasks
  {
    echo 'TASK_GUARD=true'
    echo 'TIMEOUT_HOURS=6'
    echo "CLAUDE_TASKS_DIR=\"$TASKS_DIR\""
  } >>"$BATS_TEST_TMPDIR/tg.sh"
  grep -q '^running_background_tasks() {' "$BATS_TEST_TMPDIR/tg.sh"
}

task() {
  local name="$1" last="$2"
  printf 'some output\n%s' "$last" >"$TASKS_DIR/-Users-sam/session-a/tasks/${name}.output"
}

count() {
  bash -c "source '$BATS_TEST_TMPDIR/tg.sh'; running_background_tasks"
}

@test "a command still running is counted" {
  task still_going ""
  run count
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "a command that exited is not counted" {
  task finished '[exited with code 0]'
  run count
  [ "$output" = "0" ]
}

@test "a non-zero exit is still an exit" {
  task failed '[exited with code 127]'
  run count
  [ "$output" = "0" ]
}

@test "a killed command is not counted" {
  # Matching only the exit marker counts every killed task as running
  # forever. Six of seven unterminated files on the real machine were
  # killed ones, so this is the common case, not the edge.
  task gone '[killed]'
  run count
  [ "$output" = "0" ]
}

@test "running and finished tasks are counted independently" {
  task a '[exited with code 0]'
  task b ""
  task c '[killed]'
  task d ""
  run count
  [ "$output" = "2" ]
}

@test "an abandoned task file cannot hold the Mac awake forever" {
  # A session killed mid-command leaves a file with no terminator.
  # Without the cutoff, one of those would veto sleep every night from
  # then on. The bound is the hard timeout, which is the designed
  # backstop for every other wait path too.
  task orphan ""
  touch -t 202001010000 "$TASKS_DIR/-Users-sam/session-a/tasks/orphan.output"
  run count
  [ "$output" = "0" ]
}

@test "a long-running task is not mistaken for an abandoned one" {
  # The case that started this: a suite that runs for many minutes is
  # well inside the timeout and must still count.
  task slow ""
  touch -t "$(date -v-30M +%Y%m%d%H%M)" "$TASKS_DIR/-Users-sam/session-a/tasks/slow.output"
  run count
  [ "$output" = "1" ]
}

@test "--no-task-guard disables the signal" {
  task still_going ""
  run bash -c "source '$BATS_TEST_TMPDIR/tg.sh'; TASK_GUARD=false; running_background_tasks"
  [ "$output" = "0" ]
}

@test "a missing tasks directory is zero, not an error" {
  run bash -c "source '$BATS_TEST_TMPDIR/tg.sh'; CLAUDE_TASKS_DIR=/nonexistent/nope; running_background_tasks"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "tasks across several sessions all count" {
  mkdir -p "$TASKS_DIR/-Users-sam-Projects-x/session-b/tasks"
  task one ""
  printf 'out\n' >"$TASKS_DIR/-Users-sam-Projects-x/session-b/tasks/two.output"
  run count
  [ "$output" = "2" ]
}

@test "the watch loop holds while a background task is running" {
  # The guard is worthless if the loop does not consult it on the path
  # that decides to sleep.
  block="$(sed -n '/^smart_watch_loop() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude")"
  assert_contains "$block" 'tasks="$(running_background_tasks)"'
  # A running task refreshes the activity clock,
  assert_contains "$block" '[[ "$busy" != "0" || "$tasks" != "0" ]]'
  # and the countdown branch requires it to be zero.
  assert_contains "$block" 'if [[ "$busy" == "0" && "$tasks" == "0" ]]; then'
}

@test "the reason shown to the user names background tasks" {
  block="$(sed -n '/^smart_watch_loop() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude")"
  assert_contains "$block" 'background task(s) running'
}

@test "the test sandbox isolates the tasks directory, not just HOME" {
  # Claude Code's task directory is machine-global (/tmp/claude-<uid>),
  # so isolating HOME leaves every end-to-end test reading the real one
  # — including the unterminated task file of the suite that is running.
  # That deadlocked the whole suite on the first end-to-end test: the
  # script waited forever on a background command that was the test run
  # itself. A harness that isolates one global but not another grades
  # production code under conditions production never sees.
  common="$(cat "$REPO_ROOT/tests/lib/common.bash")"
  assert_contains "$common" 'export SAC_CLAUDE_TASKS_DIR='
  [ -n "${SAC_CLAUDE_TASKS_DIR:-}" ]
  [ -d "$SAC_CLAUDE_TASKS_DIR" ]
  # And it must not be the real one.
  [[ "$SAC_CLAUDE_TASKS_DIR" != "/tmp/claude-$(id -u)" ]]
}

@test "the script honours SAC_CLAUDE_TASKS_DIR" {
  # Without this override there is no way to isolate the guard at all.
  block="$(grep -n 'CLAUDE_TASKS_DIR=' "$REPO_ROOT/sleep-after-claude" | head -1)"
  assert_contains "$block" 'SAC_CLAUDE_TASKS_DIR'
}
