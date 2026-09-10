#!/usr/bin/env bats
# --doctor exists because the original failure was undetectable from
# outside: hooks looked installed, markers were still being written,
# the command still ran — it had just silently stopped using any of it.
# Answering "will this work tonight?" required reading the source.
#
# Contract: report observed state, and exit non-zero when degraded.

load 'lib/common'

setup() {
  setup_sandbox
  export CLAUDE_SETTINGS_FILE="$HOME/.claude/settings.json"
  mkdir -p "$HOME/.claude/projects/proj" "$HOME/.local/state/goodnight/busy"
  shim pmset 'exit 1'
  shim pgrep 'exit 1'
}

doctor() {
  env SAC_NO_GUM=1 SAC_NO_GLOW=1 bash "$REPO_ROOT/sleep-after-claude" --doctor --no-log
}

@test "doctor: healthy install reports ok and exits 0" {
  bash "$REPO_ROOT/sleep-after-claude" --install-hooks >/dev/null
  run doctor
  [ "$status" -eq 0 ]
  assert_contains "$output" "Hooks healthy"
  assert_contains "$output" "Healthy"
}

@test "doctor: a settings file with no goodnight entries reports MISSING" {
  echo '{"hooks":{}}' >"$CLAUDE_SETTINGS_FILE"
  run doctor
  [ "$status" -eq 1 ]
  assert_contains "$output" "Hooks MISSING"
  assert_contains "$output" "Degraded"
}

@test "doctor: no settings file at all is reported distinctly" {
  [ ! -f "$CLAUDE_SETTINGS_FILE" ]
  run doctor
  [ "$status" -eq 1 ]
  assert_contains "$output" "No settings file"
  assert_contains "$output" "Degraded"
}

@test "doctor: hooks stripped of their tag are reported as still working" {
  # The real-world regression: functional, but a reinstall would
  # duplicate them. Must be surfaced without being called broken.
  cat >"$CLAUDE_SETTINGS_FILE" <<'JSON'
{
  "hooks": {
    "UserPromptSubmit": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "touch x # goodnight-hook" }] }
    ],
    "Stop": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "rm -f x # goodnight-hook" }] }
    ]
  }
}
JSON
  run doctor
  [ "$status" -eq 0 ]
  assert_contains "$output" "Hooks healthy"
  assert_contains "$output" "lost their ._managed_by tag"
}

@test "doctor: partial install exits non-zero" {
  cat >"$CLAUDE_SETTINGS_FILE" <<'JSON'
{ "hooks": { "Stop": [ { "_managed_by": "goodnight", "hooks": [{ "type": "command", "command": "true # goodnight-hook" }] } ] } }
JSON
  run doctor
  [ "$status" -eq 1 ]
  assert_contains "$output" "Hooks PARTIAL"
}

@test "doctor: reports stale markers and clears them" {
  bash "$REPO_ROOT/sleep-after-claude" --install-hooks >/dev/null
  touch "$HOME/.local/state/goodnight/busy/dead-session"
  touch -t "$(date -v-3H +%Y%m%d%H%M)" "$HOME/.local/state/goodnight/busy/dead-session"
  run doctor
  [ "$status" -eq 0 ]
  assert_contains "$output" "Stale (reaped)"
  [ ! -f "$HOME/.local/state/goodnight/busy/dead-session" ]
}

@test "doctor: a live session is reported as still working" {
  bash "$REPO_ROOT/sleep-after-claude" --install-hooks >/dev/null
  touch "$HOME/.local/state/goodnight/busy/live"
  echo '{}' >"$HOME/.claude/projects/proj/live.jsonl"
  run doctor
  [ "$status" -eq 0 ]
  assert_contains "$output" "would wait"
}

@test "doctor: a fully quiet machine is reported as ready to sleep" {
  bash "$REPO_ROOT/sleep-after-claude" --install-hooks >/dev/null
  echo '{}' >"$HOME/.claude/projects/proj/old.jsonl"
  touch -t "$(date -v-3H +%Y%m%d%H%M)" "$HOME/.claude/projects/proj/old.jsonl"
  run doctor
  [ "$status" -eq 0 ]
  assert_contains "$output" "would sleep"
}

@test "doctor: never sleeps the machine" {
  # Belt and braces — the diagnostic path must not touch pmset sleepnow.
  shim pmset "echo \"PMSET \$*\" >>'$BATS_TEST_TMPDIR/pmset.log'; exit 1"
  bash "$REPO_ROOT/sleep-after-claude" --install-hooks >/dev/null
  run doctor
  if [ -f "$BATS_TEST_TMPDIR/pmset.log" ]; then
    run cat "$BATS_TEST_TMPDIR/pmset.log"
    assert_not_contains "$output" "sleepnow"
  fi
}
