# Shared helpers for bats tests.
# Usage: load 'lib/common'   (inside a *.bats file)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

# Build a clean $HOME and $PATH prefix dir per test. bats auto-creates
# BATS_TEST_TMPDIR and removes it after each test.
setup_sandbox() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME" "$HOME/bin"
  export SHIM_DIR="$BATS_TEST_TMPDIR/shim"
  mkdir -p "$SHIM_DIR"
  export PATH="$SHIM_DIR:$PATH"
  # Ensure tests never pick up caller env that might leak state.
  unset SLEEP_AFTER_CLAUDE_INSTALLER_URL
  unset SLEEP_AFTER_CLAUDE_INSTALLER_SHA256
}

# Write an executable shim into $SHIM_DIR. The shim replaces one command
# on the PATH for the duration of the test.
#
# Usage: shim pmset 'printf "%s\n" "failing"; exit 1'
shim() {
  local name="$1"
  shift
  cat >"$SHIM_DIR/$name" <<EOF
#!/usr/bin/env bash
$*
EOF
  chmod +x "$SHIM_DIR/$name"
}

# Copy a fixture file into the shim so a command emits a known payload.
# Usage: shim_fixture pmset fixtures/pmset-assertions-clear.txt
shim_fixture() {
  local name="$1"
  local fixture_rel="$2"
  local fixture_path="$REPO_ROOT/tests/$fixture_rel"
  if [[ ! -f "$fixture_path" ]]; then
    echo "fixture missing: $fixture_path" >&2
    return 1
  fi
  cat >"$SHIM_DIR/$name" <<EOF
#!/usr/bin/env bash
cat "$fixture_path"
exit 0
EOF
  chmod +x "$SHIM_DIR/$name"
}

assert_contains() {
  local haystack="$1" needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "assert_contains FAILED" >&2
    echo "  expected to contain: $needle" >&2
    echo "  actual output:" >&2
    printf '    %s\n' "$haystack" >&2
    return 1
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "assert_not_contains FAILED — found: $needle" >&2
    return 1
  fi
}

# Lift selected function definitions (plus the shared jq predicate) out
# of the real script into a sourceable file, so unit tests exercise the
# shipped implementation instead of a copy that can drift from it.
#
# Usage: extract_from_script "$BATS_TEST_TMPDIR/fns.sh" hooks_health count_busy_sessions
extract_from_script() {
  local out="$1"
  shift
  # Reproduce the script's own shell options. Without these the
  # extracted functions run under laxer rules than they ever will in
  # production, and the harness silently blesses bugs it cannot see —
  # a `set -o pipefail` double-emit shipped exactly this way.
  printf 'set -uo pipefail\n' >"$out"
  sed -n "/^HOOK_MATCH_JQ=/,/;'\$/p" "$REPO_ROOT/sleep-after-claude" >>"$out"
  local fn
  for fn in "$@"; do
    sed -n "/^${fn}() {\$/,/^}\$/p" "$REPO_ROOT/sleep-after-claude" >>"$out"
    printf '\n' >>"$out"
  done
  [[ -s "$out" ]]
}
