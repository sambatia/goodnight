#!/usr/bin/env bats
# Regression tests for the failure that made goodnight stop working
# silently: settings.json was rewritten by another tool, the
# ._managed_by tag was dropped, and hook detection — which keyed on
# that tag alone — concluded the hooks were gone. The hook commands
# themselves were untouched and still firing the whole time.
#
# The contract these lock in: detection follows the command, not the
# annotation.

load 'lib/common'

setup() {
  setup_sandbox
  export CLAUDE_SETTINGS_FILE="$HOME/.claude/settings.json"
  mkdir -p "$HOME/.claude"
  extract_from_script "$BATS_TEST_TMPDIR/fns.sh" \
    hooks_health hooks_installed hooks_need_retag
}

# Write a settings.json whose goodnight hooks carry the real command
# bodies. $1 selects whether the ._managed_by tag is present.
write_settings() {
  local tagged="$1"
  local tag=""
  [[ "$tagged" == tagged ]] && tag='"_managed_by": "goodnight",'
  cat >"$CLAUDE_SETTINGS_FILE" <<JSON
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "",
        $tag
        "hooks": [{ "type": "command", "command": "mkdir -p \"\$HOME/.local/state/goodnight/busy\" 2>/dev/null; sid=\$(jq -r .session_id); touch \"\$HOME/.local/state/goodnight/busy\"/\"\$sid\"; exit 0 # goodnight-hook" }]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        $tag
        "hooks": [{ "type": "command", "command": "sid=\$(jq -r .session_id); rm -f \"\$HOME/.local/state/goodnight/busy\"/\"\$sid\"; exit 0 # goodnight-hook" }]
      }
    ]
  }
}
JSON
}

health() {
  bash -c "CLAUDE_SETTINGS_FILE='$CLAUDE_SETTINGS_FILE'; source '$BATS_TEST_TMPDIR/fns.sh'; hooks_health"
}

@test "detection: tagged hooks report healthy" {
  write_settings tagged
  run health
  [ "$output" = "ok" ]
}

@test "detection: hooks stripped of _managed_by are STILL detected" {
  # This is the exact regression. The commands are intact and firing;
  # only the annotation is gone. Reporting these as missing is what
  # silently demoted the command to legacy PID-watch mode.
  write_settings untagged
  run health
  [ "$output" = "ok" ]
}

@test "detection: untagged hooks are flagged for re-tagging" {
  write_settings untagged
  run bash -c "CLAUDE_SETTINGS_FILE='$CLAUDE_SETTINGS_FILE'; source '$BATS_TEST_TMPDIR/fns.sh'; hooks_need_retag && echo NEEDS"
  assert_contains "$output" "NEEDS"
}

@test "detection: tagged hooks are not flagged for re-tagging" {
  write_settings tagged
  run bash -c "CLAUDE_SETTINGS_FILE='$CLAUDE_SETTINGS_FILE'; source '$BATS_TEST_TMPDIR/fns.sh'; hooks_need_retag && echo NEEDS || echo CLEAN"
  assert_contains "$output" "CLEAN"
}

@test "detection: legacy hooks without the sentinel still match on the busy path" {
  # Installs predating the sentinel have neither tag nor comment, but
  # their command still names the busy directory.
  cat >"$CLAUDE_SETTINGS_FILE" <<'JSON'
{
  "hooks": {
    "UserPromptSubmit": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "touch \"$HOME/.local/state/goodnight/busy\"/\"$sid\"" }] }
    ],
    "Stop": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "rm -f \"$HOME/.local/state/goodnight/busy\"/\"$sid\"" }] }
    ]
  }
}
JSON
  run health
  [ "$output" = "ok" ]
}

@test "detection: only Stop installed reports partial, not ok" {
  # Without UserPromptSubmit no marker is ever created, so a
  # marker-trusting watcher would read a busy machine as idle. Partial
  # must never be treated as installed.
  cat >"$CLAUDE_SETTINGS_FILE" <<'JSON'
{
  "hooks": {
    "Stop": [
      { "matcher": "", "_managed_by": "goodnight", "hooks": [{ "type": "command", "command": "true # goodnight-hook" }] }
    ]
  }
}
JSON
  run health
  [ "$output" = "partial" ]
  run bash -c "CLAUDE_SETTINGS_FILE='$CLAUDE_SETTINGS_FILE'; source '$BATS_TEST_TMPDIR/fns.sh'; hooks_installed && echo YES || echo NO"
  assert_contains "$output" "NO"
}

@test "detection: unrelated hooks report missing" {
  cat >"$CLAUDE_SETTINGS_FILE" <<'JSON'
{ "hooks": { "Stop": [ { "hooks": [{ "type": "command", "command": "some-other-tool" }] } ] } }
JSON
  run health
  [ "$output" = "missing" ]
}

@test "detection: malformed settings.json reports badjson, never ok" {
  echo 'this is not json' >"$CLAUDE_SETTINGS_FILE"
  run health
  [ "$output" = "badjson" ]
}

@test "detection: missing settings file reports nofile" {
  rm -f "$CLAUDE_SETTINGS_FILE"
  run health
  [ "$output" = "nofile" ]
}

@test "detection: absent jq reports nojq (hook bodies could not run)" {
  write_settings tagged
  shim jq 'exit 127'
  # Remove jq from PATH entirely rather than shimming a failure.
  run bash -c "PATH='$BATS_TEST_TMPDIR/emptybin'; CLAUDE_SETTINGS_FILE='$CLAUDE_SETTINGS_FILE'; source '$BATS_TEST_TMPDIR/fns.sh'; hooks_health"
  [ "$output" = "nojq" ]
}

@test "install: re-installing over untagged hooks does not duplicate them" {
  # De-duplication keyed on the tag alone would leave the untagged copy
  # in place and append a second one beside it, firing every hook twice.
  write_settings untagged
  run bash "$REPO_ROOT/sleep-after-claude" --install-hooks
  [ "$status" -eq 0 ]
  run jq '[.hooks.UserPromptSubmit[]] | length' "$CLAUDE_SETTINGS_FILE"
  [ "$output" = "1" ]
  run jq '[.hooks.Stop[]] | length' "$CLAUDE_SETTINGS_FILE"
  [ "$output" = "1" ]
}

@test "install: adds a SessionEnd hook so abandoned sessions clear their marker" {
  run bash "$REPO_ROOT/sleep-after-claude" --install-hooks
  [ "$status" -eq 0 ]
  run jq -r '.hooks.SessionEnd[0].hooks[0].command' "$CLAUDE_SETTINGS_FILE"
  assert_contains "$output" "rm -f"
  assert_contains "$output" "goodnight-hook"
}

@test "install: preserves unrelated hooks belonging to other tools" {
  cat >"$CLAUDE_SETTINGS_FILE" <<'JSON'
{ "hooks": { "Stop": [ { "hooks": [{ "type": "command", "command": "other-tool --keep-me" }] } ] } }
JSON
  run bash "$REPO_ROOT/sleep-after-claude" --install-hooks
  [ "$status" -eq 0 ]
  run jq -r '[.hooks.Stop[].hooks[0].command] | join("|")' "$CLAUDE_SETTINGS_FILE"
  assert_contains "$output" "other-tool --keep-me"
  assert_contains "$output" "goodnight-hook"
}

@test "uninstall: removes hooks that have lost their _managed_by tag" {
  # Tag-only removal would leave an untagged entry permanently stuck.
  write_settings untagged
  run bash "$REPO_ROOT/sleep-after-claude" --uninstall-hooks
  [ "$status" -eq 0 ]
  run health
  [ "$output" = "missing" ] || [ "$output" = "nofile" ]
}
