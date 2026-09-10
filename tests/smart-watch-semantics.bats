#!/usr/bin/env bats
# Source-level contracts for smart_watch_loop. Behaviour lives in
# tests/smart-watch-runtime.bats; this file pins the invariants that are
# easy to regress silently during a refactor.

load 'lib/common'

@test "the watch loop is bounded by a hard timeout" {
  # The original loop was `while true` with no elapsed check, so a
  # single wedged marker meant the machine never slept. Every wait path
  # in this program must terminate.
  run grep -n 'SMART_TIMEOUT_SECS > 0 && elapsed >= SMART_TIMEOUT_SECS' "$REPO_ROOT/sleep-after-claude"
  [ "$status" -eq 0 ]
  # ...and the timeout must actually be assigned before the loop runs.
  run grep -n 'SMART_TIMEOUT_SECS=\$((TIMEOUT_HOURS \* 3600))' "$REPO_ROOT/sleep-after-claude"
  [ "$status" -eq 0 ]
}

@test "the watch loop requires marker AND transcript quiet before sleeping" {
  run grep -n 'busy" == "0" && "\$recent_write" == false' "$REPO_ROOT/sleep-after-claude"
  [ "$status" -eq 0 ]
}

@test "the cold-start hold is gone" {
  # Deliberate behaviour change. The old loop refused to sleep until it
  # had personally watched a marker appear, which meant "all agents
  # already finished" — the single most common way to invoke this
  # command — waited forever.
  run grep -n 'seen_busy' "$REPO_ROOT/sleep-after-claude"
  [ "$status" -ne 0 ]
  run grep -n 'Waiting for a Claude prompt' "$REPO_ROOT/sleep-after-claude"
  [ "$status" -ne 0 ]
}

@test "smart mode is the unconditional default, never PID-watch" {
  # Falling back to PID mode on a hook-detection failure is what made
  # the breakage invisible: it kept running, just uselessly. PID mode
  # must now be reachable only by explicit request.
  #
  # Extract the default-mode selection block and assert on its body.
  block="$(sed -n '/^if \[\[ "\$SMART_WATCH" != true \&\& "\$WATCH_PID_MODE" != true \&\&/,/^fi$/p' \
    "$REPO_ROOT/sleep-after-claude")"
  [ -n "$block" ]
  assert_contains "$block" "SMART_WATCH=true"
  assert_not_contains "$block" "WATCH_PID_MODE=true"
}

@test "PID mode is reachable only through flags that name a process" {
  # --pid and --wait-for-start are meaningless in smart mode, so each
  # selects PID mode itself rather than being silently ignored.
  for flag in '--pid | -p)' '--wait-for-start)' '--watch-pid)'; do
    arm="$(awk -v pat="$flag" '
      index($0, pat) { found=1 }
      found { print }
      found && /^      ;;$/ { exit }
    ' "$REPO_ROOT/sleep-after-claude")"
    assert_contains "$arm" "WATCH_PID_MODE=true"
  done
}

@test "stale-marker threshold is configurable and defaults to 15 minutes" {
  run grep -E 'SMART_STALE_MARKER_MINS="\$\{SAC_STALE_MARKER_MINUTES:-15\}"' "$REPO_ROOT/sleep-after-claude"
  [ "$status" -eq 0 ]
}

@test "idle threshold is configurable and defaults to 5 minutes" {
  run grep -E 'SMART_IDLE_SECONDS="\$\{SAC_IDLE_SECONDS:-300\}"' "$REPO_ROOT/sleep-after-claude"
  [ "$status" -eq 0 ]
}

@test "the reaper corroborates against transcripts, not a blind 24h sweep" {
  # The old one-liner deleted by marker age alone.
  run grep -E 'find "\$BUSY_DIR" -type f -mmin \+"\$SMART_STALE_MARKER_MINS" -delete' "$REPO_ROOT/sleep-after-claude"
  [ "$status" -ne 0 ]
  run grep -n 'transcript_for_session' "$REPO_ROOT/sleep-after-claude"
  [ "$status" -eq 0 ]
}

@test "the loop polls without forking a sleep per tick" {
  run grep -n 'micro_sleep "\$poll"' "$REPO_ROOT/sleep-after-claude"
  [ "$status" -eq 0 ]
}

@test "every sleep goes through the verified path" {
  # A bare `pmset sleepnow` anywhere means an unverified sleep can
  # still slip out and report success while the Mac stays awake.
  run grep -nE '^\s*(if )?pmset sleepnow' "$REPO_ROOT/sleep-after-claude"
  [ "$status" -ne 0 ]
  run grep -c 'attempt_sleep ' "$REPO_ROOT/sleep-after-claude"
  [ "$output" -ge 2 ]
}
