#!/usr/bin/env bats
# The waiting spinner must redraw in place, not accumulate.
#
# `\033[K` erases from the cursor to the end of the row it is on, and
# `\r` returns to the start of that same row. Neither reaches a row the
# cursor has already left, so a status line longer than the terminal
# wraps and every later redraw strands the row above it.
#
# Observed in production: a 21-minute wait in a phone-sized herdr pane
# filled the scrollback with hundreds of copies of
# "Waiting — 1 session(s) working…". Reproduced in real tmux terminals —
# 5 redraws left 5 rows at 49 columns and 1 row at 80.
#
# The ordinary waiting line measures 52 cells; herdr's mobile layout
# gives panes 49, and that shrink is global, so a phone attaching
# narrows the desktop's panes too.

load 'lib/common'

setup() {
  setup_sandbox
  extract_from_script "$BATS_TEST_TMPDIR/status.sh" term_cols print_status
  {
    echo 'USE_SPINNER=true'
    echo 'RESET="" DIM="" CYAN="" GREEN="" YELLOW=""'
  } >>"$BATS_TEST_TMPDIR/status.sh"
  grep -q '^print_status() {' "$BATS_TEST_TMPDIR/status.sh"
  grep -q '^term_cols() {' "$BATS_TEST_TMPDIR/status.sh"
}

# Visible width of a rendered status line: strip the carriage return and
# the erase sequence, which occupy no cells.
rendered_width() {
  local cols="$1" body="$2"
  COLUMNS="$cols" bash -c "
    source '$BATS_TEST_TMPDIR/status.sh'
    out=\"\$(print_status '' '*' '$body')\"
    out=\"\${out#\$'\r'}\"
    out=\"\${out#\$'\033'[K}\"
    printf '%s' \"\${#out}\"
  "
}

@test "a long status line is clipped to fit a narrow pane" {
  # 49 columns is what herdr hands a pane in mobile layout.
  run rendered_width 49 "Waiting — 1 session(s) working…  21m15s elapsed"
  [ "$status" -eq 0 ]
  [ "$output" -lt 49 ]
}

@test "the clip holds across every plausible pane width" {
  local body="Waiting — 1 session(s) working…  21m15s elapsed"
  for cols in 20 30 40 49 60 72 80 100 200; do
    run rendered_width "$cols" "$body"
    [ "$status" -eq 0 ]
    if [ "$output" -ge "$cols" ]; then
      echo "width $cols produced $output cells — it would wrap and strand a row" >&2
      return 1
    fi
  done
}

@test "a short status line is left alone" {
  # Clipping must not fire when there is room; the ellipsis would be a
  # lie about truncated content.
  run rendered_width 200 "All agents idle…  sleeping in 4m 5s"
  [ "$status" -eq 0 ]
  run bash -c "
    source '$BATS_TEST_TMPDIR/status.sh'
    COLUMNS=200 print_status '' '*' 'All agents idle…  sleeping in 4m 5s'"
  assert_contains "$output" "sleeping in 4m 5s"
  assert_not_contains "$output" "…  sleeping in 4m 5"$'…'
}

@test "term_cols does not trust tput, which lies inside a command substitution" {
  # `tput cols` cannot query the window when its stdout is a pipe, and
  # returns terminfo's static default instead. Measured live in a
  # 49-column tmux pane: tput 80, stty 49. Trusting it disabled the
  # clipping in exactly the case that needed it.
  block="$(sed -n '/^term_cols() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude")"
  assert_contains "$block" 'stty size </dev/tty'
  assert_not_contains "$block" 'c="$(tput cols'
}

@test "term_cols falls back rather than returning an empty width" {
  # No controlling terminal, no COLUMNS: must still yield a usable
  # number, or the arithmetic below it fails under `set -u`.
  run bash -c "
    source '$BATS_TEST_TMPDIR/status.sh'
    unset COLUMNS
    term_cols </dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
  [ "$output" -gt 0 ]
}

@test "an absurdly narrow pane still yields a printable line" {
  run rendered_width 10 "Waiting — 1 session(s) working…  21m15s elapsed"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
}

@test "exactly one place composes a status redraw" {
  # Three sites used to hand-roll `\r\033[K` with unbounded content: the
  # idle countdown, the waiting line, and the charger wait. Centralising
  # them in print_status is what makes the clip unavoidable, so the
  # count of composers must stay at exactly one — the implementation
  # itself. A fourth hand-rolled site would reintroduce the flood.
  n="$(grep -c 'printf "\\r\\033\[K  ' "$REPO_ROOT/sleep-after-claude" || true)"
  [ "${n%%$'\n'*}" = "1" ]
  # And that one lives inside print_status, not somewhere else.
  block="$(sed -n '/^print_status() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude")"
  assert_contains "$block" 'printf "\r\033[K  '
  # The call sites delegate.
  loop="$(sed -n '/^smart_watch_loop() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude")"
  assert_contains "$loop" 'print_status "$GREEN"'
  assert_contains "$loop" 'print_status "$CYAN"'
}
