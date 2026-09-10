#!/usr/bin/env bats
# Tests for --install-hooks / --uninstall-hooks / smart-watch primitive.

load 'lib/common'

setup() {
  setup_sandbox
  export CLAUDE_SETTINGS_FILE="$HOME/.claude/settings.json"
  export BUSY_DIR="$HOME/.local/state/goodnight/busy"
}

@test "hooks: --install-hooks creates settings.json with Stop + UserPromptSubmit entries" {
  run bash "$REPO_ROOT/sleep-after-claude" --install-hooks
  [ "$status" -eq 0 ]
  [ -f "$CLAUDE_SETTINGS_FILE" ]
  run jq '.hooks.UserPromptSubmit | length' "$CLAUDE_SETTINGS_FILE"
  [ "$output" = "1" ]
  run jq '.hooks.Stop | length' "$CLAUDE_SETTINGS_FILE"
  [ "$output" = "1" ]
  # Commands must reference the busy path via $HOME (F-03) so they
  # survive home-directory moves, NOT the frozen absolute path.
  run jq -r '.hooks.Stop[0].hooks[0].command' "$CLAUDE_SETTINGS_FILE"
  assert_contains "$output" "\$HOME/.local/state/goodnight/busy"
  assert_not_contains "$output" "$HOME/.local/state/goodnight/busy"
  assert_contains "$output" "session_id"
}

@test "F-03: --install-hooks exits non-zero when settings JSON is invalid" {
  mkdir -p "$(dirname "$CLAUDE_SETTINGS_FILE")"
  printf '{ invalid json' >"$CLAUDE_SETTINGS_FILE"

  run bash "$REPO_ROOT/sleep-after-claude" --install-hooks

  [ "$status" -ne 0 ]
  assert_contains "$output" "Could not install goodnight hooks"
  assert_not_contains "$output" "Installed goodnight hooks"
}

@test "hooks: F-03 — command contains \$HOME expression, not frozen path" {
  bash "$REPO_ROOT/sleep-after-claude" --install-hooks >/dev/null
  run jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$CLAUDE_SETTINGS_FILE"
  assert_contains "$output" "\$HOME/.local/state/goodnight/busy"
  # The frozen test-sandbox HOME path must NOT appear.
  assert_not_contains "$output" "$HOME/.local/state"
}

@test "hooks: reinstall does not duplicate — arrays remain length 1" {
  bash "$REPO_ROOT/sleep-after-claude" --install-hooks >/dev/null
  bash "$REPO_ROOT/sleep-after-claude" --install-hooks >/dev/null
  bash "$REPO_ROOT/sleep-after-claude" --install-hooks >/dev/null
  run jq '.hooks.UserPromptSubmit | length' "$CLAUDE_SETTINGS_FILE"
  [ "$output" = "1" ]
  run jq '.hooks.Stop | length' "$CLAUDE_SETTINGS_FILE"
  [ "$output" = "1" ]
}

@test "hooks: reinstall preserves user-defined hook entries" {
  # Simulate a user's existing hook that goodnight must not clobber.
  mkdir -p "$(dirname "$CLAUDE_SETTINGS_FILE")"
  cat >"$CLAUDE_SETTINGS_FILE" <<'EOF'
{
  "hooks": {
    "Stop": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "echo user-hook" }] }
    ],
    "PreToolUse": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "echo pre-tool-user-hook" }] }
    ]
  }
}
EOF
  bash "$REPO_ROOT/sleep-after-claude" --install-hooks >/dev/null
  # User's Stop hook still there
  run jq -r '.hooks.Stop | map(select(._managed_by != "goodnight"))[0].hooks[0].command' "$CLAUDE_SETTINGS_FILE"
  [ "$output" = "echo user-hook" ]
  # PreToolUse untouched
  run jq -r '.hooks.PreToolUse[0].hooks[0].command' "$CLAUDE_SETTINGS_FILE"
  [ "$output" = "echo pre-tool-user-hook" ]
  # goodnight's Stop hook present
  run jq '.hooks.Stop | map(select(._managed_by == "goodnight")) | length' "$CLAUDE_SETTINGS_FILE"
  [ "$output" = "1" ]
}

@test "hooks: --uninstall-hooks removes goodnight entries but leaves user hooks" {
  mkdir -p "$(dirname "$CLAUDE_SETTINGS_FILE")"
  cat >"$CLAUDE_SETTINGS_FILE" <<'EOF'
{
  "hooks": {
    "Stop": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "echo user-hook" }] }
    ]
  }
}
EOF
  bash "$REPO_ROOT/sleep-after-claude" --install-hooks >/dev/null
  bash "$REPO_ROOT/sleep-after-claude" --uninstall-hooks >/dev/null
  run jq '.hooks.Stop | length' "$CLAUDE_SETTINGS_FILE"
  [ "$output" = "1" ]
  run jq -r '.hooks.Stop[0].hooks[0].command' "$CLAUDE_SETTINGS_FILE"
  [ "$output" = "echo user-hook" ]
}

@test "F-03: --uninstall-hooks exits non-zero when settings JSON is invalid" {
  mkdir -p "$(dirname "$CLAUDE_SETTINGS_FILE")"
  printf '{ invalid json' >"$CLAUDE_SETTINGS_FILE"

  run bash "$REPO_ROOT/sleep-after-claude" --uninstall-hooks

  [ "$status" -ne 0 ]
  assert_contains "$output" "Could not remove goodnight hooks"
  assert_not_contains "$output" "Removed goodnight hooks"
}

@test "hooks: --uninstall-hooks from a goodnight-only settings.json leaves {} behind" {
  bash "$REPO_ROOT/sleep-after-claude" --install-hooks >/dev/null
  bash "$REPO_ROOT/sleep-after-claude" --uninstall-hooks >/dev/null
  run jq 'keys | length' "$CLAUDE_SETTINGS_FILE"
  [ "$output" = "0" ]
}

# Marker counting now depends on the transcript-corroborated liveness
# model, which has its own dedicated file. See tests/session-activity.bats.
