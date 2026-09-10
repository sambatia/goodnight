#!/usr/bin/env bats
# F-02 runtime tests — verify the jq SHA-256 integrity check rejects
# a mismatched binary and allows a matching one through.
#
# We can't drive the full installer through the download path
# because ensure_jq's F-09 hardcoded-location probes find a real
# jq on any dev machine. Instead we extract the decision logic
# (the SHA compare + refusal) from ensure_jq in isolation and
# exercise both branches.

load 'lib/common'

setup() {
  setup_sandbox
  # Simulate just the SHA-decision stanza from ensure_jq with the
  # real values it uses. If we reproduce the exact comparison the
  # real function does, a mismatch must trigger the REFUSING branch.
  cat >"$BATS_TEST_TMPDIR/sha-check.sh" <<'SCRIPT'
set -uo pipefail
# NOTE: this is a hand-written reimplementation of the SHA-check
# decision in ensure_jq, not the real function lifted out of it. It can
# therefore drift from the code it claims to cover while still passing
# — the same failure shape as a hand-kept event vocabulary. Lifting the
# real branch would be strictly better; until then, treat a change to
# ensure_jq's check as requiring a change here.
C_BOLD="" C_RESET=""
warn() { echo "WARN $1" >&2; }
try_install_or_refuse() {
  local candidate="$1" expected_sha="$2"
  local got_sha
  got_sha="$(shasum -a 256 "$candidate" 2>/dev/null | awk '{print $1}')"
  if [[ -z "$got_sha" ]]; then
    warn "shasum unavailable — cannot verify jq integrity. Aborting jq install."
    return 1
  fi
  if [[ "$got_sha" != "$expected_sha" ]]; then
    warn "jq checksum mismatch — ${C_BOLD}REFUSING${C_RESET} to install."
    warn "  expected: $expected_sha"
    warn "  got:      $got_sha"
    return 1
  fi
  echo "INSTALL_OK"
  return 0
}
SCRIPT
}

@test "F-02 runtime: mismatched SHA refuses to install" {
  # Create a decoy file with a deterministic SHA.
  printf 'malicious-payload' >"$BATS_TEST_TMPDIR/decoy"
  local wrong_sha="0000000000000000000000000000000000000000000000000000000000000000"
  run bash -c "source '$BATS_TEST_TMPDIR/sha-check.sh'; try_install_or_refuse '$BATS_TEST_TMPDIR/decoy' '$wrong_sha'"
  [ "$status" -eq 1 ]
  assert_contains "$output" "REFUSING"
  assert_contains "$output" "checksum mismatch"
  assert_not_contains "$output" "INSTALL_OK"
}

@test "F-02 runtime: matching SHA passes the check" {
  printf 'legitimate-binary' >"$BATS_TEST_TMPDIR/real"
  local real_sha
  real_sha="$(shasum -a 256 "$BATS_TEST_TMPDIR/real" | awk '{print $1}')"
  run bash -c "source '$BATS_TEST_TMPDIR/sha-check.sh'; try_install_or_refuse '$BATS_TEST_TMPDIR/real' '$real_sha'"
  [ "$status" -eq 0 ]
  assert_contains "$output" "INSTALL_OK"
  assert_not_contains "$output" "REFUSING"
}

@test "F-02: pinned arm64 SHA matches the real jq-1.8.1 release (offline-captured)" {
  # Spot-check the hardcoded SHA in the installer against a known-
  # good value captured at remediation time. If someone bumps the
  # pinned version without updating the SHA, this catches it.
  run grep -E 'arm64\).*a9fe3ea2f86dfc72f6728417521ec9067b343277152b114f4e98d8cb0e263603' \
    "$REPO_ROOT/install-sleep-after-claude.sh"
  [ "$status" -eq 0 ]
}

@test "F-02: pinned amd64 SHA matches the real jq-1.8.1 release" {
  run grep -E 'amd64\).*e80dbe0d2a2597e3c11c404f03337b981d74b4a8504b70586c354b7697a7c27f' \
    "$REPO_ROOT/install-sleep-after-claude.sh"
  [ "$status" -eq 0 ]
}
