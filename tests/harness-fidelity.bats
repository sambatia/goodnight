#!/usr/bin/env bats
# A harness that runs lifted production code under laxer shell options
# than production grades that code by rules it will never face, and
# blesses bugs it structurally cannot observe.
#
# This is not hypothetical. A `set -o pipefail` double-emit in
# agent_cpu_centiseconds shipped through CI and human review because the
# harness testing it ran without pipefail: the test asserted the right
# value and passed, while the function returned "0\n0" in production.
#
# Two harnesses were also silently under-specified — ui_confirm and
# check_for_update ran with variables unset that production always
# defines, so `[[ "$UNSET" == true ]]` was quietly false and the tests
# passed for the wrong reason.
#
# These tests fail if any of that creeps back.

load 'lib/common'

# Every .bats file that executes lifted production code, i.e. sources a
# generated harness or splices a sed-lifted block into a shell it runs.
executing_files() {
  local f
  for f in "$REPO_ROOT"/tests/*.bats; do
    case "$(basename "$f")" in harness-fidelity.bats) continue ;; esac
    # Lifted code is either sourced into a shell we start, or spliced
    # into a `bash -c` body. A whole script copied to TMPDIR and run
    # with `bash file` carries its own shebang and options, so it is
    # already running under its own rules and is not our problem.
    # A bare `$(sed …)` on its own line is spliced into a shell body.
    # `block="$(sed …)"` captures the text for assert_contains and is
    # never executed, so it needs no options.
    # Both patterns single-quoted. In double quotes bash turns `\$` into
    # a bare `$`, which ERE then reads as an end-anchor — the pattern
    # silently matches nothing and this guard passes vacuously. Which it
    # did, on its first run: the check built to catch tests that pass
    # for the wrong reason was itself passing for the wrong reason.
    if grep -qE 'source .\$BATS_TEST_TMPDIR' "$f" ||
      grep -qE '^[[:space:]]*\$\(sed -n' "$f"; then
      basename "$f"
    fi
  done
}

@test "the shared preamble states production's options exactly" {
  # One source of truth. If sleep-after-claude changes its options, this
  # is the single place that has to follow.
  run bash -c "source '$REPO_ROOT/tests/lib/common.bash'; harness_preamble"
  [ "$status" -eq 0 ]
  actual="$(grep -m1 '^set -' "$REPO_ROOT/sleep-after-claude")"
  assert_contains "$output" "$actual"
}

@test "extract_from_script emits the preamble first" {
  out="$BATS_TEST_TMPDIR/x.sh"
  extract_from_script "$out" elapsed_label
  [ "$(head -1 "$out")" = "set -uo pipefail" ]
}

@test "every harness that runs lifted code applies production options" {
  local missing=""
  for f in $(executing_files); do
    grep -qE 'harness_preamble|extract_from_script|set -uo pipefail' "$REPO_ROOT/tests/$f" ||
      missing+=" $f"
  done
  if [ -n "$missing" ]; then
    echo "harnesses executing lifted code without production options:$missing" >&2
    echo "add 'harness_preamble' to the generated harness, or route it" >&2
    echo "through extract_from_script." >&2
    return 1
  fi
}

@test "no harness silently re-enables laxer options" {
  # `set +u` inside a harness would defeat the whole point.
  # Exclude this file: it necessarily contains the pattern it forbids.
  run bash -c "grep -rn 'set +u\|set +o pipefail' '$REPO_ROOT/tests' | grep -v harness-fidelity.bats"
  [ "$status" -ne 0 ]
}
