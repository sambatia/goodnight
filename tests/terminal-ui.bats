#!/usr/bin/env bats
# Terminal UI presentation behavior.

load 'lib/common'

setup() {
  setup_sandbox
}

@test "terminal-ui: --help renders markdown help with a plain fallback" {
  run env SAC_NO_GLOW=1 "$REPO_ROOT/sleep-after-claude" --help

  [ "$status" -eq 0 ]
  assert_contains "$output" "# sleep-after-claude"
  assert_contains "$output" "## Watch options"
  assert_contains "$output" "## How it decides"
  assert_contains "$output" "--doctor"
}

@test "terminal-ui: ui_confirm fails closed without stdin TTY" {
  {
    sed -n '/^have_gum() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
    sed -n '/^prompt_confirm() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
    sed -n '/^ui_confirm() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
  } >"$BATS_TEST_TMPDIR/confirm.sh"

  run bash -c "
    STDIN_IS_TTY=false
    STDOUT_IS_TTY=false
    BOLD=''
    RESET=''
    print_warn() { echo \"WARN \$1\"; }
    source '$BATS_TEST_TMPDIR/confirm.sh'
    ui_confirm 'Proceed with risky operation?'
  " 2>&1

  [ "$status" -eq 1 ]
  assert_contains "$output" "Non-interactive confirmation unavailable"
  assert_contains "$output" "defaulting to no"
}

@test "terminal-ui: shared UI helpers render tidy plain fallback output" {
  {
    sed -n '/^print_header() {$/,/^# Render the public CLI help/p' "$REPO_ROOT/sleep-after-claude"
  } >"$BATS_TEST_TMPDIR/ui.sh"

  run bash -c "
    STDIN_IS_TTY=false
    STDOUT_IS_TTY=false
    BOLD=''
    RESET=''
    DIM=''
    GREEN=''
    YELLOW=''
    CYAN=''
    RED=''
    BLUE=''
    MAGENTA=''
    SAC_NO_GUM=1
    SAC_NO_GLOW=1
    source '$BATS_TEST_TMPDIR/ui.sh'
    ui_section 'Pre-flight scan' 'Sleep readiness audit'
    ui_kv 'Battery' 'AC Power'
    printf 'state,pid,name,type\nblocker,999,zoom,PreventUserIdleSystemSleep\n' | ui_table 'State,PID,Name,Type'
  "

  [ "$status" -eq 0 ]
  assert_contains "$output" "Pre-flight scan"
  assert_contains "$output" "Sleep readiness audit"
  assert_contains "$output" "Battery"
  assert_contains "$output" "AC Power"
  assert_contains "$output" "State"
  assert_contains "$output" "zoom"
}

@test "terminal-ui: runtime source uses gum table through the UI layer" {
  run grep -E '^ui_table\(\)' "$REPO_ROOT/sleep-after-claude"
  [ "$status" -eq 0 ]

  run grep -E 'gum table --print' "$REPO_ROOT/sleep-after-claude"
  [ "$status" -eq 0 ]
}

@test "terminal-ui: plain fallback output matches golden fixtures" {
  run "$REPO_ROOT/scripts/check-terminal-ui.sh" --fallback-only

  [ "$status" -eq 0 ]
  assert_contains "$output" "terminal-ui: runtime plain fixture OK"
  assert_contains "$output" "terminal-ui: installer plain fixture OK"
}

@test "terminal-ui: gum/glow harness validates deterministic styled snapshots" {
  run "$REPO_ROOT/scripts/check-terminal-ui.sh" --shimmed-gum-only

  [ "$status" -eq 0 ]
  assert_contains "$output" "terminal-ui: runtime gum/glow shim fixture OK"
  assert_contains "$output" "terminal-ui: installer gum/glow shim fixture OK"
}
