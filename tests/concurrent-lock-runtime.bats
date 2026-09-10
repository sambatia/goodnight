#!/usr/bin/env bats
# F-07 runtime tests — drive two real bash subprocesses racing on the
# lock and assert that exactly one acquires it. Complements the
# isolated-unit tests in tests/concurrent-lock.bats.

load 'lib/common'

setup() {
  setup_sandbox
  export GOODNIGHT_LOCK_DIR="$HOME/.local/state/goodnight/lock"
  # Assemble a standalone runner script that sources the lock helpers
  # and tries to acquire. Prints "ACQUIRED" or "REJECTED".
  cat >"$BATS_TEST_TMPDIR/try-lock.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
GOODNIGHT_LOCK_DIR="$GOODNIGHT_LOCK_DIR"
GOODNIGHT_LOCK_ACQUIRED=false
BOLD="" RESET=""
print_error() { echo "ERR \$1" >&2; }
print_step()  { echo "STEP \$1"; }
print_warn()  { echo "WARN \$1"; }
EOF
  sed -n '/^acquire_goodnight_lock() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude" \
    >>"$BATS_TEST_TMPDIR/try-lock.sh"
  sed -n '/^release_goodnight_lock() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude" \
    >>"$BATS_TEST_TMPDIR/try-lock.sh"
  cat >>"$BATS_TEST_TMPDIR/try-lock.sh" <<'EOF'
# Run: acquire, sleep N, release. If acquire fails, print REJECTED.
if acquire_goodnight_lock; then
  echo ACQUIRED
  sleep "${HOLD_FOR:-2}"
  release_goodnight_lock
else
  echo REJECTED
fi
EOF
  chmod +x "$BATS_TEST_TMPDIR/try-lock.sh"
}

@test "F-07 runtime: two concurrent processes — exactly one acquires" {
  # Start two tries simultaneously. The first should print
  # "ACQUIRED", the second should print "REJECTED" (it sees the
  # alive holder). Race is resolved by kernel mkdir atomicity.
  HOLD_FOR=3 bash "$BATS_TEST_TMPDIR/try-lock.sh" >"$BATS_TEST_TMPDIR/a.out" 2>&1 &
  local pid_a=$!
  # Tiny nudge so the first has a chance to mkdir.
  sleep 0.3
  HOLD_FOR=1 bash "$BATS_TEST_TMPDIR/try-lock.sh" >"$BATS_TEST_TMPDIR/b.out" 2>&1 &
  local pid_b=$!
  wait "$pid_a" "$pid_b" 2>/dev/null || true

  run cat "$BATS_TEST_TMPDIR/a.out" "$BATS_TEST_TMPDIR/b.out"
  # Exactly one ACQUIRED and one REJECTED across both outputs.
  local n_ok n_rej
  n_ok="$(grep -c '^ACQUIRED$' "$BATS_TEST_TMPDIR/a.out" "$BATS_TEST_TMPDIR/b.out" | awk -F: '{sum+=$2} END {print sum}')"
  n_rej="$(grep -c '^REJECTED$' "$BATS_TEST_TMPDIR/a.out" "$BATS_TEST_TMPDIR/b.out" | awk -F: '{sum+=$2} END {print sum}')"
  [ "$n_ok" -eq 1 ]
  [ "$n_rej" -eq 1 ]
}

@test "F-07 runtime: lock is released after holder exits → second invocation succeeds" {
  # First process holds lock for 1s then exits. Second waits 2s and
  # tries — should succeed because lock is released.
  HOLD_FOR=1 bash "$BATS_TEST_TMPDIR/try-lock.sh" >"$BATS_TEST_TMPDIR/first.out" 2>&1
  # First should have acquired.
  run cat "$BATS_TEST_TMPDIR/first.out"
  assert_contains "$output" "ACQUIRED"
  [ ! -d "$GOODNIGHT_LOCK_DIR" ]

  # Now second invocation should also acquire cleanly.
  HOLD_FOR=0 bash "$BATS_TEST_TMPDIR/try-lock.sh" >"$BATS_TEST_TMPDIR/second.out" 2>&1
  run cat "$BATS_TEST_TMPDIR/second.out"
  assert_contains "$output" "ACQUIRED"
}

@test "F-07 runtime: stale lock (dead holder PID) is reclaimed at acquisition" {
  # Fake a lock held by a PID that doesn't exist. A fresh invocation
  # must see it's stale, reclaim, and succeed.
  mkdir -p "$GOODNIGHT_LOCK_DIR"
  echo "999999" >"$GOODNIGHT_LOCK_DIR/pid"
  HOLD_FOR=0 bash "$BATS_TEST_TMPDIR/try-lock.sh" >"$BATS_TEST_TMPDIR/reclaim.out" 2>&1
  run cat "$BATS_TEST_TMPDIR/reclaim.out"
  assert_contains "$output" "Stale lock"
  assert_contains "$output" "ACQUIRED"
}
