#!/usr/bin/env bats
# The one gap the session-log signal cannot cover: an agent with no busy
# marker — Codex — running a long tool call that writes nothing while it
# runs. A build burns CPU even when it is silent, so CPU delta closes it.
#
# The signal is a veto only. An agent blocked on a network round trip
# burns no CPU while genuinely working, so CPU is sound as a reason to
# stay awake and useless as a reason to sleep. The hard --timeout bounds
# the veto so it can never wedge the watch.

load 'lib/common'

setup() {
  setup_sandbox
  extract_from_script "$BATS_TEST_TMPDIR/cpu.sh" agent_cpu_centiseconds
}

@test "no agent processes reports zero rather than failing" {
  shim pgrep 'exit 1'
  run bash -c "source '$BATS_TEST_TMPDIR/cpu.sh'; agent_cpu_centiseconds"
  [ "$output" = "0" ]
}

@test "cumulative CPU is summed across every agent process" {
  shim pgrep 'echo 101; echo 102'
  # 0:10.00 and 0:05.00 -> 15s -> 1500 centiseconds
  shim ps 'printf "  0:10.00\n  0:05.00\n"'
  run bash -c "source '$BATS_TEST_TMPDIR/cpu.sh'; agent_cpu_centiseconds"
  [ "$output" = "1500" ]
}

@test "the mm:ss.ss form macOS actually prints is parsed" {
  # launchd shows as 90:31.90 — ninety minutes, not ninety hours.
  shim pgrep 'echo 101'
  shim ps 'printf " 90:31.90\n"'
  run bash -c "source '$BATS_TEST_TMPDIR/cpu.sh'; agent_cpu_centiseconds"
  [ "$output" = "543190" ]
}

@test "the hh:mm:ss form is parsed" {
  shim pgrep 'echo 101'
  shim ps 'printf " 2:00:00\n"'
  run bash -c "source '$BATS_TEST_TMPDIR/cpu.sh'; agent_cpu_centiseconds"
  [ "$output" = "720000" ]
}

@test "the dd-hh:mm:ss form is parsed" {
  shim pgrep 'echo 101'
  shim ps 'printf " 1-00:00:00\n"'
  run bash -c "source '$BATS_TEST_TMPDIR/cpu.sh'; agent_cpu_centiseconds"
  [ "$output" = "8640000" ]
}

@test "an unreadable ps degrades to no veto, never to a stuck watch" {
  shim pgrep 'echo 101'
  shim ps 'exit 1'
  run bash -c "source '$BATS_TEST_TMPDIR/cpu.sh'; agent_cpu_centiseconds"
  [ "$output" = "0" ]
}

@test "the guard is a veto only — it never shortens the wait" {
  # It may assign last_activity=$now, which delays sleep. It must never
  # move last_activity backwards or trigger the sleep branch itself.
  block="$(sed -n '/^smart_watch_loop() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude")"
  assert_contains "$block" 'cpu_busy=true'
  assert_contains "$block" 'last_activity=$now'
  assert_not_contains "$block" 'cpu_busy=true; return 0'
}

@test "the threshold scales with the poll interval, not the tick" {
  # Otherwise the same CPU load would read as busy at one poll rate and
  # idle at another.
  block="$(sed -n '/^smart_watch_loop() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude")"
  assert_contains "$block" 'cpu_window=$((now - prev_cpu_ts))'
  assert_contains "$block" 'cpu_delta > cpu_window * AGENT_CPU_BUSY_PCT'
}

@test "the first tick cannot veto — there is no delta yet" {
  block="$(sed -n '/^smart_watch_loop() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude")"
  assert_contains "$block" 'prev_cpu=-1'
  assert_contains "$block" 'if ((prev_cpu >= 0))'
}

@test "--no-cpu-guard disables it" {
  run grep -n 'CPU_GUARD=false' "$REPO_ROOT/sleep-after-claude"
  [ "$status" -eq 0 ]
  run grep -n 'AGENT_CPU_BUSY_PCT="\${SAC_AGENT_CPU_BUSY_PCT:-20}"' "$REPO_ROOT/sleep-after-claude"
  [ "$status" -eq 0 ]
}

@test "watch-pid mode also stands down when the Mac slept on its own" {
  # Parity with smart mode: this path measures its deadline against the
  # wall clock too, so a lid closed mid-watch would otherwise read as
  # elapsed watch time and fire the timeout on wake.
  run grep -n 'SLEPT_EXTERNALLY (watch-pid)' "$REPO_ROOT/sleep-after-claude"
  [ "$status" -eq 0 ]
  run grep -n 'PID_ENTRY_SLEEP_STAMP="\$(sleep_stamp)"' "$REPO_ROOT/sleep-after-claude"
  [ "$status" -eq 0 ]
}

@test "log-summary counts the events the code actually emits" {
  # The vocabulary was left on pre-rewrite names, so every current event
  # reported zero — a report that is confidently wrong.
  for evt in SMART_IDLE_REACHED SLEEP_CONFIRMED SLEEP_REFUSED SLEPT_EXTERNALLY HOOKS_DEGRADED; do
    run grep -c "$evt" "$REPO_ROOT/sleep-after-claude"
    # Present both as an emitted event and in the summary vocabulary.
    [ "$output" -ge 2 ]
  done
}
