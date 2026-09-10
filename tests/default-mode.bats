#!/usr/bin/env bats
# Default-mode selection. Smart mode is now the unconditional default;
# PID mode is opt-in. The old behaviour — silently demoting to PID mode
# whenever hook detection failed — is the bug that let a broken
# integration masquerade as a working command for months.

load 'lib/common'

setup() {
  setup_sandbox
  export CLAUDE_SETTINGS_FILE="$HOME/.claude/settings.json"
}

@test "default mode: smart is selected with no flags, hooks or not" {
  block="$(sed -n '/^if \[\[ "\$SMART_WATCH" != true \&\& "\$WATCH_PID_MODE" != true \&\&/,/^fi$/p' \
    "$REPO_ROOT/sleep-after-claude")"
  assert_contains "$block" "SMART_WATCH=true"
  assert_not_contains "$block" "hooks_installed"
}

@test "--smart repairs missing hooks instead of refusing to run" {
  # Previously this exited 1 with "hooks aren't installed" and did
  # nothing. Refusing to work is not a useful response to a repairable
  # config problem in a command you rely on nightly.
  [ ! -f "$CLAUDE_SETTINGS_FILE" ]
  shim pgrep 'exit 1'

  run env SAC_IDLE_SECONDS=1 bash "$REPO_ROOT/sleep-after-claude" \
    --smart --no-preflight --allow-battery --dry-run \
    --no-auto-caffeinate --no-sound --no-log

  [ "$status" -eq 0 ]
  assert_contains "$output" "repair"
  assert_contains "$output" "Dry run complete"
  # And the repair actually landed.
  run jq -r '[.hooks.UserPromptSubmit[], .hooks.Stop[]] | length' "$CLAUDE_SETTINGS_FILE"
  [ "$output" = "2" ]
}

@test "--smart with --no-repair falls back instead of repairing" {
  [ ! -f "$CLAUDE_SETTINGS_FILE" ]
  shim pgrep 'exit 1'

  run env SAC_IDLE_SECONDS=1 bash "$REPO_ROOT/sleep-after-claude" \
    --smart --no-preflight --allow-battery --dry-run --no-repair \
    --no-auto-caffeinate --no-sound --no-log

  [ "$status" -eq 0 ]
  assert_contains "$output" "transcript-activity detection"
  [ ! -f "$CLAUDE_SETTINGS_FILE" ]
}

@test "hooks_installed: true after --install-hooks, false after --uninstall-hooks" {
  extract_from_script "$BATS_TEST_TMPDIR/helper.sh" hooks_health hooks_installed

  probe() {
    bash -c "CLAUDE_SETTINGS_FILE='$CLAUDE_SETTINGS_FILE'; source '$BATS_TEST_TMPDIR/helper.sh'; hooks_installed && echo YES || echo NO"
  }

  run probe
  [ "$output" = "NO" ]
  bash "$REPO_ROOT/sleep-after-claude" --install-hooks >/dev/null
  run probe
  [ "$output" = "YES" ]
  bash "$REPO_ROOT/sleep-after-claude" --uninstall-hooks >/dev/null
  run probe
  [ "$output" = "NO" ]
}

@test "F-04: hooks_installed is false without jq even when marker text exists" {
  extract_from_script "$BATS_TEST_TMPDIR/helper.sh" hooks_health hooks_installed

  mkdir -p "$(dirname "$CLAUDE_SETTINGS_FILE")"
  cat >"$CLAUDE_SETTINGS_FILE" <<'JSON'
{ "hooks": { "Stop": [ { "_managed_by": "goodnight" } ] } }
JSON
  mkdir -p "$BATS_TEST_TMPDIR/empty-path"

  run bash -c "
    PATH='$BATS_TEST_TMPDIR/empty-path'
    CLAUDE_SETTINGS_FILE='$CLAUDE_SETTINGS_FILE'
    source '$BATS_TEST_TMPDIR/helper.sh'
    hooks_installed && echo YES || echo NO
  "
  [ "$output" = "NO" ]
}

@test "installer: runs --install-hooks automatically during install" {
  SHELL=/bin/zsh run bash "$REPO_ROOT/install-sleep-after-claude.sh"
  [ "$status" -eq 0 ]
  assert_contains "$output" "Claude Code hooks installed"
  [ -f "$CLAUDE_SETTINGS_FILE" ]
  [ -x "$HOME/bin/sleep-after-claude" ]
  run jq -r '.hooks.Stop | map(select(._managed_by == "goodnight")) | length' \
    "$CLAUDE_SETTINGS_FILE"
  [ "$output" = "1" ]
}

@test "installer: reports already-installed on second run" {
  SHELL=/bin/zsh bash "$REPO_ROOT/install-sleep-after-claude.sh" >/dev/null
  SHELL=/bin/zsh run bash "$REPO_ROOT/install-sleep-after-claude.sh"
  [ "$status" -eq 0 ]
  assert_contains "$output" "already installed"
}
