#!/usr/bin/env bats
# Self-update workflow tests.
#
# Network is shimmed with a fake `curl` on PATH that serves local
# files, and ~/.cache/sleep-after-claude is isolated via $HOME per
# test. These tests drive check_for_update() in isolation by sourcing
# the script's function block rather than running the whole watch
# loop (which needs a live Claude process and would hit pmset).

load 'lib/common'

setup() {
  setup_sandbox
  export SHELL=/bin/zsh
  # Extract check_for_update + its config globals + the ui_* helpers
  # it now calls (ui_spin, ui_confirm). Tests force the bash-fallback
  # path via SAC_NO_GUM=1 for deterministic output.
  {
    harness_preamble
    # Production's config block defines this; without it `set -u` in the
    # preamble correctly refuses to guess.
    echo 'SKIP_UPDATE_CHECK_FORCED=false'
    sed -n '/^UPDATE_CHECK_URL=/,/^UPDATE_CACHE_TTL_SECS=/p' "$REPO_ROOT/sleep-after-claude"
    sed -n '/^have_gum() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
    sed -n '/^have_glow() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
    sed -n '/^ui_confirm() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
    sed -n '/^ui_spin() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
    sed -n '/^check_for_update() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
  } >"$BATS_TEST_TMPDIR/check.sh"
  [ -s "$BATS_TEST_TMPDIR/check.sh" ]
  export SAC_NO_GUM=1
}

@test "update-check: skipped when --skip-update-check logic is honored" {
  run bash -c "
    SKIP_UPDATE_CHECK=true
    SLEEP_AFTER_CLAUDE_UPDATE_URL='file:///dev/null'
    SLEEP_AFTER_CLAUDE_INSTALLER_URL='file:///dev/null'
    STDIN_IS_TTY=false
    BOLD='' DIM='' GREEN='' YELLOW='' RED='' CYAN='' RESET=''
    print_step()  { echo \"> \$1\"; }
    print_ok()    { echo \"OK \$1\"; }
    print_warn()  { echo \"W  \$1\"; }
    log_event()   { :; }
    prompt_confirm() { return 1; }
    source '$BATS_TEST_TMPDIR/check.sh'
    check_for_update
    echo 'DONE'
  " 2>&1
  [ "$status" -eq 0 ]
  assert_contains "$output" "DONE"
  # No network-implying output whatsoever.
  assert_not_contains "$output" "newer version"
}

@test "update-check: respects the 24h rate-limit cache" {
  mkdir -p "$HOME/.cache/sleep-after-claude"
  # Write a "just now" timestamp so the check short-circuits.
  date +%s > "$HOME/.cache/sleep-after-claude/last-update-check"
  run bash -c "
    SKIP_UPDATE_CHECK=false
    SLEEP_AFTER_CLAUDE_UPDATE_URL='http://127.0.0.1:1/should-never-be-hit'
    SLEEP_AFTER_CLAUDE_INSTALLER_URL='http://127.0.0.1:1/should-never-be-hit'
    UPDATE_CACHE_DIR='$HOME/.cache/sleep-after-claude'
    UPDATE_CACHE_TTL_SECS=86400
    STDIN_IS_TTY=false
    BOLD='' DIM='' GREEN='' YELLOW='' RED='' CYAN='' RESET=''
    print_step()  { echo \"> \$1\"; }
    print_ok()    { echo \"OK \$1\"; }
    print_warn()  { echo \"W  \$1\"; }
    prompt_confirm() { return 1; }
    source '$BATS_TEST_TMPDIR/check.sh'
    check_for_update
    echo 'DONE'
  " 2>&1
  [ "$status" -eq 0 ]
  assert_contains "$output" "DONE"
  # The check short-circuited — so no newer-version banner.
  assert_not_contains "$output" "newer version"
}

@test "update-check: silently skipped when network times out" {
  # Point the URL at an unroutable address with a 1-second timeout
  # (overriding the default 5) via curl shim that always fails fast.
  shim curl 'exit 7'  # curl exit 7 = could not connect
  run bash -c "
    SKIP_UPDATE_CHECK=false
    SLEEP_AFTER_CLAUDE_UPDATE_URL='http://127.0.0.1:1/nope'
    SLEEP_AFTER_CLAUDE_INSTALLER_URL='http://127.0.0.1:1/nope'
    UPDATE_CACHE_DIR='$HOME/.cache/sleep-after-claude'
    UPDATE_CACHE_TTL_SECS=86400
    STDIN_IS_TTY=false
    BOLD='' DIM='' GREEN='' YELLOW='' RED='' CYAN='' RESET=''
    print_step()  { echo \"> \$1\"; }
    print_ok()    { echo \"OK \$1\"; }
    print_warn()  { echo \"W  \$1\"; }
    prompt_confirm() { return 1; }
    export PATH='$SHIM_DIR:'\$PATH
    source '$BATS_TEST_TMPDIR/check.sh'
    check_for_update
    echo 'DONE'
  " 2>&1
  [ "$status" -eq 0 ]
  assert_contains "$output" "DONE"
  assert_not_contains "$output" "newer version"
}

@test "update-check: flags the update when remote sha differs and stdin is not TTY" {
  # Craft a fake "remote" script with different content so sha differs.
  cat > "$BATS_TEST_TMPDIR/remote.sh" <<'EOF'
#!/usr/bin/env bash
# Pretend this is a newer version of sleep-after-claude.
echo "hello from newer version"
EOF
  run bash -c "
    SKIP_UPDATE_CHECK=false
    SLEEP_AFTER_CLAUDE_UPDATE_URL='file://$BATS_TEST_TMPDIR/remote.sh'
    SLEEP_AFTER_CLAUDE_INSTALLER_URL='file://$BATS_TEST_TMPDIR/remote.sh'
    UPDATE_CACHE_DIR='$HOME/.cache/sleep-after-claude'
    UPDATE_CACHE_TTL_SECS=86400
    STDIN_IS_TTY=false
    BOLD='' DIM='' GREEN='' YELLOW='' RED='' CYAN='' RESET=''
    print_step()  { echo \"> \$1\"; }
    print_ok()    { echo \"OK \$1\"; }
    print_warn()  { echo \"W  \$1\"; }
    prompt_confirm() { return 1; }
    source '$BATS_TEST_TMPDIR/check.sh'
    check_for_update
    echo 'DONE'
  " 2>&1
  [ "$status" -eq 0 ]
  assert_contains "$output" "newer version"
  assert_contains "$output" "skipping update prompt"
}

@test "update-check: no banner when local sha == remote sha" {
  # The function hashes BASH_SOURCE[0] — i.e., the file that defined
  # the function — so for this equality test the "remote" must be a
  # byte-identical copy of the sourced function file itself. (The
  # head-line sanity check requires it to start with #!/usr/bin/env
  # bash, so prepend that line to our check fixture before copying.)
  {
    echo '#!/usr/bin/env bash'
    cat "$BATS_TEST_TMPDIR/check.sh"
  } > "$BATS_TEST_TMPDIR/check-with-shebang.sh"
  cp "$BATS_TEST_TMPDIR/check-with-shebang.sh" "$BATS_TEST_TMPDIR/same.sh"
  run bash -c "
    SKIP_UPDATE_CHECK=false
    SLEEP_AFTER_CLAUDE_UPDATE_URL='file://$BATS_TEST_TMPDIR/same.sh'
    SLEEP_AFTER_CLAUDE_INSTALLER_URL='file://$BATS_TEST_TMPDIR/same.sh'
    UPDATE_CACHE_DIR='$HOME/.cache/sleep-after-claude'
    UPDATE_CACHE_TTL_SECS=86400
    STDIN_IS_TTY=false
    BOLD='' DIM='' GREEN='' YELLOW='' RED='' CYAN='' RESET=''
    print_step()  { echo \"> \$1\"; }
    print_ok()    { echo \"OK \$1\"; }
    print_warn()  { echo \"W  \$1\"; }
    prompt_confirm() { return 1; }
    source '$BATS_TEST_TMPDIR/check-with-shebang.sh'
    check_for_update
    echo 'DONE'
  " 2>&1
  [ "$status" -eq 0 ]
  assert_not_contains "$output" "newer version"
}
