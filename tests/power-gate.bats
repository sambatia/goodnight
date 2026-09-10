#!/usr/bin/env bats
# Power-state gate tests. Uses a PATH-shim for `pmset` to simulate
# AC / Battery / Unknown states without touching the real machine.

load 'lib/common'

setup() {
  setup_sandbox
  # Extract the power functions + their ui_* dependencies. Tests force
  # the bash-fallback path by setting SAC_NO_GUM=1, so ui_panel just
  # prints the hand-drawn card.
  {
    harness_preamble
    sed -n '/^have_gum() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
    sed -n '/^have_glow() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
    sed -n '/^ui_panel() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
    sed -n '/^get_power_source() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
    sed -n '/^get_battery_percent() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
    sed -n '/^render_battery_gauge() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
    sed -n '/^wait_for_ac_power() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
  } >"$BATS_TEST_TMPDIR/power.sh"
  [ -s "$BATS_TEST_TMPDIR/power.sh" ]
  # Force fallback path in tests for deterministic output.
  export SAC_NO_GUM=1
}

@test "get_power_source: returns AC when pmset reports 'AC Power'" {
  shim pmset "cat <<'EOF'
Now drawing from 'AC Power'
 -InternalBattery-0 (id=1234567)\t100%; charged; 0:00 remaining present: true
EOF"
  run bash -c "source '$BATS_TEST_TMPDIR/power.sh'; get_power_source"
  [ "$status" -eq 0 ]
  [ "$output" = "AC" ]
}

@test "get_power_source: returns Battery when pmset reports 'Battery Power'" {
  shim pmset "cat <<'EOF'
Now drawing from 'Battery Power'
 -InternalBattery-0 (id=1234567)\t62%; discharging; 3:15 remaining present: true
EOF"
  run bash -c "source '$BATS_TEST_TMPDIR/power.sh'; get_power_source"
  [ "$status" -eq 0 ]
  [ "$output" = "Battery" ]
}

@test "get_power_source: returns Unknown when pmset has no recognizable source (e.g., desktop Mac)" {
  shim pmset 'echo "Now drawing from nothing identifiable"; exit 0'
  run bash -c "source '$BATS_TEST_TMPDIR/power.sh'; get_power_source"
  [ "$output" = "Unknown" ]
}

@test "get_battery_percent: extracts the first N% token from pmset output" {
  shim pmset "printf 'Now drawing from %s\n -InternalBattery-0\t77%%; discharging\n' \"'Battery Power'\""
  run bash -c "source '$BATS_TEST_TMPDIR/power.sh'; get_battery_percent"
  [ "$status" -eq 0 ]
  [ "$output" = "77%" ]
}

@test "wait_for_ac_power: returns immediately when --allow-battery is set" {
  shim pmset "printf 'Now drawing from %s\n' \"'Battery Power'\""
  run bash -c "
    ALLOW_BATTERY=true FORCE=false USE_SPINNER=false
    BOLD='' DIM='' YELLOW='' GREEN='' CYAN='' RESET=''
    print_ok() { echo \"OK \$1\"; }
    log_event() { :; }
    source '$BATS_TEST_TMPDIR/power.sh'
    wait_for_ac_power
    echo DONE
  " 2>&1
  [ "$status" -eq 0 ]
  assert_contains "$output" "DONE"
  assert_not_contains "$output" "External power required"
}

@test "wait_for_ac_power: returns immediately when --force is set" {
  shim pmset "printf 'Now drawing from %s\n' \"'Battery Power'\""
  run bash -c "
    ALLOW_BATTERY=false FORCE=true USE_SPINNER=false
    BOLD='' DIM='' YELLOW='' GREEN='' CYAN='' RESET=''
    print_ok() { echo \"OK \$1\"; }
    log_event() { :; }
    source '$BATS_TEST_TMPDIR/power.sh'
    wait_for_ac_power
    echo DONE
  " 2>&1
  [ "$status" -eq 0 ]
  assert_contains "$output" "DONE"
  assert_not_contains "$output" "External power required"
}

@test "wait_for_ac_power: returns immediately when already on AC" {
  shim pmset "printf 'Now drawing from %s\n -InternalBattery-0\t100%%; charged\n' \"'AC Power'\""
  run bash -c "
    ALLOW_BATTERY=false FORCE=false USE_SPINNER=false
    BOLD='' DIM='' YELLOW='' GREEN='' CYAN='' RESET=''
    print_ok() { echo \"OK \$1\"; }
    log_event() { :; }
    source '$BATS_TEST_TMPDIR/power.sh'
    wait_for_ac_power
    echo DONE
  " 2>&1
  [ "$status" -eq 0 ]
  assert_contains "$output" "DONE"
  assert_not_contains "$output" "External power required"
}

@test "wait_for_ac_power: returns immediately on Unknown (desktop Mac)" {
  shim pmset 'echo "Now drawing from nothing identifiable"; exit 0'
  run bash -c "
    ALLOW_BATTERY=false FORCE=false USE_SPINNER=false
    BOLD='' DIM='' YELLOW='' GREEN='' CYAN='' RESET=''
    print_ok() { echo \"OK \$1\"; }
    log_event() { :; }
    source '$BATS_TEST_TMPDIR/power.sh'
    wait_for_ac_power
    echo DONE
  " 2>&1
  [ "$status" -eq 0 ]
  assert_contains "$output" "DONE"
  assert_not_contains "$output" "External power required"
}

@test "wait_for_ac_power: shows warning on battery, resumes when shim flips to AC" {
  # A pmset shim that returns Battery Power the first 2 times and
  # AC Power on the 3rd+ call. Uses a state file in BATS_TEST_TMPDIR.
  cat > "$SHIM_DIR/pmset" <<EOF
#!/usr/bin/env bash
stamp="$BATS_TEST_TMPDIR/pmset-calls"
n="\$(cat "\$stamp" 2>/dev/null || echo 0)"
n=\$((n + 1))
echo "\$n" > "\$stamp"
if [[ "\$n" -le 2 ]]; then
  printf "Now drawing from %s\n -InternalBattery-0\t80%%; discharging\n" "'Battery Power'"
else
  printf "Now drawing from %s\n -InternalBattery-0\t81%%; charging\n" "'AC Power'"
fi
EOF
  chmod +x "$SHIM_DIR/pmset"

  run bash -c "
    ALLOW_BATTERY=false FORCE=false USE_SPINNER=false
    BOLD='' DIM='' YELLOW='' GREEN='' CYAN='' RESET=''
    print_ok() { echo \"OK \$1\"; }
    log_event() { echo \"log: \$1\"; }
    source '$BATS_TEST_TMPDIR/power.sh'
    wait_for_ac_power
    echo DONE
  " 2>&1
  [ "$status" -eq 0 ]
  assert_contains "$output" "External power required"
  assert_contains "$output" "Please connect your charger"
  assert_contains "$output" "External power detected"
  assert_contains "$output" "DONE"
  assert_contains "$output" "log: POWER_GATE_WAITING"
  assert_contains "$output" "log: POWER_GATE_RELEASED"
}
