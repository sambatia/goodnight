#!/usr/bin/env bats
# The liveness model: a busy marker only counts while the session's
# transcript shows it is actually doing something.
#
# The old model trusted markers alone and reaped them at 24h, so a
# session that crashed — or simply stopped at a permission prompt —
# pinned the machine awake for the rest of the day. Corroborating
# against transcript mtime is what lets the stale window be minutes
# instead of a day without risking a reap mid-task.

load 'lib/common'

setup() {
  setup_sandbox
  export BUSY_DIR="$HOME/.local/state/goodnight/busy"
  export CLAUDE_PROJECTS_DIR="$HOME/.claude/projects"
  export CODEX_SESSIONS_DIR="$HOME/.codex/sessions"
  export SMART_STALE_MARKER_MINS=15
  mkdir -p "$BUSY_DIR" "$CLAUDE_PROJECTS_DIR/-Users-sam-proj" "$CODEX_SESSIONS_DIR/2026/09/10"
  extract_from_script "$BATS_TEST_TMPDIR/fns.sh" \
    transcript_for_session transcript_active_within newest_agent_activity reap_dead_markers count_busy_sessions
}

run_fn() {
  bash -c "
    BUSY_DIR='$BUSY_DIR'
    CLAUDE_PROJECTS_DIR='$CLAUDE_PROJECTS_DIR'
    CODEX_SESSIONS_DIR='$CODEX_SESSIONS_DIR'
    AGENT_ACTIVITY_DIRS=('$CLAUDE_PROJECTS_DIR' '$CODEX_SESSIONS_DIR')
    SMART_STALE_MARKER_MINS='$SMART_STALE_MARKER_MINS'
    source '$BATS_TEST_TMPDIR/fns.sh'
    $1"
}

# Create a session: a busy marker plus a transcript aged $2 minutes.
make_session() {
  local sid="$1" age_min="$2"
  touch "$BUSY_DIR/$sid"
  local t="$CLAUDE_PROJECTS_DIR/-Users-sam-proj/${sid}.jsonl"
  echo '{}' >"$t"
  if [[ "$age_min" != "0" ]]; then
    touch -t "$(date -v-"${age_min}"M +%Y%m%d%H%M)" "$t"
  fi
}

@test "a session writing right now counts as busy" {
  make_session live 0
  run run_fn 'count_busy_sessions'
  [ "$output" = "1" ]
  [ -f "$BUSY_DIR/live" ]
}

@test "a session quiet past the stale window stops counting and is reaped" {
  # Crashed, or parked on a permission prompt. Either way it is not
  # working, and it must not hold the machine awake.
  make_session stalled 30
  run run_fn 'count_busy_sessions'
  [ "$output" = "0" ]
  [ ! -f "$BUSY_DIR/stalled" ]
}

@test "a long task inside the stale window is NOT reaped" {
  # The whole risk of a tight stale window is reaping real work. A
  # transcript touched 5 minutes ago with a 15 minute window stays.
  make_session working 5
  run run_fn 'count_busy_sessions'
  [ "$output" = "1" ]
  [ -f "$BUSY_DIR/working" ]
}

@test "marker age alone does not reap a session whose transcript is fresh" {
  # A marker written hours ago by a session that is still actively
  # working must survive — transcript mtime is the authority, not the
  # marker's own timestamp.
  make_session marathon 0
  touch -t "$(date -v-6H +%Y%m%d%H%M)" "$BUSY_DIR/marathon"
  run run_fn 'count_busy_sessions'
  [ "$output" = "1" ]
  [ -f "$BUSY_DIR/marathon" ]
}

@test "an orphan marker with no transcript is reaped once it ages out" {
  touch "$BUSY_DIR/orphan"
  touch -t "$(date -v-30M +%Y%m%d%H%M)" "$BUSY_DIR/orphan"
  run run_fn 'count_busy_sessions'
  [ "$output" = "0" ]
  [ ! -f "$BUSY_DIR/orphan" ]
}

@test "a fresh marker with no transcript yet is given the benefit of the doubt" {
  # A prompt was just submitted; the transcript may not exist for a
  # moment. Reaping here would sleep the Mac on a session that is
  # about to start work.
  touch "$BUSY_DIR/just-started"
  run run_fn 'count_busy_sessions'
  [ "$output" = "1" ]
  [ -f "$BUSY_DIR/just-started" ]
}

@test "mixed sessions: only the live one counts" {
  make_session live 0
  make_session dead 45
  run run_fn 'count_busy_sessions'
  [ "$output" = "1" ]
  [ -f "$BUSY_DIR/live" ]
  [ ! -f "$BUSY_DIR/dead" ]
}

@test "transcript_active_within sees a recent write with no marker at all" {
  # The safety net: work happening without hooks must still block
  # sleep, because this is exactly the state a broken hook leaves.
  echo '{}' >"$CLAUDE_PROJECTS_DIR/-Users-sam-proj/no-marker.jsonl"
  run run_fn 'transcript_active_within 300 && echo ACTIVE || echo QUIET'
  assert_contains "$output" "ACTIVE"
}

@test "transcript_active_within reports quiet when every transcript is old" {
  echo '{}' >"$CLAUDE_PROJECTS_DIR/-Users-sam-proj/old.jsonl"
  touch -t "$(date -v-2H +%Y%m%d%H%M)" "$CLAUDE_PROJECTS_DIR/-Users-sam-proj/old.jsonl"
  run run_fn 'transcript_active_within 300 && echo ACTIVE || echo QUIET'
  assert_contains "$output" "QUIET"
}

@test "transcript_active_within is quiet when no transcripts dir exists" {
  rm -rf "$CLAUDE_PROJECTS_DIR"
  run run_fn 'transcript_active_within 300 && echo ACTIVE || echo QUIET'
  assert_contains "$output" "QUIET"
}

@test "transcript lookup resolves a session id across project directories" {
  mkdir -p "$CLAUDE_PROJECTS_DIR/-Users-sam-other"
  echo '{}' >"$CLAUDE_PROJECTS_DIR/-Users-sam-other/abc-123.jsonl"
  run run_fn 'transcript_for_session abc-123'
  assert_contains "$output" "abc-123.jsonl"
}

@test "empty busy dir counts zero without error" {
  run run_fn 'count_busy_sessions'
  [ "$output" = "0" ]
}

@test "a working Codex session blocks sleep even though it writes no marker" {
  # Busy markers only ever describe Claude Code sessions. Without a
  # second activity root the Mac would sleep on top of a running Codex
  # job — "wait for my agents" has to mean all of them.
  echo '{}' >"$CODEX_SESSIONS_DIR/2026/09/10/rollout-2026-09-10T03-19-47-abc.jsonl"
  run run_fn 'transcript_active_within 300 && echo ACTIVE || echo QUIET'
  assert_contains "$output" "ACTIVE"
}

@test "a finished Codex session stops blocking sleep" {
  local f="$CODEX_SESSIONS_DIR/2026/09/10/rollout-old.jsonl"
  echo '{}' >"$f"
  touch -t "$(date -v-2H +%Y%m%d%H%M)" "$f"
  run run_fn 'transcript_active_within 300 && echo ACTIVE || echo QUIET'
  assert_contains "$output" "QUIET"
}

@test "activity is reported across roots, newest wins" {
  echo '{}' >"$CLAUDE_PROJECTS_DIR/-Users-sam-proj/claude.jsonl"
  touch -t "$(date -v-2H +%Y%m%d%H%M)" "$CLAUDE_PROJECTS_DIR/-Users-sam-proj/claude.jsonl"
  echo '{}' >"$CODEX_SESSIONS_DIR/2026/09/10/rollout-new.jsonl"
  run run_fn 'newest_agent_activity'
  now=$(date +%s)
  [ -n "$output" ]
  # The Codex file was written just now, so the newest mtime is recent.
  [ "$((now - output))" -lt 120 ]
}

@test "a missing Codex root is skipped, not fatal" {
  rm -rf "$CODEX_SESSIONS_DIR"
  echo '{}' >"$CLAUDE_PROJECTS_DIR/-Users-sam-proj/live.jsonl"
  run run_fn 'transcript_active_within 300 && echo ACTIVE || echo QUIET'
  assert_contains "$output" "ACTIVE"
}
