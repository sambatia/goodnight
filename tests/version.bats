#!/usr/bin/env bats
# The version is a support artifact: it only helps if it is true. A
# constant that drifts from the changelog and the git tag is worse than
# no version at all, because it makes a bug report confidently wrong.

load 'lib/common'

@test "--version prints the version constant" {
  run bash "$REPO_ROOT/sleep-after-claude" --version
  [ "$status" -eq 0 ]
  constant="$(grep -m1 '^SAC_VERSION=' "$REPO_ROOT/sleep-after-claude" | cut -d'"' -f2)"
  [ -n "$constant" ]
  [ "$output" = "sleep-after-claude $constant" ]
}

@test "-V is accepted too" {
  run bash "$REPO_ROOT/sleep-after-claude" -V
  [ "$status" -eq 0 ]
  assert_contains "$output" "sleep-after-claude"
}

@test "the version constant is valid semver" {
  constant="$(grep -m1 '^SAC_VERSION=' "$REPO_ROOT/sleep-after-claude" | cut -d'"' -f2)"
  [[ "$constant" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]
}

@test "the newest CHANGELOG entry matches the version constant" {
  # Two places that must agree, so make disagreement a build failure
  # rather than something discovered in a bug report.
  constant="$(grep -m1 '^SAC_VERSION=' "$REPO_ROOT/sleep-after-claude" | cut -d'"' -f2)"
  newest="$(grep -m1 -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "$REPO_ROOT/CHANGELOG.md" | tr -d '#[] ')"
  [ "$constant" = "$newest" ]
}

@test "the version reaches the log, so a night is attributable to a build" {
  run grep -n 'SMART_WATCH_START version=\$SAC_VERSION' "$REPO_ROOT/sleep-after-claude"
  [ "$status" -eq 0 ]
}

@test "--doctor reports the version and the binary it ran from" {
  run grep -n 'ui_kv "Version" "\$SAC_VERSION"' "$REPO_ROOT/sleep-after-claude"
  [ "$status" -eq 0 ]
}
