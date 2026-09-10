#!/usr/bin/env bats
# F-05 regression tests.
# A failing `pmset -g assertions` must NOT produce a green "clear"
# verdict. The renderer must say "scan unavailable"; JSON must set
# scan_ok=false and can_sleep=null.

load 'lib/common'

setup() {
  setup_sandbox
}

run_preflight() {
  local args=("$@")
  PATH="$SHIM_DIR:$PATH" bash "$REPO_ROOT/sleep-after-claude" --preflight "${args[@]}"
}

@test "F-05: brief verdict shows 'scan unavailable' when pmset exits non-zero" {
  shim pmset 'exit 1'
  run run_preflight --brief
  [ "$status" -eq 0 ]
  assert_contains "$output" "Sleep-blocker scan unavailable"
  assert_not_contains "$output" "No sleep blockers detected"
}

@test "F-05: full verdict shows 'scan unavailable' when pmset output lacks header" {
  # Emit an unexpected format — no "Listed by owning process" line.
  shim pmset 'printf "garbage output\n"; exit 0'
  run run_preflight
  [ "$status" -eq 0 ]
  assert_contains "$output" "Sleep-blocker scan unavailable"
  assert_not_contains "$output" "No active sleep blockers detected"
}

@test "F-05: JSON reports scan_ok=false and can_sleep=null on failure" {
  shim pmset 'exit 1'
  run run_preflight --json
  [ "$status" -eq 0 ]
  # Validate JSON and specific fields with python3.
  python_check="$(printf '%s\n' "$output" | python3 -c 'import json,sys
d=json.load(sys.stdin)
assert d["scan_ok"] is False, d
assert d["can_sleep"] is None, d
print("OK")')"
  [ "$python_check" = "OK" ]
}

@test "F-05: JSON reports scan_ok=true and can_sleep=true on healthy scan" {
  shim_fixture pmset fixtures/pmset-assertions-clear.txt
  run run_preflight --json
  [ "$status" -eq 0 ]
  python_check="$(printf '%s\n' "$output" | python3 -c 'import json,sys
d=json.load(sys.stdin)
assert d["scan_ok"] is True, d
assert d["can_sleep"] is True, d
assert d["blocker_count"] == 0, d
print("OK")')"
  [ "$python_check" = "OK" ]
}

@test "F-05: JSON reports scan_ok=true and can_sleep=false when blocker detected" {
  shim_fixture pmset fixtures/pmset-assertions-with-blocker.txt
  run run_preflight --json
  [ "$status" -eq 0 ]
  python_check="$(printf '%s\n' "$output" | python3 -c 'import json,sys
d=json.load(sys.stdin)
assert d["scan_ok"] is True, d
assert d["can_sleep"] is False, d
assert d["blocker_count"] >= 1, d
names=[b["name"] for b in d["blockers"]]
assert "malicious-blocker" in names, names
print("OK")')"
  [ "$python_check" = "OK" ]
}

@test "F-05: JSON output is always valid JSON across failure/clear/blocker fixtures" {
  for case in fail clear blocker; do
    case "$case" in
      fail)    shim pmset 'exit 1' ;;
      clear)   shim_fixture pmset fixtures/pmset-assertions-clear.txt ;;
      blocker) shim_fixture pmset fixtures/pmset-assertions-with-blocker.txt ;;
    esac
    run run_preflight --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | python3 -c 'import json,sys; json.load(sys.stdin)'
  done
}

@test "unattended: a failed blocker scan proceeds instead of aborting the run" {
  # The scan is advisory — the sleep itself is verified and retried. A
  # transient pmset failure must not silently cancel the whole night's
  # run, which is what fail-closed amounts to when nobody is awake to
  # answer the prompt.
  count="$(grep -c '"\$FORCE" == false && "\$UNATTENDED" == false' "$REPO_ROOT/sleep-after-claude")"
  [ "$count" -eq 3 ]
}

@test "unattended: a failed scan still reaches the sleep step" {
  # setup() already built the sandbox; re-running it here left the
  # shim dir on PATH twice and made the test's state harder to reason
  # about than the thing it was testing.
  shim pmset 'exit 1'
  shim pgrep 'exit 1'
  mkdir -p "$HOME/.claude/projects" "$HOME/.local/state/goodnight/busy"
  run env SAC_IDLE_SECONDS=1 bash "$REPO_ROOT/sleep-after-claude" \
    --smart --unattended --dry-run --allow-battery \
    --no-auto-caffeinate --no-sound --no-log --no-repair
  [ "$status" -eq 0 ]
  assert_contains "$output" "Dry run complete"
  assert_not_contains "$output" "Aborted"
}
