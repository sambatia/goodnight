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
  extract_from_script "$BATS_TEST_TMPDIR/cpu.sh" agent_process_tree agent_cpu_centiseconds
  # The function reads this list; under the harness's `set -u` an unset
  # array is an error, which is the point of running with the script's
  # own options.
  sed -i.bak '1a\
AGENT_PROCESS_NAMES=(claude codex)
' "$BATS_TEST_TMPDIR/cpu.sh"
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
  run grep -n '_cfg_int SAC_AGENT_CPU_BUSY_PCT' "$REPO_ROOT/sleep-after-claude"
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


@test "a failing ps yields ONE zero, not two, under pipefail" {
  # awk's END block prints its 0 even when ps fails; with pipefail the
  # failing pipeline then fires the fallback too. The result was "0\n0",
  # which fails the numeric guard and quietly disables the signal.
  shim pgrep 'echo 101'
  shim ps 'exit 1'
  run bash -c "set -uo pipefail; source '$BATS_TEST_TMPDIR/cpu.sh'; agent_cpu_centiseconds"
  [ "$output" = "0" ]
  [ "$(printf '%s' "$output" | wc -l | tr -d ' ')" = "0" ]
}

@test "a malformed tuning value falls back loudly instead of killing the run" {
  # Under set -u a non-numeric word in an arithmetic context is not a
  # harmless fallback — bash reads it as a variable name, finds it
  # unset, and aborts the watch.
  local H; H="$(mktemp -d)"
  run env HOME="$H" SAC_AGENT_CPU_BUSY_PCT=bogus SAC_IDLE_SECONDS=1 \
    SAC_NO_GUM=1 SAC_NO_GLOW=1 bash "$REPO_ROOT/sleep-after-claude" \
    --smart --unattended --dry-run --no-preflight --allow-battery \
    --no-auto-caffeinate --no-sound --no-log --no-repair
  rm -rf "$H"
  [ "$status" -eq 0 ]
  assert_contains "$output" "is not a positive integer"
  assert_contains "$output" "Dry run complete"
}

@test "config validation reports through REPLY, not a subshell" {
  # $(_cfg_int ...) would run in a subshell, so the warning it records
  # would die there: the fallback would work and the user would never
  # learn their setting was ignored.
  block="$(sed -n '/^_cfg_int() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude")"
  assert_contains "$block" 'REPLY='
  assert_not_contains "$block" "printf '%s' \"\$fallback\""
  run grep -c '_cfg_int SAC_' "$REPO_ROOT/sleep-after-claude"
  [ "$output" -ge 8 ]
}

@test "log-summary derives its vocabulary from the log, not a fixed list" {
  # A hand-kept list drifts the moment an event is renamed, and had.
  run grep -n 'for pat in SMART_WATCH_START' "$REPO_ROOT/sleep-after-claude"
  [ "$status" -ne 0 ]
  run grep -n 'sort | uniq -c | sort -rn' "$REPO_ROOT/sleep-after-claude"
  [ "$status" -eq 0 ]
}

@test "log-summary actually counts real events from a real log" {
  setup_sandbox
  local L="$BATS_TEST_TMPDIR/sac.log"
  cat >"$L" <<'LOGEOF'
[2026-09-10 03:50:57] SMART_WATCH_START busy_count=1 hooks=ok
[2026-09-10 04:48:19] SMART_IDLE_REACHED waited=3442s
[2026-09-10 04:48:23] SLEEP_ATTEMPT n=1/3 ctx=watch
[2026-09-10 04:48:35] SLEEP_CONFIRMED n=1 via=kern.sleeptime
[2026-09-10 04:48:35] SLEEP_CONFIRMED n=1 via=kern.sleeptime
LOGEOF
  run env SAC_NO_GLOW=1 bash "$REPO_ROOT/sleep-after-claude" --log-summary --log-file "$L"
  [ "$status" -eq 0 ]
  assert_contains "$output" "| SLEEP_CONFIRMED | 2 |"
  assert_contains "$output" "| SMART_IDLE_REACHED | 1 |"
}

@test "watch-pid checks for external sleep before its timeout branch" {
  block="$(awk '/^  while \[\[ "\$\{SMART_WATCH_DONE/,/^  done$/' "$REPO_ROOT/sleep-after-claude")"
  sleep_line="$(printf '%s\n' "$block" | grep -n 'SLEPT_EXTERNALLY' | head -1 | cut -d: -f1)"
  timeout_line="$(printf '%s\n' "$block" | grep -n 'Timeout of' | head -1 | cut -d: -f1)"
  [ -n "$sleep_line" ] && [ -n "$timeout_line" ]
  [ "$sleep_line" -lt "$timeout_line" ]
}

@test "a single CPU spike does not veto — it must be sustained" {
  # Measured idle sits at 3-5% of a core but spikes to 14% against a 20%
  # threshold. A lone reading must not count, because one spurious veto
  # resets the whole idle countdown: noise arriving more often than
  # --idle would hold the machine awake until the hard timeout, which is
  # the never-sleeps failure this command exists to fix.
  block="$(sed -n '/^smart_watch_loop() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude")"
  assert_contains "$block" 'cpu_hits=$((cpu_hits + 1))'
  assert_contains "$block" 'cpu_hits=0'
  assert_contains "$block" 'cpu_hits >= AGENT_CPU_BUSY_SAMPLES'
  run grep -n 'AGENT_CPU_BUSY_SAMPLES=2' "$REPO_ROOT/sleep-after-claude"
  [ "$status" -eq 0 ]
}

@test "the agent process list is configurable, not hardcoded" {
  run grep -n 'AGENT_PROCESS_NAMES=(claude codex aider gemini opencode cursor-agent)' "$REPO_ROOT/sleep-after-claude"
  [ "$status" -eq 0 ]
  run grep -n 'SAC_EXTRA_AGENT_PROCESSES' "$REPO_ROOT/sleep-after-claude"
  [ "$status" -eq 0 ]
  # And the guard must iterate that list rather than naming binaries.
  block="$(sed -n '/^agent_process_tree() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude")"
  assert_contains "$block" 'for name in "${AGENT_PROCESS_NAMES[@]}"'
  assert_not_contains "$block" 'pgrep -x claude'
}

@test "extra agent processes are picked up from the environment" {
  extract_from_script "$BATS_TEST_TMPDIR/names.sh" agent_process_tree agent_cpu_centiseconds
  shim pgrep 'echo "PGREP $*" >>"$SHIM_LOG"; exit 1'
  export SHIM_LOG="$BATS_TEST_TMPDIR/pgrep.log"
  : >"$SHIM_LOG"
  run bash -c "
    AGENT_PROCESS_NAMES=(claude myagent)
    source '$BATS_TEST_TMPDIR/names.sh'
    agent_cpu_centiseconds"
  [ "$output" = "0" ]
  run cat "$SHIM_LOG"
  assert_contains "$output" "PGREP -x claude"
  assert_contains "$output" "PGREP -x myagent"
}

@test "caffeinate it did not start is announced as something it will kill" {
  # "leaving as-is" told the user a caffeinate they were relying on was
  # safe. It is captured and terminated at sleep time — it has to be,
  # since that assertion is what blocks sleep.
  block="$(sed -n '/^ensure_caffeinate_running() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude")"
  assert_not_contains "$block" "leaving as-is"
  assert_contains "$block" "will release these before it sleeps"
}

@test "the tree includes descendants, not just the named agent process" {
  # An agent's work is mostly done by its children: background shells,
  # Monitors, test runs, builds — spawned as zsh/node/npm, not as
  # `claude`. ps -o time= never reports a child's CPU against its
  # parent, so naming only the agent misses exactly the work that keeps
  # a machine busy after a turn ends and the marker has been cleared.
  extract_from_script "$BATS_TEST_TMPDIR/tree.sh" agent_process_tree
  # Fake a two-level tree: roots 100, children 200 201, grandchild 300.
  shim pgrep "
    case \"\$*\" in
      *'-x claude'*)  echo 100 ;;
      *'-P 100'*)     echo 200; echo 201 ;;
      *'-P 200,201'*) echo 300 ;;
      *)              exit 1 ;;
    esac"
  run bash -c "
    AGENT_PROCESS_NAMES=(claude)
    source '$BATS_TEST_TMPDIR/tree.sh'
    agent_process_tree"
  assert_contains "$output" "100"
  assert_contains "$output" "200"
  assert_contains "$output" "201"
  assert_contains "$output" "300"
}

@test "tree walking is depth-capped so a parent/child cycle cannot spin" {
  block="$(sed -n '/^agent_process_tree() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude")"
  assert_contains "$block" 'depth < 12'
}

@test "no agents means an empty tree and zero CPU, not an error" {
  extract_from_script "$BATS_TEST_TMPDIR/t.sh" agent_process_tree agent_cpu_centiseconds
  shim pgrep 'exit 1'
  run bash -c "
    AGENT_PROCESS_NAMES=(claude)
    source '$BATS_TEST_TMPDIR/t.sh'
    agent_cpu_centiseconds"
  [ "$output" = "0" ]
}

@test "CPU is summed across the whole tree" {
  extract_from_script "$BATS_TEST_TMPDIR/t2.sh" agent_process_tree agent_cpu_centiseconds
  shim pgrep "
    case \"\$*\" in
      *'-x claude'*) echo 100 ;;
      *'-P 100'*)    echo 200 ;;
      *)             exit 1 ;;
    esac"
  # parent 0:10.00 + child 0:05.00 = 15s = 1500 centiseconds
  shim ps 'printf "  0:10.00\n  0:05.00\n"'
  run bash -c "
    AGENT_PROCESS_NAMES=(claude)
    source '$BATS_TEST_TMPDIR/t2.sh'
    agent_cpu_centiseconds"
  [ "$output" = "1500" ]
}
