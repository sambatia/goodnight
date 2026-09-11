#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
#  install-sleep-after-claude.sh
#  Self-extracting installer for sleep-after-claude + goodnight alias.
#
#  Usage:
#    bash install-sleep-after-claude.sh
#    curl -fsSL <url> | bash             # piped-install path (re-downloads
#                                          self into temp file, validates
#                                          size/markers/optional SHA, then
#                                          extracts)
#
#  What it does, in order:
#    1. Verifies macOS.
#    2. Creates ~/bin if needed; adds it to PATH in the user's shell rc.
#    3. Backs up any existing sleep-after-claude install.
#    4. Extracts the embedded script to ~/bin/sleep-after-claude.
#    5. Detects the shell (zsh/bash) and installs a deduplicated
#       `goodnight` alias; unknown shells get manual instructions only.
#    6. Auto-installs jq into ~/bin/jq (SHA-pinned per arch, non-fatal
#       on failure — goodnight falls back to --watch-pid mode without jq).
#    7. Auto-installs Claude Code hooks into ~/.claude/settings.json so
#       --smart idle detection works on first run. Gated by jq
#       availability and SAC_SKIP_HOOK_INSTALL=1 (opt-out).
#    8. Verifies the install by running `--help` on the extracted tool.
#    9. Drains its own stdin on piped-install exit with a bounded 5s
#       timeout (F-11) so `curl | bash && next_cmd` chains don't hang.
#
#  Environment variable overrides:
#    SLEEP_AFTER_CLAUDE_INSTALLER_URL      — alt source URL
#    SLEEP_AFTER_CLAUDE_INSTALLER_SHA256   — require this SHA on piped-install
#    SAC_JQ_SHA256                         — override the expected jq SHA
#    SAC_SKIP_HOOK_INSTALL=1               — skip ~/.claude/settings.json edit
# ─────────────────────────────────────────────────────────────────

set -uo pipefail

INSTALLER_STDOUT_IS_TTY=false
[[ -t 1 ]] && INSTALLER_STDOUT_IS_TTY=true

# ── Colours (TTY only) ────────────────────────────────────────────
if [[ "$INSTALLER_STDOUT_IS_TTY" == true ]]; then
  # $'...' so vars contain real ESC bytes — robust to printf %s and
  # plain echo without -e.
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'
  C_RED=$'\033[31m'
  C_BLUE=$'\033[34m'
else
  C_RESET=""
  C_BOLD=""
  C_DIM=""
  C_GREEN=""
  C_YELLOW=""
  C_CYAN=""
  C_RED=""
  C_BLUE=""
fi

# ── Terminal UI layer ─────────────────────────────────────────────
# The installer can be run as `curl | bash`, from a local file, or
# inside CI. gum/glow are optional: when present in a real terminal we
# use them for spinners, panels, and markdown summaries; otherwise the
# same messages render as plain, readable Bash output.
have_gum() {
  [[ "${SAC_NO_GUM:-}" != "1" ]] || return 1
  [[ "$INSTALLER_STDOUT_IS_TTY" == true ]] || return 1
  if [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ]] && [[ "${SAC_FORCE_GUM:-}" != "1" ]]; then
    return 1
  fi
  command -v gum >/dev/null 2>&1
}

have_glow() {
  [[ "${SAC_NO_GLOW:-}" != "1" ]] || return 1
  [[ "$INSTALLER_STDOUT_IS_TTY" == true ]] || return 1
  command -v glow >/dev/null 2>&1
}

ui_markdown() {
  if have_glow; then
    glow -
  else
    cat
  fi
}

ui_header() {
  echo ""
  if have_gum; then
    gum style --foreground 39 --bold -- "sleep-after-claude installer"
    gum style --foreground 245 -- "Installs goodnight, jq support, and Claude Code idle hooks."
    gum style --foreground 240 -- "────────────────────────────────────────────"
  else
    echo -e "  ${C_BOLD}${C_BLUE}sleep-after-claude installer${C_RESET}"
    echo -e "  ${C_DIM}Installs goodnight, jq support, and Claude Code idle hooks.${C_RESET}"
    echo -e "  ${C_DIM}─────────────────────────────────────────${C_RESET}"
  fi
  echo ""
}

ui_spin() {
  local title="$1"
  shift
  [[ "${1:-}" == "--" ]] && shift
  if have_gum; then
    gum spin --spinner minidot --title "$title" --show-output -- "$@"
    return $?
  fi
  say "$title"
  "$@"
}

ui_panel() {
  local kind="$1"
  shift
  local title="$1"
  shift
  local -a lines=("$@")
  if have_gum; then
    local fg border
    case "$kind" in
      success)
        fg=46
        border=46
        ;;
      warning)
        fg=214
        border=214
        ;;
      danger)
        fg=196
        border=196
        ;;
      *)
        fg=39
        border=39
        ;;
    esac
    local title_block content_block
    title_block="$(gum style --foreground "$fg" --bold -- "$title")"
    content_block="$(printf '%s\n' "${lines[@]}" | gum style)"
    gum style \
      --border rounded \
      --border-foreground "$border" \
      --padding "1 2" \
      --margin "1 0" \
      -- "$title_block" "" "$content_block"
    return
  fi

  local color="$C_BLUE"
  case "$kind" in
    success) color="$C_GREEN" ;;
    warning) color="$C_YELLOW" ;;
    danger) color="$C_RED" ;;
  esac
  echo ""
  echo -e "  ${C_BOLD}${color}${title}${C_RESET}"
  echo -e "  ${C_DIM}─────────────────────────────────────────${C_RESET}"
  local line
  for line in "${lines[@]}"; do
    [[ -z "$line" ]] && echo "" || echo -e "  ${line}"
  done
  echo ""
}

say() { echo -e "  ${C_CYAN}›${C_RESET} $1"; }
ok() { echo -e "  ${C_GREEN}✔${C_RESET} $1"; }
warn() { echo -e "  ${C_YELLOW}⚠${C_RESET}  $1"; }
fail() {
  if have_gum; then
    ui_panel danger "Installer error" "$1" >&2
  else
    echo -e "  ${C_RED}✖${C_RESET} $1" >&2
  fi
}

# ── Header ────────────────────────────────────────────────────────
ui_header

# ── 1. macOS check ────────────────────────────────────────────────
if [[ "$(uname)" != "Darwin" ]]; then
  fail "This installer only supports macOS."
  exit 1
fi
ok "macOS detected ($(sw_vers -productVersion 2>/dev/null || echo unknown))"

# ── 2. Ensure ~/bin exists ────────────────────────────────────────
if [[ ! -d "$HOME/bin" ]]; then
  mkdir -p "$HOME/bin"
  say "Created ~/bin"
fi
# shellcheck disable=SC2088 # Intentional user-facing display — "~/bin" reads better than an expanded absolute path
ok "~/bin ready"

# ── 3. ~/bin PATH handling — deferred until we know the rc file ──
# Step 8 below adds `export PATH="$HOME/bin:$PATH"` to the shell rc
# when the alias is installed. This makes `sleep-after-claude` directly
# callable in future shell sessions without the user ever needing to
# touch PATH manually.

# ── 4. Backup existing install ────────────────────────────────────
TARGET="$HOME/bin/sleep-after-claude"
if [[ -f "$TARGET" ]]; then
  cp "$TARGET" "${TARGET}.bak"
  ok "Previous version backed up to ~/bin/sleep-after-claude.bak"
fi

# When run as `curl ... | bash`, BASH_SOURCE[0] and $0 are "bash" (not a file),
# so awk can't read the installer. In that case, re-download it to a temp file.
# The re-download is a second trust hop: we warn the user, sanity-check the
# body, and optionally verify an sha256 pin if the caller provided one.
SELF="${BASH_SOURCE[0]:-$0}"
TMP_SELF=""
if [[ ! -f "$SELF" ]]; then
  SOURCE_URL="${SLEEP_AFTER_CLAUDE_INSTALLER_URL:-https://raw.githubusercontent.com/sambatia/goodnight/main/install-sleep-after-claude.sh}"
  # Calm single-line message (this is the normal `curl | bash` path —
  # not an error). Advanced users wanting SHA-256 provenance can find
  # the env-var recipe in the README; we don't surface it here because
  # it's noise for the 99% non-technical install flow.
  TMP_SELF="$(mktemp -t sleep-after-claude-installer.XXXXXX)"
  if ! ui_spin "Fetching installer payload from $SOURCE_URL" -- curl -fsSL "$SOURCE_URL" -o "$TMP_SELF"; then
    fail "Could not re-download installer from $SOURCE_URL"
    rm -f "$TMP_SELF"
    exit 1
  fi

  # Sanity-check the downloaded payload before trusting it.
  # 1. Size must be within a plausible envelope (guards against HTML error
  #    pages, truncated CDN responses, and absurd payloads).
  TMP_SIZE="$(wc -c <"$TMP_SELF" | tr -d ' ')"
  if ! [[ "$TMP_SIZE" =~ ^[0-9]+$ ]] || ((TMP_SIZE < 2000 || TMP_SIZE > 524288)); then
    fail "Downloaded installer has implausible size (${TMP_SIZE} bytes) — aborting."
    rm -f "$TMP_SELF"
    exit 1
  fi
  # 2. Must contain both payload markers.
  if ! grep -q '^__SCRIPT_START__$' "$TMP_SELF" || ! grep -q '^__SCRIPT_END__$' "$TMP_SELF"; then
    fail "Downloaded installer is missing payload markers — aborting."
    rm -f "$TMP_SELF"
    exit 1
  fi
  # 3. Optional sha256 pin.
  if [[ -n "${SLEEP_AFTER_CLAUDE_INSTALLER_SHA256:-}" ]]; then
    if ! command -v shasum >/dev/null 2>&1; then
      fail "shasum not available — cannot verify SLEEP_AFTER_CLAUDE_INSTALLER_SHA256."
      rm -f "$TMP_SELF"
      exit 1
    fi
    GOT_SHA="$(shasum -a 256 "$TMP_SELF" | awk '{print $1}')"
    if [[ "$GOT_SHA" != "$SLEEP_AFTER_CLAUDE_INSTALLER_SHA256" ]]; then
      fail "Checksum mismatch — expected $SLEEP_AFTER_CLAUDE_INSTALLER_SHA256, got $GOT_SHA"
      rm -f "$TMP_SELF"
      exit 1
    fi
    ok "Installer checksum verified."
  fi

  SELF="$TMP_SELF"
fi

if ! ui_spin "Extracting sleep-after-claude to ~/bin" -- bash -c \
  'awk '\''/^__SCRIPT_START__$/{flag=1; next} /^__SCRIPT_END__$/{flag=0} flag'\'' "$1" >"$2"' \
  _ "$SELF" "$TARGET"; then
  fail "Extraction failed — installer file may be corrupted."
  [[ -n "$TMP_SELF" ]] && rm -f "$TMP_SELF"
  exit 1
fi

[[ -n "$TMP_SELF" ]] && rm -f "$TMP_SELF"

if [[ ! -s "$TARGET" ]]; then
  fail "Extraction failed — installer file may be corrupted."
  exit 1
fi

chmod +x "$TARGET"
ok "Extracted $(wc -l <"$TARGET" | tr -d ' ') lines to ~/bin/sleep-after-claude"

# ── 6. Syntax-check the extracted script ──────────────────────────
if ui_spin "Checking script syntax" -- bash -n "$TARGET"; then
  ok "Script syntax valid"
else
  fail "Extracted script has syntax errors — aborting."
  exit 1
fi

# ── 7. Detect shell + rc file ─────────────────────────────────────
SHELL_NAME="$(basename "${SHELL:-/bin/zsh}")"
RC=""
case "$SHELL_NAME" in
  zsh)
    RC="$HOME/.zshrc"
    ;;
  bash)
    if [[ -f "$HOME/.bash_profile" ]]; then
      RC="$HOME/.bash_profile"
    else
      RC="$HOME/.bashrc"
    fi
    ;;
esac

# ── 8. Add alias (idempotent, dedupes across reinstalls) ──────────
if [[ -z "$RC" ]]; then
  warn "Unknown shell ($SHELL_NAME) — skipping alias install."
  warn "Add this line to your shell rc manually:"
  warn "  alias goodnight=\"$HOME/bin/sleep-after-claude\""
else
  [[ -f "$RC" ]] || touch "$RC"

  # Remove any prior `alias goodnight=` lines (and the header comment
  # directly above them, if any) so reinstalls don't duplicate or orphan
  # lines pointing at stale paths. Then re-append the current line.
  if grep -q '^[[:space:]]*alias[[:space:]]\+goodnight=' "$RC" 2>/dev/null; then
    TMP_RC="$(mktemp)"
    awk '
      /^# sleep-after-claude shortcut \(added by installer\)$/ { skip_next_if_alias=1; next }
      skip_next_if_alias==1 && /^[[:space:]]*alias[[:space:]]+goodnight=/ { skip_next_if_alias=0; next }
      /^[[:space:]]*alias[[:space:]]+goodnight=/ { skip_next_if_alias=0; next }
      { skip_next_if_alias=0; print }
    ' "$RC" >"$TMP_RC" && mv "$TMP_RC" "$RC"
    say "Removed existing 'goodnight' alias line(s) in $(basename "$RC")"
  fi

  {
    echo ''
    echo '# sleep-after-claude shortcut (added by installer)'
    echo "alias goodnight=\"$HOME/bin/sleep-after-claude\""
  } >>"$RC"
  ok "Alias 'goodnight' added to $(basename "$RC")"

  # Ensure ~/bin is on PATH for future shell sessions. Dedupe the same
  # way as the alias line so reinstalls don't accumulate duplicates.
  PATH_LINE="export PATH=\"\$HOME/bin:\$PATH\""
  if grep -qF "$PATH_LINE" "$RC" 2>/dev/null; then
    : # already present, leave it
  else
    # Also detect near-equivalents (e.g. quoted differently) so we
    # don't append a second PATH line that contradicts a prior manual
    # edit.
    if grep -qE '^[[:space:]]*export[[:space:]]+PATH=.*\$HOME/bin' "$RC" 2>/dev/null ||
      grep -qE '^[[:space:]]*export[[:space:]]+PATH=.*'"$HOME/bin" "$RC" 2>/dev/null; then
      : # some PATH export mentioning $HOME/bin already exists
    else
      {
        echo ''
        echo '# Put ~/bin on PATH so sleep-after-claude is callable directly (added by installer)'
        echo "$PATH_LINE"
      } >>"$RC"
      # shellcheck disable=SC2088 # Intentional user-facing display
      ok "~/bin added to PATH in $(basename "$RC")"
    fi
  fi
fi

# ── 8a. Ensure runtime dependencies (jq) ──────────────────────────
# Goodnight's default mode uses Claude Code hooks, and hook install /
# detection requires `jq`. macOS doesn't ship with jq, so a clean
# laptop would fall back to --watch-pid mode without it. To make the
# install truly zero-touch, we auto-fetch a static jq binary from the
# jqlang/jq GitHub releases and drop it in ~/bin (already on PATH
# from step 8 above).
#
# Failure here is non-fatal: goodnight still works in --watch-pid
# mode, and the user can install jq later. We just print a clear
# message.
ensure_jq() {
  # Prefer any already-installed jq. F-09: also probe common locations
  # in case the user installed jq before this run but hasn't sourced
  # the updated PATH yet.
  if command -v jq >/dev/null 2>&1; then
    ok "jq already installed: $(jq --version 2>/dev/null || echo '?')"
    return 0
  fi
  local candidate
  local candidate_dir
  for candidate in "$HOME/bin/jq" "/opt/homebrew/bin/jq" "/usr/local/bin/jq" "/usr/bin/jq"; do
    if [[ -x "$candidate" ]] && "$candidate" --version >/dev/null 2>&1; then
      ok "jq already installed at $candidate: $("$candidate" --version)"
      candidate_dir="$(dirname "$candidate")"
      export PATH="$candidate_dir:$PATH"
      return 0
    fi
  done

  local arch jq_url jq_tmp jq_dest jq_version expected_sha got_sha
  case "$(uname -m)" in
    arm64) arch="arm64" ;;
    x86_64) arch="amd64" ;;
    *)
      warn "Unknown CPU architecture '$(uname -m)' — cannot auto-install jq."
      warn "Install manually: ${C_BOLD}brew install jq${C_RESET} — then re-run this installer."
      return 1
      ;;
  esac

  # Pinned to a known-good stable release. Bump = update version AND
  # both SHA-256 values below. To rotate, fetch and compute with:
  #   curl -fsSL "$jq_url" | shasum -a 256
  jq_version="1.8.1"
  # F-02: Expected SHA-256 per arch. Mismatch → hard refusal. An
  # override is honored via SAC_JQ_SHA256 for users who need to pin
  # a different jq build (e.g., bleeding-edge version).
  case "$arch" in
    arm64) expected_sha="a9fe3ea2f86dfc72f6728417521ec9067b343277152b114f4e98d8cb0e263603" ;;
    amd64) expected_sha="e80dbe0d2a2597e3c11c404f03337b981d74b4a8504b70586c354b7697a7c27f" ;;
  esac
  expected_sha="${SAC_JQ_SHA256:-$expected_sha}"

  jq_url="https://github.com/jqlang/jq/releases/download/jq-${jq_version}/jq-macos-${arch}"
  jq_dest="$HOME/bin/jq"
  jq_tmp="$(mktemp -t goodnight-jq.XXXXXX)"

  if ! ui_spin "Downloading jq ${jq_version} for macOS (${arch})" -- \
    curl -fsSL --max-time 60 -o "$jq_tmp" "$jq_url"; then
    warn "Could not download jq from GitHub (offline? firewall?)."
    warn "Install later with: ${C_BOLD}brew install jq${C_RESET}"
    warn "Goodnight will run in --watch-pid mode until then."
    rm -f "$jq_tmp"
    return 1
  fi

  # Basic sanity: plausible binary size (catches CDN error pages
  # before the SHA-256 check has to do real work).
  local size
  size="$(wc -c <"$jq_tmp" | tr -d ' ')"
  if ! [[ "$size" =~ ^[0-9]+$ ]] || ((size < 500000 || size > 10000000)); then
    warn "Downloaded jq has implausible size (${size} bytes) — skipping."
    rm -f "$jq_tmp"
    return 1
  fi

  # F-02: SHA-256 integrity check against the pinned value. A
  # mismatch indicates supply-chain compromise, wrong mirror, or the
  # release binary was re-uploaded (requires re-pinning on our side).
  # In any of those cases we refuse to install.
  got_sha="$(shasum -a 256 "$jq_tmp" 2>/dev/null | awk '{print $1}')"
  if [[ -z "$got_sha" ]]; then
    warn "shasum unavailable — cannot verify jq integrity. Aborting jq install."
    rm -f "$jq_tmp"
    return 1
  fi
  if [[ "$got_sha" != "$expected_sha" ]]; then
    warn "jq checksum mismatch — ${C_BOLD}REFUSING${C_RESET} to install."
    warn "  expected: $expected_sha"
    warn "  got:      $got_sha"
    warn "If jq was legitimately re-released, set ${C_BOLD}SAC_JQ_SHA256=<expected>${C_RESET} and re-run."
    rm -f "$jq_tmp"
    return 1
  fi

  chmod +x "$jq_tmp"
  # Strip the macOS quarantine attribute so gatekeeper doesn't flag
  # this first-run-from-a-script binary.
  xattr -d com.apple.quarantine "$jq_tmp" 2>/dev/null || true

  if ! "$jq_tmp" --version >/dev/null 2>&1; then
    warn "Downloaded jq binary didn't run (macOS gatekeeper? wrong arch?)."
    warn "Install manually: ${C_BOLD}brew install jq${C_RESET}"
    rm -f "$jq_tmp"
    return 1
  fi

  mv "$jq_tmp" "$jq_dest"
  # Ensure the newly-installed jq is on PATH for the rest of this
  # installer run (future sessions pick it up via the rc file edit
  # in step 8).
  export PATH="$HOME/bin:$PATH"
  ok "jq ${jq_version} installed at ~/bin/jq (sha256 verified)"
}

echo ""
say "Ensuring runtime dependencies..."
ensure_jq || true

# ── 9. Verification ───────────────────────────────────────────────
echo ""
if ui_spin "Running quick verification" -- bash -c 'TARGET="$1"; "$TARGET" --help >/dev/null 2>&1' _ "$TARGET"; then
  ok "Script executes successfully"
else
  fail "Script failed to run --help. Try manually: ~/bin/sleep-after-claude --help"
  exit 1
fi

# ── 9a. Claude Code hook setup ────────────────────────────────────
# Default `goodnight` uses hook-based idle detection. Try to install
# the hooks automatically so the user gets the expected behavior on
# first run. Requires jq — if absent, emit a friendly note and skip
# (the installed script still works in --watch-pid mode until the
# user installs jq and runs `goodnight --install-hooks`).
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
hooks_already_installed() {
  [[ -f "$CLAUDE_SETTINGS" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -e '(.hooks.Stop // []) + (.hooks.UserPromptSubmit // []) | map(select(._managed_by == "goodnight")) | length > 0' \
    "$CLAUDE_SETTINGS" >/dev/null 2>&1
}

echo ""
say "Checking Claude Code hook setup..."
if [[ "${SAC_SKIP_HOOK_INSTALL:-}" == "1" ]]; then
  # F-06: Explicit opt-out for users who don't want the installer
  # touching ~/.claude/settings.json. Install still succeeds; they
  # can always run `goodnight --install-hooks` later when ready.
  warn "SAC_SKIP_HOOK_INSTALL=1 — skipping Claude Code hook install."
  warn "Run ${C_CYAN}goodnight --install-hooks${C_RESET} to enable idle detection later."
elif hooks_already_installed; then
  ok "Claude Code hooks already installed — idle detection ready."
elif ! command -v jq >/dev/null 2>&1; then
  # Auto-install of jq in step 8a failed (offline, unsupported arch,
  # etc.). Record the skip reason — user can recover later.
  warn "jq unavailable — Claude Code hook installation skipped."
  warn "Once jq is installed (e.g. ${C_BOLD}brew install jq${C_RESET}), run:"
  warn "  ${C_CYAN}goodnight --install-hooks${C_RESET}"
  warn "Until then goodnight runs in legacy ${C_BOLD}--watch-pid${C_RESET} mode."
else
  # F-06: About to modify ~/.claude/settings.json. Announce clearly
  # before doing it. Users who don't want this can Ctrl+C now or
  # re-run with SAC_SKIP_HOOK_INSTALL=1.
  say "Installing Claude Code hooks into $CLAUDE_SETTINGS..."
  say "(adds three ${C_BOLD}_managed_by: goodnight${C_RESET} entries; existing hooks preserved."
  say " Skip with ${C_BOLD}SAC_SKIP_HOOK_INSTALL=1${C_RESET} and re-run; remove later with ${C_BOLD}goodnight --uninstall-hooks${C_RESET}.)"
  if ui_spin "Installing Claude Code hooks" -- bash -c '"$1" --install-hooks >"$2" 2>&1' _ "$TARGET" /tmp/sac-hook-install.log; then
    ok "Claude Code hooks installed — default mode is idle-detection."
    say "Restart any running Claude Code sessions so they pick up the new hooks."
  else
    warn "Could not auto-install Claude Code hooks. See /tmp/sac-hook-install.log"
    warn "You can install them manually later: ${C_CYAN}goodnight --install-hooks${C_RESET}"
  fi
fi

# ── 10. Done ──────────────────────────────────────────────────────
echo ""
{
  echo "# Installation complete 🌙"
  echo ""
  echo "goodnight is installed at \`~/bin/sleep-after-claude\` and the \`goodnight\` shortcut is configured."
  echo ""
  echo "## Next step"
  echo ""
  echo "Open a new Terminal tab, then run:"
  echo ""
  echo "\`\`\`bash"
  echo "goodnight --help       # show all options"
  echo "goodnight --preflight  # audit your system"
  echo "goodnight              # watch Claude and sleep when done"
  echo "\`\`\`"
} | ui_markdown
if [[ -n "$RC" ]]; then
  {
    echo "To use it in this terminal right now:"
    echo ""
    echo "\`\`\`bash"
    echo "source $RC"
    echo "\`\`\`"
  } | ui_markdown
fi

# ── Drain the rest of the piped installer ────────────────────────
# When invoked as `curl ... | bash`, curl streams the embedded
# __SCRIPT_START__/__SCRIPT_END__ payload below this line. Without
# draining, `exit 0` closes the pipe mid-write and curl fails with
# "curl: (56) Failure writing output to destination". Cosmetically
# ugly and confusing to users even when the install succeeded.
#
# Detection: `-p /dev/stdin` is true only when stdin is a FIFO
# (i.e., piped input). Local runs (`bash install.sh` or
# `bash < install.sh`) have stdin as a TTY or regular file → no
# drain needed. This is the same idiom used by Homebrew's own
# installer.
if [[ -p /dev/stdin ]]; then
  # F-11: Bound the drain so a pathological hang on the pipe source
  # (slow trickle, stuck CDN connection) can't block the installer's
  # exit indefinitely. 5s comfortably exceeds any real CDN finish-
  # write for a ~45KB payload.
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout 5 cat >/dev/null 2>&1 || true
  elif command -v timeout >/dev/null 2>&1; then
    timeout 5 cat >/dev/null 2>&1 || true
  else
    # Fallback: background cat + 5s watchdog. Kill the cat if it's
    # still running when the deadline hits.
    cat >/dev/null 2>&1 &
    drain_pid=$!
    (sleep 5 && kill "$drain_pid" 2>/dev/null) &
    wait "$drain_pid" 2>/dev/null || true
  fi
fi

exit 0

# ─── Embedded sleep-after-claude script follows ───────────────────
# Everything between __SCRIPT_START__ and __SCRIPT_END__ is extracted
# by awk above. Do not modify these markers.
__SCRIPT_START__
#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
#  sleep-after-claude
#  Watches Claude Code work and sleeps the Mac when it is done.
#
#  Supports hook-based smart idle detection, PID-exit watching,
#  pre-flight sleep-blocker scans, optional terminal UI polish, and
#  an auditable sleep attempt path.
#
#  Usage: sleep-after-claude [options]
# ─────────────────────────────────────────────────────────────

set -uo pipefail

# Capture original argv up-front so check_for_update can `exec` into
# the freshly-installed binary preserving the user's invocation (F-05).
SAC_ORIGINAL_ARGS=("$@")

# ── macOS guard ───────────────────────────────────────────────
if [[ "$(uname)" != "Darwin" ]]; then
  echo "✖  sleep-after-claude only supports macOS." >&2
  exit 1
fi

# ── Bash version + TTY detection ──────────────────────────────
BASH_MAJOR="${BASH_VERSINFO[0]:-0}"
USE_BUILTIN_SLEEP=false
[[ $BASH_MAJOR -ge 4 ]] && USE_BUILTIN_SLEEP=true

USE_SPINNER=true
[[ -t 1 ]] || USE_SPINNER=false

STDIN_IS_TTY=false
[[ -t 0 ]] && STDIN_IS_TTY=true

STDOUT_IS_TTY=false
[[ -t 1 ]] && STDOUT_IS_TTY=true

# ── Colours (disabled for non-TTY output) ─────────────────────
if [[ "$STDOUT_IS_TTY" == true ]]; then
  # Use $'...' so the vars contain actual ESC bytes (not the literal
  # string "\033[..."). This means `printf "%s" "$CYAN"` renders
  # correctly, and `echo "$CYAN"` works without `-e`. The previous
  # "\033[..." form required either `echo -e` or `printf %b`, and
  # silently produced literal text when passed through `printf %s`.
  RESET=$'\033[0m'
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  CYAN=$'\033[36m'
  RED=$'\033[31m'
  BLUE=$'\033[34m'
  MAGENTA=$'\033[35m'
else
  RESET=""
  BOLD=""
  DIM=""
  GREEN=""
  YELLOW=""
  CYAN=""
  RED=""
  BLUE=""
  MAGENTA=""
fi

# Numeric environment overrides are user input that reaches arithmetic
# contexts. Under `set -u` a non-numeric value there is not a harmless
# fallback: bash reads the word as a variable name, finds it unset, and
# aborts. On the watch path that ends the run, so one typo in a tuning
# knob would take the whole night with it.
#
# Validate at assignment; fall back loudly.
SAC_CONFIG_WARNINGS=""
# Answers in $REPLY rather than on stdout. Command substitution would
# run this in a subshell, so the warning it accumulates would die with
# that subshell and a bad value would be corrected in silence — the
# fallback would work and the user would never learn their knob was
# ignored.
_cfg_int() {
  local name="$1" value="$2" fallback="$3"
  if [[ "$value" =~ ^[0-9]+$ ]] && ((10#$value > 0)); then
    REPLY=$((10#$value))
    return
  fi
  SAC_CONFIG_WARNINGS+="${name}=\"${value}\" is not a positive integer — using ${fallback}"$'\n'
  REPLY="$fallback"
}

# Version of this script.
#
# Supportability, not ceremony: a user reporting a problem has to be
# able to say which build they are on, and the log has to record which
# build actually slept the machine. Self-update still compares SHA-256
# rather than this string — the hash is exact where a version can be
# forgotten — but a hash is useless in a bug report.
#
# Bump in the same commit that cuts the tag; tests/version.bats asserts
# this matches the newest CHANGELOG entry.
SAC_VERSION="0.2.2"

# ── Config defaults ───────────────────────────────────────────
TIMEOUT_HOURS=6
DELAY_SECS=1
TARGET_PID=""
TARGET_PID_EXPLICIT=false
NO_SOUND=false
CAFFEINATE_ONLY=false
DRY_RUN=false
LIST_MODE=false
NOTIFY=false
# Logging defaults ON. This is an unattended command that takes an
# irreversible action while nobody is watching; a run that leaves no
# evidence behind cannot be debugged the next morning. --no-log opts
# out. The log is size-capped (see LOG_MAX_BYTES).
LOG_ENABLED=true
WAIT_FOR_START=false
LOG_FILE="${HOME}/.local/state/sleep-after-claude.log"
FIFO_DIR=""
PREFLIGHT_ONLY=false
SKIP_PREFLIGHT=false
FORCE=false
BRIEF=false
JSON_OUTPUT=false
# The update check is opt-in. It ends in a blocking y/N prompt, and a
# command whose whole purpose is to be started and walked away from
# must not be able to stall on a question about itself. `--check-update`
# asks for it explicitly; `update-all` and friends handle routine
# upgrades out of band.
SKIP_UPDATE_CHECK=true
# SAC_SKIP_UPDATE_CHECK is a hard override rather than merely another
# default: the post-update re-exec replays the user's original argv,
# which may well contain --check-update, and without a suppressor that
# would re-enter the update check forever (F-05).
SKIP_UPDATE_CHECK_FORCED="${SAC_SKIP_UPDATE_CHECK:+true}"
SKIP_UPDATE_CHECK_FORCED="${SKIP_UPDATE_CHECK_FORCED:-false}"
NO_AUTO_CAFFEINATE=false
ALLOW_BATTERY=false
LOG_SUMMARY=false
SLEEP_NOW=false
SMART_WATCH=false
WATCH_PID_MODE=false
INSTALL_HOOKS=false
UNINSTALL_HOOKS=false
CLAUDE_SETTINGS_FILE="${HOME}/.claude/settings.json"
BUSY_DIR="${HOME}/.local/state/goodnight/busy"

# Where Claude Code stores per-session transcripts:
#   $CLAUDE_PROJECTS_DIR/<project-slug>/<session_id>.jsonl
# Claude appends to the transcript continuously while a session works,
# which makes its mtime the single most reliable "this agent is alive
# and doing something" signal available without cooperation from the
# session itself. Everything in smart mode is built on it.
CLAUDE_PROJECTS_DIR="${SAC_CLAUDE_PROJECTS_DIR:-${HOME}/.claude/projects}"

# Codex keeps the equivalent record at
#   $CODEX_SESSIONS_DIR/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl
# and appends to it as the session works, exactly like Claude's
# transcripts.
CODEX_SESSIONS_DIR="${SAC_CODEX_SESSIONS_DIR:-${HOME}/.codex/sessions}"

# Every root scanned for agent activity. Busy markers only ever describe
# Claude Code sessions, so without this the machine would happily sleep
# on top of a working Codex run — "wait until my agents are done" has to
# mean all of them, not just the ones that can write us a marker.
#
# Extend with SAC_EXTRA_ACTIVITY_DIRS (colon-separated) for any other
# agent that keeps an append-as-it-works log.
AGENT_ACTIVITY_DIRS=("$CLAUDE_PROJECTS_DIR" "$CODEX_SESSIONS_DIR")
if [[ -n "${SAC_EXTRA_ACTIVITY_DIRS:-}" ]]; then
  while IFS= read -r _extra_dir; do
    [[ -n "$_extra_dir" ]] && AGENT_ACTIVITY_DIRS+=("$_extra_dir")
  done <<<"${SAC_EXTRA_ACTIVITY_DIRS//:/$'\n'}"
fi

# How long every tracked session must be quiet before we sleep.
# Default 5 minutes: long enough that a brief gap between turns (or a
# slow tool call that outlives its transcript write) doesn't trip the
# countdown, short enough to be useful as a nightly command.
_cfg_int SAC_IDLE_SECONDS "${SAC_IDLE_SECONDS:-300}" 300
SMART_IDLE_SECONDS="$REPLY"

# A busy marker whose session transcript hasn't been written for this
# many minutes is treated as dead weight — a crashed session, a session
# parked on a permission prompt, or one whose Stop hook never fired.
# Such a marker no longer blocks sleep and is reaped on sight.
#
# Because staleness is now corroborated against real transcript
# activity (rather than the marker's own mtime alone) this can be far
# tighter than the old blind 24h reaper without risking a reap
# mid-work. Override with SAC_STALE_MARKER_MINUTES.
_cfg_int SAC_STALE_MARKER_MINUTES "${SAC_STALE_MARKER_MINUTES:-15}" 15
SMART_STALE_MARKER_MINS="$REPLY"

# Sentinel embedded in every hook command goodnight installs. Unlike a
# sibling JSON key (._managed_by), a substring of the command string
# itself survives every settings.json rewrite we have observed in the
# wild — editors, installers, and Claude Code's own config merges all
# preserve the command verbatim while freely dropping unknown keys.
# Hook detection keys on this first and the JSON tag second.
HOOK_SENTINEL="goodnight-hook"

# Verified-sleep tuning. pmset returns 0 even when an assertion blocks
# the sleep, so a single call proves nothing; we confirm afterwards and
# retry. See attempt_sleep().
_cfg_int SAC_SLEEP_MAX_ATTEMPTS "${SAC_SLEEP_MAX_ATTEMPTS:-3}" 3
SLEEP_MAX_ATTEMPTS="$REPLY"
_cfg_int SAC_SLEEP_VERIFY_SECS "${SAC_SLEEP_VERIFY_SECS:-12}" 12
SLEEP_VERIFY_SECS="$REPLY"
_cfg_int SAC_SLEEP_RETRY_BACKOFF_SECS "${SAC_SLEEP_RETRY_BACKOFF_SECS:-5}" 5
SLEEP_RETRY_BACKOFF_SECS="$REPLY"

# A running agent that is burning CPU is working, whatever its session
# log says. This closes the one gap the log-mtime signal cannot cover:
# an agent with no busy marker — Codex — running a long tool call that
# writes nothing while it runs.
#
# Expressed as percent of one core, sampled as a delta over the poll
# interval so it is scale-invariant and immune to a process's lifetime
# total. Measured idle floor for live agent processes on a working
# machine is ~5%, so 20% carries roughly a 4x margin.
#
# This can only ever DELAY sleep, never authorise it: an agent blocked
# on a network round trip burns no CPU while genuinely working, so CPU
# is sound as a veto and useless as permission. The hard --timeout
# bounds the veto so it can never wedge the watch.
_cfg_int SAC_AGENT_CPU_BUSY_PCT "${SAC_AGENT_CPU_BUSY_PCT:-20}" 20
AGENT_CPU_BUSY_PCT="$REPLY"

# Process names the CPU guard treats as agents.
#
# The session-log signal must know where each agent writes and in what
# shape; CPU needs only a process name, so it generalises to any agent
# CLI for free. That makes this the cheap half of covering a new tool,
# and the reason this list is broader than the two whose log formats
# are actually understood.
#
# Claude and Codex have log coverage as well; the rest are CPU-only,
# which still means a build or test run they launch keeps the Mac
# awake. Extend with SAC_EXTRA_AGENT_PROCESSES (space or comma
# separated). Matched exactly via `pgrep -x`, so a generic name cannot
# collide with an unrelated process.
# Consecutive above-threshold samples required before CPU counts as
# activity.
#
# One sample is not enough. Measured idle on a working machine sits at
# 3-5% of a core but spikes to 14%, and a single spurious reading does
# not merely delay sleep by a tick — it resets the whole idle countdown.
# Noise arriving more often than --idle would therefore hold the machine
# awake until the hard timeout, which is precisely the never-sleeps
# failure this command exists to fix.
#
# Real work is sustained by definition, so debouncing costs one tick of
# detection latency against a 5-minute window and buys immunity to
# transients.
AGENT_CPU_BUSY_SAMPLES=2

AGENT_PROCESS_NAMES=(claude codex aider gemini opencode cursor-agent)
if [[ -n "${SAC_EXTRA_AGENT_PROCESSES:-}" ]]; then
  while IFS= read -r _agent_name; do
    [[ -n "$_agent_name" ]] && AGENT_PROCESS_NAMES+=("$_agent_name")
  done <<<"$(printf '%s' "${SAC_EXTRA_AGENT_PROCESSES//,/ }" | tr ' ' '\n')"
fi
CPU_GUARD=true

UNATTENDED=false
NO_REPAIR=false
DOCTOR_MODE=false
# Seconds an interactive prompt may block before it self-answers with
# the safe default. Guarantees an unattended `goodnight` can never hang
# on a question nobody is awake to answer.
_cfg_int SAC_PROMPT_TIMEOUT_SECS "${SAC_PROMPT_TIMEOUT_SECS:-60}" 60
PROMPT_TIMEOUT_SECS="$REPLY"
# Rotate the log once it passes this size so an unattended nightly
# command can't grow it without bound.
_cfg_int SAC_LOG_MAX_BYTES "${SAC_LOG_MAX_BYTES:-2097152}" 2097152
LOG_MAX_BYTES="$REPLY"
UPDATE_CHECK_URL="${SLEEP_AFTER_CLAUDE_UPDATE_URL:-https://raw.githubusercontent.com/sambatia/goodnight/main/sleep-after-claude}"
UPDATE_INSTALLER_URL="${SLEEP_AFTER_CLAUDE_INSTALLER_URL:-https://raw.githubusercontent.com/sambatia/goodnight/main/install-sleep-after-claude.sh}"
UPDATE_CACHE_DIR="${HOME}/.cache/sleep-after-claude"
UPDATE_CACHE_TTL_SECS=86400 # 24h rate-limit on network checks

# ── Helpers ───────────────────────────────────────────────────
print_header() {
  echo ""
  if have_gum; then
    gum style --foreground 39 --bold -- "sleep-after-claude"
    gum style --foreground 245 -- "Sleep your Mac when Claude Code finishes."
    gum style --foreground 240 -- "────────────────────────────────────────────"
  else
    echo -e "  ${BOLD}${BLUE}sleep-after-claude${RESET}"
    echo -e "  ${DIM}Sleep your Mac when Claude Code finishes.${RESET}"
    echo -e "  ${DIM}─────────────────────────────────────────${RESET}"
  fi
}

print_step() { echo -e "  ${CYAN}›${RESET} $1"; }
print_ok() { echo -e "  ${GREEN}✔${RESET} $1"; }
print_warn() { echo -e "  ${YELLOW}⚠${RESET}  $1"; }
print_error() { echo -e "  ${RED}✖${RESET} $1"; }
print_done() {
  echo ""
  if have_gum; then
    gum style \
      --border rounded \
      --border-foreground 46 \
      --padding "1 2" \
      --margin "0 0 1 0" \
      -- "$(gum style --foreground 46 --bold -- "Done")" "$1"
  else
    echo -e "  ${BOLD}${GREEN}✔ Done.${RESET} $1"
  fi
  echo ""
}

# ── gum / glow integration ────────────────────────────────────
# These are optional polish layers. When `gum` (charmbracelet/gum) is
# on PATH and both stdin and stdout are real TTYs, interactive prompts
# and styled cards use gum for a prettier experience. When absent —
# or when the session is over SSH, where mobile/flaky SSH clients
# mishandle gum's /dev/tty writes and arrow-key forwarding —
# everything falls back to the hand-rolled bash UI.
#
# Overrides:
#   SAC_NO_GUM=1      force fallback (CI, scripts, minimal terminals)
#   SAC_FORCE_GUM=1   opt back in when over SSH (for users whose SSH
#                     client handles TUIs well — e.g. iTerm → ssh)
have_gum() {
  [[ "${SAC_NO_GUM:-}" != "1" ]] || return 1
  [[ "$STDOUT_IS_TTY" == true ]] || return 1
  [[ "$STDIN_IS_TTY" == true ]] || return 1
  # SSH sessions default to fallback — interactive TUIs over SSH are
  # often fragile (especially over mobile SSH apps like Termius/Blink
  # which may not forward arrow keys or /dev/tty reliably).
  if [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ]] && [[ "${SAC_FORCE_GUM:-}" != "1" ]]; then
    return 1
  fi
  command -v gum >/dev/null 2>&1
}
have_glow() {
  [[ "${SAC_NO_GLOW:-}" != "1" ]] || return 1
  [[ "$STDOUT_IS_TTY" == true ]] || return 1
  command -v glow >/dev/null 2>&1
}

# Render markdown to the terminal when glow is available; otherwise
# pass the plain markdown through unchanged for scripts and CI logs.
ui_markdown() {
  if have_glow; then
    glow -
  else
    cat
  fi
}

# Small terminal design system. All helpers prefer gum when the user is
# in an interactive terminal, but every component has a plain Bash
# fallback so CI, pipes, SSH fallbacks, and scripts stay predictable.
ui_rule() {
  if have_gum; then
    gum style --foreground 240 -- "────────────────────────────────────────────"
  else
    echo -e "  ${DIM}─────────────────────────────────────────${RESET}"
  fi
}

ui_section() {
  local title="$1"
  local subtitle="${2:-}"
  echo ""
  if have_gum; then
    gum style --foreground 141 --bold -- "$title"
    [[ -n "$subtitle" ]] && gum style --foreground 245 -- "$subtitle"
    gum style --foreground 240 -- "────────────────────────────────────────────"
  else
    echo -e "  ${BOLD}${MAGENTA}${title}${RESET}"
    [[ -n "$subtitle" ]] && echo -e "  ${DIM}${subtitle}${RESET}"
    echo -e "  ${DIM}─────────────────────────────────────────${RESET}"
  fi
}

ui_kv() {
  local label="$1"
  local value="$2"
  printf "  %b%-16s%b %s\n" "$DIM" "${label}:" "$RESET" "$value"
}

ui_table() {
  local columns="$1"
  local tmp
  tmp="$(mktemp -t sac-ui-table.XXXXXX 2>/dev/null)" || return 1
  cat >"$tmp"
  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    return 0
  fi

  if have_gum && [[ "${COLUMNS:-100}" -ge 88 ]]; then
    gum table --print \
      --separator "," \
      --columns "$columns" \
      --border rounded \
      --border.foreground 240 \
      --header.foreground 141 \
      --cell.foreground 252 \
      <"$tmp"
    local rc=$?
    rm -f "$tmp"
    return "$rc"
  fi

  local header
  header="$(printf '%s' "$columns" | tr ',' ' ')"
  echo -e "  ${BOLD}${header}${RESET}"
  command awk -F',' '{
    printf "  "
    for (i = 1; i <= NF; i++) {
      printf "%-20s", $i
    }
    printf "\n"
  }' "$tmp"
  rm -f "$tmp"
}

# Styled panel: gum-powered rounded box with colored border if gum is
# available, otherwise the existing hand-drawn ╭─╮ card. Each argument
# is one content line.
#
# Usage: ui_panel <color> <title> <line1> <line2> ...
#   color: "warning" | "info" | "success" | "danger"
ui_panel() {
  local kind="$1"
  shift
  local title="$1"
  shift
  local -a lines=("$@")

  if have_gum; then
    local fg border
    case "$kind" in
      warning)
        fg=214
        border=214
        ;;
      info)
        fg=39
        border=39
        ;;
      success)
        fg=46
        border=46
        ;;
      danger)
        fg=196
        border=196
        ;;
      *)
        fg=250
        border=250
        ;;
    esac
    # gum style takes each argument as a separate line and renders
    # them inside the box. --bold applies to the whole block; we
    # use an explicit bold title and plain content by calling
    # gum style twice and nesting via gum join.
    local title_block content_block
    title_block="$(gum style --foreground "$fg" --bold -- "$title")"
    content_block="$(printf '%s\n' "${lines[@]}" | gum style)"
    gum style \
      --border rounded \
      --border-foreground "$border" \
      --padding "1 2" \
      --margin "1 0" \
      -- "$title_block" "" "$content_block"
    return
  fi

  # Fallback: hand-drawn box (current style).
  local color="$YELLOW"
  case "$kind" in
    info) color="$BLUE" ;;
    success) color="$GREEN" ;;
    danger) color="$RED" ;;
  esac
  local rule="────────────────────────────────────────────────────────"
  echo ""
  echo -e "  ${BOLD}${color}╭─ ${title} ${rule:0:$((54 - ${#title}))}╮${RESET}"
  echo -e "  ${color}│${RESET}"
  local line
  for line in "${lines[@]}"; do
    if [[ -z "$line" ]]; then
      echo -e "  ${color}│${RESET}"
    else
      echo -e "  ${color}│${RESET}   ${line}"
    fi
  done
  echo -e "  ${color}│${RESET}"
  echo -e "  ${BOLD}${color}╰──────────────────────────────────────────────────────────╯${RESET}"
  echo ""
}

# gum-powered yes/no confirm with fallback to prompt_confirm.
# Usage: ui_confirm "Proceed anyway?"   (returns 0 on yes, 1 on no)
ui_confirm() {
  local prompt="$1"
  if [[ "$UNATTENDED" == true ]]; then
    print_warn "Unattended mode — declining: $prompt"
    return 1
  fi
  if [[ "$STDIN_IS_TTY" != true ]]; then
    print_warn "Non-interactive confirmation unavailable — defaulting to no: $prompt"
    return 1
  fi
  if have_gum; then
    # --default=false means Enter selects No (safe default). --timeout
    # guarantees the prompt cannot outlive the person who started the
    # command and walked away.
    gum confirm --default=false --timeout "${PROMPT_TIMEOUT_SECS}s" "$prompt"
    return $?
  fi
  prompt_confirm "${BOLD}${prompt}${RESET} [y/N]:"
}

# gum-powered single-choice menu with fallback to stdin read.
# Usage:
#   ui_choose "Header text" \
#     "opt1|First option description" \
#     "opt2|Second option"
# Returns the chosen option key (before the pipe) on stdout.
ui_choose() {
  local header="$1"
  shift
  local -a items=("$@")
  if [[ "$UNATTENDED" == true || "$STDIN_IS_TTY" != true ]]; then
    # No one to ask. Callers treat an empty result as "take the safe
    # default" rather than blocking on a menu nobody will answer.
    return 1
  fi
  # The first entry is the documented safe default, and it is what an
  # unanswered prompt must resolve to. Callers order their menus so
  # that this is the non-destructive choice.
  local safe_default="${items[0]%%|*}"
  if have_gum; then
    local -a labels=()
    local item
    for item in "${items[@]}"; do
      labels+=("${item#*|}")
    done
    local chosen_label rc
    chosen_label="$(gum choose --header "$header" --timeout "${PROMPT_TIMEOUT_SECS}s" -- "${labels[@]}")"
    rc=$?
    # gum exits 124 on timeout. Passing that through as a failure threw
    # the safe default away and handed the caller an empty answer, which
    # it reads as abort — so a prompt left unattended kept the Mac awake,
    # which is precisely what the timeout was added to prevent.
    if ((rc == 124)); then
      echo "$safe_default"
      return 0
    fi
    ((rc == 0)) || return 130
    # Map label back to key
    for item in "${items[@]}"; do
      if [[ "${item#*|}" == "$chosen_label" ]]; then
        echo "${item%%|*}"
        return 0
      fi
    done
    return 1
  fi
  # Fallback: render labels + read a single-letter key.
  #
  # Every byte of prompt UI goes to stderr. This function's stdout is
  # command-substituted by the caller, so the menu itself was being
  # captured as part of the answer — the header and labels came back
  # glued to the chosen key, matched no case arm, and the blocker menu
  # aborted whatever the user picked.
  local item
  echo "  $header" >&2
  for item in "${items[@]}"; do
    local key="${item%%|*}" label="${item#*|}"
    echo -e "    ${CYAN}[${key:0:1}]${RESET} ${label}" >&2
  done
  local choice
  printf "  Choice: " >&2
  # Bounded here too. Without gum installed this read was unbounded, so
  # the time-bounded-prompt contract held only on machines that happened
  # to have gum.
  if ! read -r -t "$PROMPT_TIMEOUT_SECS" choice; then
    echo "" >&2
    print_warn "No answer in ${PROMPT_TIMEOUT_SECS}s — taking the safe default." >&2
    echo "$safe_default"
    return 0
  fi
  choice="$(echo "$choice" | tr '[:upper:]' '[:lower:]' | cut -c1)"
  for item in "${items[@]}"; do
    local key="${item%%|*}"
    if [[ "${key:0:1}" == "$choice" ]]; then
      echo "$key"
      return 0
    fi
  done
  return 1
}

# gum spin wrapper with fallback to a simple message. The command
# runs inside the spinner; its exit status is returned.
# Usage: ui_spin "Fetching..." -- curl -fsSL url -o file
ui_spin() {
  local title="$1"
  shift
  # Skip the `--` separator if present.
  [[ "${1:-}" == "--" ]] && shift
  if have_gum; then
    gum spin --spinner minidot --title "$title" --show-output -- "$@"
    return $?
  fi
  print_step "$title"
  "$@"
}

# Render the public CLI help from one markdown block so the styled and
# plain fallbacks stay byte-for-byte consistent.
usage() {
  ui_markdown <<'HELP'
# sleep-after-claude

Sleep your Mac once every agent has finished, paused, or gone quiet.

## Usage

```bash
sleep-after-claude [options]
```

## How it decides

Two independent signals must agree before the Mac sleeps:

- **Busy markers** — written by Claude Code hooks on every prompt,
  removed when the turn ends. Precise, but only as good as the hooks.
- **Transcript activity** — Claude appends to
  `~/.claude/projects/*/<session>.jsonl` while it works. Needs no
  hooks, so it still catches work when the hooks are broken or absent.

A session whose transcript has been silent past `--stale` no longer
counts as busy — that covers a crash, a quit, and a session parked on
a permission prompt. Sleep is then verified against the kernel and
retried, because `pmset sleepnow` reports success even when macOS
refuses.

Run `--doctor` to see all of this as live state.

## Watch options

| Flag | Description |
|---|---|
| `--idle <secs>` | Quiet period required before sleeping (default: 300). |
| `--stale <mins>` | Silence after which a session stops counting (default: 15). |
| `--timeout, -t <hrs>` | Sleep regardless after N hours, min 1 (default: 6). |
| `--delay, -d <secs>` | Grace period before sleeping (default: 1). |
| `--pid, -p <pid>` | Watch a specific PID (`--watch-pid` mode only). |
| `--wait-for-start` | Poll until a Claude process appears. |

## Mode options

| Flag | Description |
|---|---|
| `--doctor` | Report live health of the whole integration, then exit. |
| `--version, -V` | Print the version and exit. |
| `--caffeinate-only` | Release caffeinate but don't sleep the Mac. |
| `--dry-run` | Simulate: detect and wait, but don't sleep. |
| `--unattended` | Never prompt; every question takes its safe default. |
| `--list, -l` | Show detectable Claude processes and exit. |
| `--preflight, -P` | Run pre-flight scan only, then exit. |
| `--no-preflight` | Skip pre-flight scan entirely. |
| `--force, -f` | Skip confirmation prompts. |
| `--no-repair` | Don't auto-repair degraded Claude Code hooks. |
| `--no-cpu-guard` | Don't treat agent CPU activity as a reason to stay awake. |
| `--check-update` | Check for a newer version now (off by default). |
| `--skip-update-check` | Accepted for compatibility; the check is already off. |
| `--no-auto-caffeinate` | Don't auto-start `caffeinate -dim` if missing. |
| `--allow-battery` | Proceed even if the Mac is on battery (default: wait for AC). |
| `--log-summary` | Render the session log as pretty markdown. |
| `--sleep-now` | Skip the watch: preflight, handle blockers, sleep immediately. |
| `--smart` | Idle-aware watch (the default). |
| `--watch-pid` | Legacy process-exit watch mode. Rarely what you want. |
| `--install-hooks` | Install/repair the Claude Code hooks. |
| `--uninstall-hooks` | Remove goodnight's Claude Code hooks. |

## Output options

| Flag | Description |
|---|---|
| `--brief, -b` | Show only the verdict in preflight output. |
| `--json` | Emit preflight as JSON for automation. |
| `--no-sound` | Skip the completion sound. |
| `--notify, -n` | Send a macOS notification on completion. |
| `--log` | Append events to the log file (on by default). |
| `--no-log` | Disable logging for this run. |
| `--log-file <path>` | Custom log file (implies `--log`). |
| `--help, -h` | Show this help. |

## Defaults

Logging is on. Default log: `~/.local/state/sleep-after-claude.log`
(rotated at 2 MB to `.log.1`).
HELP
}

# Erase the current line.
#
# `\033[K` clears from the cursor to the end of the line, whatever is
# there. Overwriting a fixed 72 columns with spaces fails two ways:
# anything longer leaves a tail behind, and on a terminal narrower than
# 72 the padding itself wraps and creates a second line the next `\r`
# cannot reach. Both showed up in practice as duplicated spinner rows
# with fragments of earlier output stranded beside them.
clear_line() {
  [[ "$USE_SPINNER" == true ]] && printf "\r\033[K"
}

is_integer() { [[ "$1" =~ ^[0-9]+$ ]]; }
is_positive_integer() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }

elapsed_label() {
  local secs=$1
  local h=$((secs / 3600))
  local m=$(((secs % 3600) / 60))
  local s=$((secs % 60))
  if [[ $h -gt 0 ]]; then
    printf "%dh %02dm %02ds" $h $m $s
  elif [[ $m -gt 0 ]]; then
    printf "%dm %02ds" $m $s
  else
    printf "%ds" $s
  fi
}

play_sound() {
  [[ "$NO_SOUND" == true ]] && return
  afplay /System/Library/Sounds/Glass.aiff 2>/dev/null || true
}

# Escape for AppleScript double-quoted strings
as_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# Escape for JSON string values
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

notify_macos() {
  [[ "$NOTIFY" == true ]] || return
  local msg title
  msg="$(as_escape "$1")"
  title="$(as_escape "sleep-after-claude")"
  osascript -e "display notification \"$msg\" with title \"$title\"" 2>/dev/null || true
}

LOG_WRITE_FAILED=false
# Appends a timestamped event line to $LOG_FILE when --log is active.
# No-op when LOG_ENABLED is false. On first write failure emits a single
# stderr warning; subsequent failures stay silent so the tick loop
# doesn't spam. Return status when disabled is unspecified (no caller
# checks it).
LOG_ROTATE_CHECKED=false
# Rotate once per invocation, not once per event — the size check is a
# stat() and the tick loop calls log_event often.
maybe_rotate_log() {
  [[ "$LOG_ROTATE_CHECKED" == true ]] && return 0
  LOG_ROTATE_CHECKED=true
  [[ -f "$LOG_FILE" ]] || return 0
  local size
  size="$(stat -f %z "$LOG_FILE" 2>/dev/null || stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)"
  [[ "$size" =~ ^[0-9]+$ ]] || return 0
  ((size > LOG_MAX_BYTES)) || return 0
  # Single generation of history is enough to debug last night's run.
  mv -f "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
}

log_event() {
  [[ "$LOG_ENABLED" == true ]] || return
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  maybe_rotate_log
  # Brace group + outer 2>/dev/null so the shell's own "No such file or
  # directory" error on a failed >> redirection is also suppressed, not
  # just errors produced by the command itself.
  if ! { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >>"$LOG_FILE"; } 2>/dev/null; then
    # Warn once per session so the user knows durability is broken.
    if [[ "$LOG_WRITE_FAILED" == false ]]; then
      LOG_WRITE_FAILED=true
      echo "  ⚠  log write failed: $LOG_FILE (subsequent failures will be silent)" >&2
    fi
  fi
}

micro_sleep() {
  if [[ "$USE_BUILTIN_SLEEP" == true ]]; then
    read -rt "$1" -u 9 _ 2>/dev/null || true
  else
    sleep "$1"
  fi
}

# ── Detect Claude processes ───────────────────────────────────
# Blocklist covers processes that contain "claude" in path/args but
# are NOT Claude Code CLI. Patterns anchored where possible to avoid
# collateral damage (e.g. any process with "Helper" in the command).
EXCLUDE_PATTERN='Claude\.app|Contents/Helpers/|chrome-native-host|--type=|/Electron|Electron\.app|Cursor\.app|Windsurf\.app|anthropic-tools'

find_claude_processes() {
  local script_name tight_pids tight_result
  script_name="$(basename "$0")"

  tight_pids=$(
    {
      pgrep -x claude 2>/dev/null || true
      pgrep -f "claude-code" 2>/dev/null || true
    } | sort -u | grep -v "^$$\$" || true
  )

  if [[ -n "$tight_pids" ]]; then
    tight_result=$(echo "$tight_pids" |
      xargs -I{} sh -c 'ps -p {} -o pid=,command= 2>/dev/null || true' |
      grep -iv "$script_name" |
      grep -iv "sleep-after" |
      grep -Ev "$EXCLUDE_PATTERN" ||
      true)
    if [[ -n "$tight_result" ]]; then
      echo "$tight_result"
      return
    fi
  fi

  pgrep -fi "claude" 2>/dev/null |
    grep -v "^$$\$" |
    xargs -I{} sh -c 'ps -p {} -o pid=,command= 2>/dev/null || true' |
    grep -iv "$script_name" |
    grep -iv "sleep-after" |
    grep -Ev "$EXCLUDE_PATTERN" ||
    true
}

find_all_claude_processes_raw() {
  local script_name
  script_name="$(basename "$0")"
  pgrep -fi "claude" 2>/dev/null |
    grep -v "^$$\$" |
    xargs -I{} sh -c 'ps -p {} -o pid=,command= 2>/dev/null || true' |
    grep -iv "$script_name" |
    grep -iv "sleep-after" ||
    true
}

# ── Pre-flight scan ───────────────────────────────────────────
PREFLIGHT_TARGET=""
PREFLIGHT_EXCLUDED=""
PREFLIGHT_CAFFEINATE=""
PREFLIGHT_ASSERTIONS=()
PREFLIGHT_BLOCKERS=()
PREFLIGHT_DISPLAY_ONLY=()
PREFLIGHT_SYSTEM=()
PREFLIGHT_LID=""
PREFLIGHT_SESSIONS=""
PREFLIGHT_BATTERY_PCT=""
PREFLIGHT_BATTERY_SRC=""
PREFLIGHT_SLEEP_MIN=""
PREFLIGHT_DISPLAYSLEEP_MIN=""
PREFLIGHT_HIBERNATE_MODE=""

# Known-benign macOS system daemons. These routinely hold
# PreventUserIdleSystemSleep assertions as part of normal operation but
# do NOT actually prevent sleep — the OS releases them at sleep time.
# Flagging these as blockers creates false alarms.
#
# Anchored to exact daemon names (case-sensitive, full match).
SYSTEM_DAEMONS_REGEX='^(runningboardd|sharingd|powerd|useractivityd|bluetoothd|rcd|coreaudiod|apsd|locationd|cloudd|searchd|mDNSResponder|UserEventAgent|symptomsd|timed|trustd|cfprefsd|WindowServer|loginwindow|SystemUIServer|Dock|Finder|ControlCenter|NotificationCenter|identityservicesd|imagent|callservicesd|remindd|parsecd|bird|iconservicesagent|iconservicesd|diskarbitrationd|fseventsd|spindump|corespeechd|corespotlightd|nsurlsessiond|nsurlstoraged|assistantd|mediaremoted|distnoted|syspolicyd|amfid|taskgated|securityd|secinitd|opendirectoryd|configd|hidd|backlightd|thermalmonitord|pboard|launchservicesd|nfcd|airportd|wifiAgent|wifiFirmwareLoader|wifianalyticsd|watchdogd|appsleepd|routined|avconferenced|bluetoothuserd|gamecontrollerd)$'

# Parse pmset -g assertions into categorized arrays. Used by both full
# scan and post-watch re-scan (which only needs this).
#
# PREFLIGHT_SCAN_OK is true only when `pmset -g assertions` ran AND produced
# the expected "Listed by owning process" header. Verdict rendering must
# treat empty blockers differently when the scan failed — an unverified
# "clear" is worse than an explicit "scan unavailable".
# Will the release step clear this caffeinate?
#
# Yes unless it is alive and owned by somebody else — one owned by
# another user survives the kill and is a genuine blocker. A process
# that has already exited between the pmset scan and this check holds
# nothing and blocks nothing, so it counts as clear rather than as an
# obstacle we cannot remove. Erring the other way would let a caffeinate
# that died mid-scan read as un-releasable.
caffeinate_is_releasable() {
  local pid="$1" owner
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  owner="$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')"
  # No owner => the process is gone => nothing left to release.
  [[ -z "$owner" || "$owner" == "$USER" ]]
}

PREFLIGHT_SCAN_OK=false
scan_assertions() {
  local raw line parsing=false severity apid aname atype pmset_rc
  raw="$(pmset -g assertions 2>/dev/null)"
  pmset_rc=$?

  PREFLIGHT_ASSERTIONS=()
  PREFLIGHT_BLOCKERS=()
  PREFLIGHT_DISPLAY_ONLY=()
  PREFLIGHT_SYSTEM=()
  PREFLIGHT_SCAN_OK=false

  if [[ $pmset_rc -ne 0 || -z "$raw" ]]; then
    return
  fi
  if [[ "$raw" != *"Listed by owning process"* ]]; then
    return
  fi
  PREFLIGHT_SCAN_OK=true

  while IFS= read -r line; do
    if [[ "$line" == *"Listed by owning process"* ]]; then
      parsing=true
      continue
    fi
    [[ "$parsing" == false ]] && continue
    [[ -z "${line// /}" ]] && continue

    if [[ "$line" =~ pid[[:space:]]+([0-9]+)\(([^\)]+)\).*\][[:space:]]+[^[:space:]]+[[:space:]]+([A-Za-z]+) ]]; then
      apid="${BASH_REMATCH[1]}"
      aname="${BASH_REMATCH[2]}"
      atype="${BASH_REMATCH[3]}"

      severity="info"
      case "$atype" in
        PreventSystemSleep)
          # caffeinate we can terminate is not a blocker, it is the thing
          # goodnight releases. `caffeinate -dims` holds exactly this
          # assertion (the `s`), so classifying it as un-releasable fired
          # the red "releasing caffeinate alone will not be sufficient"
          # panel on every run where such a caffeinate was up — while the
          # blockers it listed *were* caffeinate. A warning that
          # contradicts itself and fires every time is one nobody reads.
          #
          # Ownership matters: we can only kill our own. One owned by
          # another user really is un-releasable and stays a blocker.
          if [[ "$aname" == "caffeinate" ]] && caffeinate_is_releasable "$apid"; then
            severity="release"
          elif [[ "$aname" =~ $SYSTEM_DAEMONS_REGEX ]]; then
            # Even PreventSystemSleep from system daemons is usually
            # benign; the OS releases it at sleep time.
            severity="system"
          else
            severity="blocker"
          fi
          ;;
        PreventUserIdleSystemSleep)
          if [[ "$aname" == "caffeinate" ]] && caffeinate_is_releasable "$apid"; then
            severity="release"
          elif [[ "$aname" =~ $SYSTEM_DAEMONS_REGEX ]]; then
            severity="system"
          else
            severity="blocker"
          fi
          ;;
        PreventUserIdleDisplaySleep | NoDisplaySleepAssertion)
          severity="display"
          ;;
        UserIsActive)
          severity="user"
          ;;
      esac

      PREFLIGHT_ASSERTIONS+=("$severity|$apid|$aname|$atype")
      [[ "$severity" == "blocker" ]] && PREFLIGHT_BLOCKERS+=("$apid|$aname|$atype")
      [[ "$severity" == "display" ]] && PREFLIGHT_DISPLAY_ONLY+=("$apid|$aname|$atype")
      [[ "$severity" == "system" ]] && PREFLIGHT_SYSTEM+=("$apid|$aname|$atype")
    fi
  done <<<"$raw"
}

preflight_scan() {
  local all_claude target_pid_set line pid batt pm batt_pct

  # -- Claude target/excluded
  # Honor --pid override: if user explicitly set TARGET_PID, use it.
  if [[ "$TARGET_PID_EXPLICIT" == true && -n "$TARGET_PID" ]]; then
    if kill -0 "$TARGET_PID" 2>/dev/null; then
      PREFLIGHT_TARGET="$(ps -p "$TARGET_PID" -o pid=,command= 2>/dev/null || echo "")"
    else
      PREFLIGHT_TARGET=""
    fi
  else
    PREFLIGHT_TARGET="$(find_claude_processes)"
  fi

  all_claude="$(find_all_claude_processes_raw)"
  target_pid_set=""
  if [[ -n "$PREFLIGHT_TARGET" ]]; then
    target_pid_set="$(echo "$PREFLIGHT_TARGET" | awk '{print $1}' | sort -u)"
  fi

  PREFLIGHT_EXCLUDED=""
  if [[ -n "$all_claude" ]]; then
    while IFS= read -r line; do
      pid="$(echo "$line" | awk '{print $1}')"
      if ! echo "$target_pid_set" | grep -qx "$pid"; then
        PREFLIGHT_EXCLUDED+="${line}"$'\n'
      fi
    done <<<"$all_claude"
    PREFLIGHT_EXCLUDED="${PREFLIGHT_EXCLUDED%$'\n'}"
  fi

  # -- Caffeinate detail
  PREFLIGHT_CAFFEINATE="$(
    ps -axo pid=,user=,etime=,command= 2>/dev/null |
      awk '/[c]affeinate/' ||
      true
  )"

  # -- Assertions
  scan_assertions

  # -- Power state
  batt="$(pmset -g batt 2>/dev/null || echo "")"
  pm="$(pmset -g 2>/dev/null || echo "")"

  batt_pct="$(echo "$batt" | grep -oE '[0-9]+%' | head -1)"
  if [[ -z "$batt_pct" ]]; then
    PREFLIGHT_BATTERY_PCT="N/A"
  else
    PREFLIGHT_BATTERY_PCT="$batt_pct"
  fi

  if echo "$batt" | grep -q "AC Power"; then
    PREFLIGHT_BATTERY_SRC="AC Power"
  elif echo "$batt" | grep -q "Battery Power"; then
    PREFLIGHT_BATTERY_SRC="Battery"
  else
    PREFLIGHT_BATTERY_SRC="unknown"
  fi

  PREFLIGHT_SLEEP_MIN="$(echo "$pm" | awk '/^ *sleep[[:space:]]/{print $2; exit}')"
  PREFLIGHT_DISPLAYSLEEP_MIN="$(echo "$pm" | awk '/^ *displaysleep[[:space:]]/{print $2; exit}')"
  PREFLIGHT_HIBERNATE_MODE="$(echo "$pm" | awk '/^ *hibernatemode[[:space:]]/{print $2; exit}')"

  # -- Lid state
  PREFLIGHT_LID="$(
    ioreg -r -k AppleClamshellState 2>/dev/null |
      awk -F'= ' '/AppleClamshellState/ {print $2; exit}' |
      tr -d ' ' ||
      echo "unknown"
  )"
  [[ -z "$PREFLIGHT_LID" ]] && PREFLIGHT_LID="unknown"

  # -- Active user sessions
  PREFLIGHT_SESSIONS="$(who 2>/dev/null || echo "")"
}

# -- Brief render (verdict only)
render_preflight_brief() {
  echo ""
  if [[ -n "$PREFLIGHT_TARGET" ]]; then
    local tgt_pid tgt_cmd
    tgt_pid="$(echo "$PREFLIGHT_TARGET" | awk 'NR==1{print $1}')"
    tgt_cmd="$(echo "$PREFLIGHT_TARGET" | awk 'NR==1{$1=""; sub(/^ /,""); print}' | cut -c1-50)"
    echo -e "  ${GREEN}✔${RESET} Target: PID ${tgt_pid} ${DIM}→ ${tgt_cmd}${RESET}"
  else
    echo -e "  ${RED}✖${RESET} No target Claude process found"
  fi
  if [[ "$PREFLIGHT_SCAN_OK" != true ]]; then
    echo -e "  ${YELLOW}⚠${RESET}  Sleep-blocker scan unavailable (pmset failed or unexpected output)"
  elif [[ ${#PREFLIGHT_BLOCKERS[@]} -eq 0 ]]; then
    echo -e "  ${GREEN}✔${RESET} No sleep blockers detected"
  else
    echo -e "  ${RED}✖${RESET} ${#PREFLIGHT_BLOCKERS[@]} sleep blocker(s):"
    local entry pid name type
    for entry in "${PREFLIGHT_BLOCKERS[@]}"; do
      IFS='|' read -r pid name type <<<"$entry"
      echo -e "    • ${BOLD}${name}${RESET} (PID $pid) — ${RED}${type}${RESET}"
    done
  fi
  echo ""
}

# -- Full render
render_preflight() {
  if [[ "$BRIEF" == true ]]; then
    render_preflight_brief
    return
  fi

  ui_section "Pre-flight scan" "Sleep readiness audit before goodnight releases caffeinate."

  ui_section "Claude processes"
  if [[ -n "$PREFLIGHT_TARGET" ]]; then
    # Label the first match as the active "Target" (what the watch
    # loop will actually follow) and any additional matches as
    # "Candidate" so the output isn't misleading when there are
    # multiple Claude processes running.
    local _preflight_line_no=0
    echo "$PREFLIGHT_TARGET" | while IFS= read -r line; do
      _preflight_line_no=$((_preflight_line_no + 1))
      if [[ $_preflight_line_no -eq 1 ]]; then
        echo -e "  ${GREEN}✔${RESET} Target:    ${line}"
      else
        echo -e "  ${DIM}•${RESET} Candidate: ${DIM}${line}  (not watched — use --pid to pick)${RESET}"
      fi
    done
  else
    echo -e "  ${RED}✖${RESET} No target Claude process found"
  fi
  if [[ -n "$PREFLIGHT_EXCLUDED" ]]; then
    echo "$PREFLIGHT_EXCLUDED" | while IFS= read -r line; do
      local epid ecmd
      epid="$(echo "$line" | awk '{print $1}')"
      ecmd="$(echo "$line" | awk '{$1=""; sub(/^ /,""); print}' | cut -c1-65)"
      echo -e "  ${YELLOW}⊘${RESET} Excluded:  ${DIM}PID $epid  ${ecmd}${RESET}"
    done
  fi

  ui_section "Caffeinate processes" "Captured helpers will be released before sleep."
  if [[ -n "$PREFLIGHT_CAFFEINATE" ]]; then
    echo "$PREFLIGHT_CAFFEINATE" | while IFS= read -r line; do
      echo -e "  ${DIM}${line}${RESET}"
    done
  else
    echo -e "  ${DIM}  none running${RESET}"
  fi

  ui_section "Sleep assertions" "Detected with pmset -g assertions."
  if [[ ${#PREFLIGHT_ASSERTIONS[@]} -eq 0 ]]; then
    echo -e "  ${DIM}  none${RESET}"
  elif have_gum && [[ "${COLUMNS:-100}" -ge 88 ]]; then
    local entry sev pid name type label
    {
      for entry in "${PREFLIGHT_ASSERTIONS[@]}"; do
        IFS='|' read -r sev pid name type <<<"$entry"
        case "$sev" in
          blocker) label="BLOCKS SLEEP" ;;
          release) label="will release" ;;
          system) label="system benign" ;;
          display) label="display only" ;;
          user) label="user active" ;;
          *) label="info" ;;
        esac
        printf '%s,%s,%s,%s\n' "$label" "$pid" "$name" "$type"
      done
    } | ui_table "State,PID,Process,Assertion"
  else
    local entry sev pid name type
    for entry in "${PREFLIGHT_ASSERTIONS[@]}"; do
      IFS='|' read -r sev pid name type <<<"$entry"
      case "$sev" in
        blocker)
          echo -e "  ${RED}✖${RESET} ${BOLD}${name}${RESET} (PID $pid): ${RED}${type}${RESET} ${DIM}← BLOCKS SYSTEM SLEEP${RESET}"
          ;;
        release)
          echo -e "  ${GREEN}✔${RESET} ${name} (PID $pid): ${type} ${DIM}← will release${RESET}"
          ;;
        system)
          echo -e "  ${DIM}ℹ  ${name} (PID $pid): ${type} (macOS system daemon — benign)${RESET}"
          ;;
        display)
          echo -e "  ${YELLOW}⚠${RESET}  ${name} (PID $pid): ${type} ${DIM}← display only, system will still sleep${RESET}"
          ;;
        user)
          echo -e "  ${DIM}ℹ  ${name} (PID $pid): ${type} (harmless — auto-dismissed when idle)${RESET}"
          ;;
        *)
          echo -e "  ${DIM}ℹ  ${name} (PID $pid): ${type}${RESET}"
          ;;
      esac
    done
  fi

  ui_section "Power state"
  ui_kv "Battery" "${PREFLIGHT_BATTERY_PCT} (${PREFLIGHT_BATTERY_SRC})"
  ui_kv "Display sleep" "${PREFLIGHT_DISPLAYSLEEP_MIN:-?} min"
  ui_kv "System sleep" "${PREFLIGHT_SLEEP_MIN:-?} min"
  ui_kv "Hibernate mode" "${PREFLIGHT_HIBERNATE_MODE:-?}"
  local lid_display="unknown"
  case "$PREFLIGHT_LID" in
    Yes) lid_display="closed" ;;
    No) lid_display="open" ;;
  esac
  ui_kv "Lid" "$lid_display"

  ui_section "Active user sessions"
  if [[ -n "$PREFLIGHT_SESSIONS" ]]; then
    echo "$PREFLIGHT_SESSIONS" | while IFS= read -r line; do
      echo -e "  ${DIM}${line}${RESET}"
    done
  else
    echo -e "  ${DIM}  none${RESET}"
  fi

  ui_section "Verdict"
  if [[ "$PREFLIGHT_SCAN_OK" != true ]]; then
    ui_panel warning "Sleep-blocker scan unavailable" \
      "pmset -g assertions failed or returned unexpected output." \
      "goodnight cannot verify whether the Mac will actually sleep."
  elif [[ ${#PREFLIGHT_BLOCKERS[@]} -eq 0 ]]; then
    ui_panel success "No active sleep blockers detected" \
      "Releasing caffeinate will allow the Mac to sleep normally."
    if [[ ${#PREFLIGHT_SYSTEM[@]} -gt 0 ]]; then
      print_step "${#PREFLIGHT_SYSTEM[@]} macOS system daemon assertion(s) detected; the OS releases these at sleep time."
    fi
    if [[ ${#PREFLIGHT_DISPLAY_ONLY[@]} -gt 0 ]]; then
      print_step "${#PREFLIGHT_DISPLAY_ONLY[@]} display-only assertion(s) detected; these do not prevent system sleep."
    fi
  else
    local count=${#PREFLIGHT_BLOCKERS[@]}
    ui_panel danger "${count} active system-sleep blocker(s)" \
      "Releasing caffeinate alone will not be sufficient." \
      "These processes must exit or release their assertions first."
    local entry pid name type
    for entry in "${PREFLIGHT_BLOCKERS[@]}"; do
      IFS='|' read -r pid name type <<<"$entry"
      echo -e "    • ${BOLD}${name}${RESET} (PID $pid) — ${RED}${type}${RESET}"
    done
  fi
  echo ""
}

# -- JSON render
render_preflight_json() {
  local entry pid name type sev first
  local target_pid="" target_cmd=""
  if [[ -n "$PREFLIGHT_TARGET" ]]; then
    target_pid="$(echo "$PREFLIGHT_TARGET" | awk 'NR==1{print $1}')"
    target_cmd="$(echo "$PREFLIGHT_TARGET" | awk 'NR==1{$1=""; sub(/^ /,""); print}')"
  fi

  printf '{\n'
  printf '  "target": '
  if [[ -n "$target_pid" ]]; then
    printf '{"pid": %s, "command": "%s"}' "$target_pid" "$(json_escape "$target_cmd")"
  else
    printf 'null'
  fi
  printf ',\n'

  # Excluded
  printf '  "excluded": ['
  first=true
  if [[ -n "$PREFLIGHT_EXCLUDED" ]]; then
    while IFS= read -r line; do
      local epid ecmd
      epid="$(echo "$line" | awk '{print $1}')"
      ecmd="$(echo "$line" | awk '{$1=""; sub(/^ /,""); print}')"
      [[ "$first" == true ]] && first=false || printf ','
      printf '\n    {"pid": %s, "command": "%s"}' "$epid" "$(json_escape "$ecmd")"
    done <<<"$PREFLIGHT_EXCLUDED"
    printf '\n  '
  fi
  printf '],\n'

  # Caffeinate pids
  printf '  "caffeinate_pids": ['
  first=true
  local caff_pids
  caff_pids="$(pgrep caffeinate 2>/dev/null || true)"
  if [[ -n "$caff_pids" ]]; then
    while IFS= read -r pid; do
      [[ "$first" == true ]] && first=false || printf ', '
      printf '%s' "$pid"
    done <<<"$caff_pids"
  fi
  printf '],\n'

  # Assertions
  printf '  "assertions": ['
  first=true
  for entry in "${PREFLIGHT_ASSERTIONS[@]}"; do
    IFS='|' read -r sev pid name type <<<"$entry"
    [[ "$first" == true ]] && first=false || printf ','
    printf '\n    {"severity": "%s", "pid": %s, "name": "%s", "type": "%s"}' \
      "$sev" "$pid" "$(json_escape "$name")" "$(json_escape "$type")"
  done
  [[ "$first" == false ]] && printf '\n  '
  printf '],\n'

  # Blockers
  printf '  "blockers": ['
  first=true
  for entry in "${PREFLIGHT_BLOCKERS[@]}"; do
    IFS='|' read -r pid name type <<<"$entry"
    [[ "$first" == true ]] && first=false || printf ','
    printf '\n    {"pid": %s, "name": "%s", "type": "%s"}' \
      "$pid" "$(json_escape "$name")" "$(json_escape "$type")"
  done
  [[ "$first" == false ]] && printf '\n  '
  printf '],\n'

  # Power + verdict
  local lid_display="unknown"
  case "$PREFLIGHT_LID" in Yes) lid_display="closed" ;; No) lid_display="open" ;; esac

  printf '  "power": {\n'
  printf '    "battery_percent": "%s",\n' "$(json_escape "$PREFLIGHT_BATTERY_PCT")"
  printf '    "battery_source": "%s",\n' "$(json_escape "$PREFLIGHT_BATTERY_SRC")"
  printf '    "system_sleep_min": "%s",\n' "$(json_escape "${PREFLIGHT_SLEEP_MIN:-?}")"
  printf '    "display_sleep_min": "%s",\n' "$(json_escape "${PREFLIGHT_DISPLAYSLEEP_MIN:-?}")"
  printf '    "hibernate_mode": "%s",\n' "$(json_escape "${PREFLIGHT_HIBERNATE_MODE:-?}")"
  printf '    "lid": "%s"\n' "$(json_escape "$lid_display")"
  printf '  },\n'
  printf '  "scan_ok": %s,\n' "$([[ "$PREFLIGHT_SCAN_OK" == true ]] && echo true || echo false)"
  # can_sleep: true only when scan succeeded AND no blockers. Null when the
  # scan failed — consumers must not treat that as a green light.
  if [[ "$PREFLIGHT_SCAN_OK" == true ]]; then
    printf '  "can_sleep": %s,\n' "$([[ ${#PREFLIGHT_BLOCKERS[@]} -eq 0 ]] && echo true || echo false)"
  else
    printf '  "can_sleep": null,\n'
  fi
  printf '  "blocker_count": %d\n' "${#PREFLIGHT_BLOCKERS[@]}"
  printf '}\n'
}

prompt_confirm() {
  local prompt="$1"
  local response
  printf "  %b " "$prompt"
  # Time-bounded: an unanswered prompt resolves to the safe default
  # rather than holding the process open indefinitely.
  if ! read -r -t "$PROMPT_TIMEOUT_SECS" response; then
    echo ""
    print_warn "No answer in ${PROMPT_TIMEOUT_SECS}s — assuming no."
    return 1
  fi
  case "$response" in
    [yY] | [yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

# Print blockers detected after watch (wrapped in function for scope hygiene)
print_post_watch_blockers() {
  local entry pid name type
  echo ""
  print_warn "${#PREFLIGHT_BLOCKERS[@]} sleep blocker(s) detected AFTER watch finished:"
  for entry in "${PREFLIGHT_BLOCKERS[@]}"; do
    IFS='|' read -r pid name type <<<"$entry"
    echo -e "    • ${BOLD}${name}${RESET} (PID $pid) — ${type}"
  done
  print_step "Sleep may not succeed. Releasing caffeinate anyway."
  log_event "POST_WATCH_BLOCKERS count=${#PREFLIGHT_BLOCKERS[@]}"
}

# ── Blocker classification ────────────────────────────────────
# System-managed processes (launchd-supervised Apple daemons) cannot
# be killed by the user without sudo, and macOS respawns them anyway.
# The user must instead quit the consumer app that triggered the
# assertion (e.g., quit Zoom to release cameracaptured's hold).
#
# These names include camera/audio/display daemons that commonly hold
# PreventUserIdleSystemSleep while a video app is active.
SYSTEM_MANAGED_BLOCKERS_REGEX='^(runningboardd|powerd|useractivityd|sharingd|cameracaptured|mediaanalysisd|screencaptureui|replayd|avconferenced|WirelessRadioManagerd|kernel_task|launchd)$'

# Return "system" if the blocker name is system-managed, "user" otherwise.
classify_blocker() {
  local name="$1"
  if [[ "$name" =~ $SYSTEM_MANAGED_BLOCKERS_REGEX ]]; then
    echo "system"
  else
    echo "user"
  fi
}

# Print a suggested action for a system-managed blocker so the user
# knows what to do instead of asking us to kill it.
system_blocker_hint() {
  local name="$1"
  case "$name" in
    runningboardd) echo "Routine macOS process-lifecycle assertion — released automatically at sleep time." ;;
    powerd | useractivityd | sharingd) echo "macOS power/activity daemon — released automatically at sleep time." ;;
    cameracaptured) echo "Camera is in use — quit Zoom/Meet/FaceTime/Chrome tabs/Continuity Camera." ;;
    mediaanalysisd) echo "Photos is analyzing media — will release on its own shortly." ;;
    screencaptureui | replayd) echo "Screen recording is active — stop the recording." ;;
    avconferenced) echo "A call/conference app is active — end the call." ;;
    *) echo "System-managed — quit the app that triggered this assertion." ;;
  esac
}

# Present the blocker-handling menu and act on the user's choice.
# Returns 0 on "proceed with watch" (either skipped or after successful
# termination), non-zero on "abort".
prompt_and_handle_blockers() {
  local entry pid name type kind
  local user_blockers=() system_blockers=()

  for entry in "${PREFLIGHT_BLOCKERS[@]}"; do
    IFS='|' read -r pid name type <<<"$entry"
    kind="$(classify_blocker "$name")"
    if [[ "$kind" == "system" ]]; then
      system_blockers+=("$entry")
    else
      user_blockers+=("$entry")
    fi
  done

  ui_panel warning "Sleep blockers detected" \
    "Some running processes are currently preventing system sleep."
  if [[ ${#user_blockers[@]} -gt 0 ]]; then
    ui_section "User apps" "These can be terminated by goodnight."
    for entry in "${user_blockers[@]}"; do
      IFS='|' read -r pid name type <<<"$entry"
      echo -e "    ${RED}✖${RESET} ${BOLD}${name}${RESET} (PID $pid) — ${type}"
    done
    echo ""
  fi
  if [[ ${#system_blockers[@]} -gt 0 ]]; then
    ui_section "System-managed" "These require your action; macOS will respawn them if killed."
    for entry in "${system_blockers[@]}"; do
      IFS='|' read -r pid name type <<<"$entry"
      echo -e "    ${YELLOW}⚠${RESET}  ${BOLD}${name}${RESET} (PID $pid) — ${type}"
      echo -e "       ${DIM}→ $(system_blocker_hint "$name")${RESET}"
    done
    echo ""
  fi

  if [[ "$FORCE" == true ]]; then
    print_warn "${#PREFLIGHT_BLOCKERS[@]} blocker(s) detected but --force was given — proceeding."
    return 0
  fi

  if [[ "$UNATTENDED" == true || "$STDIN_IS_TTY" != true ]]; then
    # Proceed rather than abort: the sleep itself is verified and
    # retried, so a blocker that survives shows up as a logged, reported
    # failure instead of a silent refusal — and aborting would guarantee
    # the machine stays awake, the worse of the two outcomes.
    #
    # Say *why* we are not asking. "No one to prompt" is confusing when
    # the user is sitting at the keyboard watching: they passed a flag
    # that means "do not ask me", which is a different fact.
    if [[ "$UNATTENDED" == true ]]; then
      print_warn "${#PREFLIGHT_BLOCKERS[@]} blocker(s) detected — not asking because ${BOLD}--unattended${RESET} is set; proceeding, sleep will be verified and retried."
      print_step "Run without ${BOLD}--unattended${RESET} to be offered the terminate/skip/abort menu."
      log_event "BLOCKERS_UNATTENDED_PROCEED count=${#PREFLIGHT_BLOCKERS[@]} reason=flag"
    else
      print_warn "${#PREFLIGHT_BLOCKERS[@]} blocker(s) detected, no TTY to prompt on — proceeding; sleep will be verified and retried."
      log_event "BLOCKERS_UNATTENDED_PROCEED count=${#PREFLIGHT_BLOCKERS[@]} reason=no-tty"
    fi
    return 0
  fi

  # Order matters: the first entry is what gum returns if the prompt
  # times out, so the safe non-destructive choice leads. Terminating
  # the user's apps must always be a deliberate act.
  local -a menu=()
  menu+=("s|Skip — proceed; sleep will be verified and retried")
  if [[ ${#user_blockers[@]} -gt 0 ]]; then
    menu+=("t|Terminate the ${#user_blockers[@]} user app(s) listed above")
  fi
  menu+=("a|Abort — I'll handle these manually")
  local choice
  choice="$(ui_choose "How would you like to proceed?" "${menu[@]}")"
  case "$choice" in
    t | terminate)
      if [[ ${#user_blockers[@]} -eq 0 ]]; then
        print_warn "No user-killable blockers — only system-managed ones remain. Skipping terminate."
        return 0
      fi
      terminate_user_blockers "${user_blockers[@]}"
      # Re-scan so the next render reflects reality.
      scan_assertions
      if [[ ${#PREFLIGHT_BLOCKERS[@]} -eq 0 ]]; then
        print_ok "All blockers cleared."
      else
        print_warn "${#PREFLIGHT_BLOCKERS[@]} blocker(s) remain after termination (likely system-managed):"
        for entry in "${PREFLIGHT_BLOCKERS[@]}"; do
          IFS='|' read -r pid name type <<<"$entry"
          echo -e "    ${YELLOW}⚠${RESET}  ${name} (PID $pid) — ${type}"
        done
        print_step "Proceeding with watch anyway."
      fi
      return 0
      ;;
    s | skip)
      print_warn "Skipping termination. Sleep may not succeed after Claude finishes."
      return 0
      ;;
    a | abort | "")
      print_warn "Aborted. Claude is still running; caffeinate untouched."
      return 1
      ;;
    *)
      print_warn "Unrecognized choice — aborting for safety."
      return 1
      ;;
  esac
}

# Send SIGTERM to each user blocker, wait up to 2 seconds, escalate to
# SIGKILL if still alive. Reports per-blocker success/failure. Never
# attempts to kill system-managed processes (caller has already
# filtered them out).
terminate_user_blockers() {
  local entry pid name type
  local stopped=() survived=()
  echo ""
  print_step "Terminating user-app blockers..."
  for entry in "$@"; do
    IFS='|' read -r pid name type <<<"$entry"
    if ! kill -0 "$pid" 2>/dev/null; then
      stopped+=("$name (PID $pid, already gone)")
      continue
    fi
    if kill "$pid" 2>/dev/null; then
      # Poll up to 2 seconds for graceful exit. The loop variable is
      # unused — we only care about the iteration count.
      local _
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
      done
      if kill -0 "$pid" 2>/dev/null; then
        if kill -9 "$pid" 2>/dev/null; then
          stopped+=("$name (PID $pid, SIGKILL)")
          log_event "BLOCKER_SIGKILL pid=$pid name=\"$name\""
        else
          survived+=("$name (PID $pid)")
          log_event "BLOCKER_KILL_FAILED pid=$pid name=\"$name\""
        fi
      else
        stopped+=("$name (PID $pid)")
        log_event "BLOCKER_STOPPED pid=$pid name=\"$name\""
      fi
    else
      survived+=("$name (PID $pid, kill denied)")
      log_event "BLOCKER_KILL_DENIED pid=$pid name=\"$name\""
    fi
  done
  if [[ ${#stopped[@]} -gt 0 ]]; then
    print_ok "Stopped ${#stopped[@]} blocker(s):"
    for s in "${stopped[@]}"; do
      echo -e "    ${GREEN}✔${RESET} ${DIM}${s}${RESET}"
    done
  fi
  if [[ ${#survived[@]} -gt 0 ]]; then
    print_warn "${#survived[@]} blocker(s) could not be stopped:"
    for s in "${survived[@]}"; do
      echo -e "    ${RED}✖${RESET} ${DIM}${s}${RESET}"
    done
  fi
}

# ── Auto-start caffeinate -dim if none is running ─────────────
# Ensures the Mac stays awake while we watch. If the user (or another
# tool) already has caffeinate running, we leave it alone — the end-
# of-watch release step will stop all caffeinate PIDs captured at
# start.
AUTO_STARTED_CAFFEINATE_PID=""
ensure_caffeinate_running() {
  [[ "$NO_AUTO_CAFFEINATE" == true ]] && return 0
  local existing
  existing="$(pgrep -u "$USER" caffeinate 2>/dev/null || true)"
  if [[ -n "$existing" ]]; then
    # These get captured and terminated at sleep time — they must be,
    # since their assertion is exactly what blocks sleep. Earlier
    # wording here implied the opposite, telling the user a caffeinate
    # they were relying on would be left untouched.
    print_warn "caffeinate already running (PIDs: $(echo "$existing" | tr '\n' ' ')) — goodnight will release these before it sleeps"
    return 0
  fi
  # Start caffeinate -dim in the background, detached from this shell
  # so it survives after we exit. `disown` suppresses the "terminated"
  # message when we eventually kill it.
  caffeinate -dim &
  AUTO_STARTED_CAFFEINATE_PID=$!
  disown "$AUTO_STARTED_CAFFEINATE_PID" 2>/dev/null || true
  # Tiny delay so pmset sees the assertion next time we scan.
  sleep 0.2
  print_ok "Started ${BOLD}caffeinate -dim${RESET} (PID $AUTO_STARTED_CAFFEINATE_PID) to keep the Mac awake"
  log_event "AUTO_CAFFEINATE_STARTED pid=$AUTO_STARTED_CAFFEINATE_PID"
}

# ── Verified sleep ────────────────────────────────────────────
#
# `pmset sleepnow` exits 0 whether or not the machine actually sleeps.
# If any process holds a PreventSystemSleep assertion, macOS quietly
# declines and pmset still reports success — so the old code announced
# "Good night", exited 0, and left the Mac awake all night with no trace
# of the failure. Every sleep now goes through here, which confirms the
# outcome against the kernel and retries.
#
# Confirmation signal: kern.sleeptime is the timestamp of the last
# transition into sleep. It moves if and only if the machine slept.
# (Note that if the Mac sleeps and is never woken, this function simply
# never returns — the process is frozen mid-call, which is the intended
# end state.)
sleep_stamp() {
  sysctl -n kern.sleeptime 2>/dev/null | tr -cd '0-9 ' | awk '{print $1}'
}
wake_stamp() {
  sysctl -n kern.waketime 2>/dev/null | tr -cd '0-9 ' | awk '{print $1}'
}

# Kill any caffeinate that has appeared since the watch began. Between
# retries this matters: a helper or another tool can start a fresh one
# while we were waiting, and it will block every subsequent attempt.
release_all_caffeinate() {
  local pids
  # shellcheck disable=SC2207
  pids=($(pgrep -u "$USER" caffeinate 2>/dev/null || true))
  ((${#pids[@]} == 0)) && return 0
  kill "${pids[@]}" 2>/dev/null || true
  sleep 0.3
  local still=()
  local p
  for p in "${pids[@]}"; do
    kill -0 "$p" 2>/dev/null && still+=("$p")
  done
  ((${#still[@]} > 0)) && kill -9 "${still[@]}" 2>/dev/null
  log_event "CAFFEINATE_RELEASED pids=${pids[*]}"
  return 0
}

# Request sleep and verify it happened. Returns 0 on confirmed sleep,
# 1 if every attempt was refused.
attempt_sleep() {
  local context="${1:-}"
  local attempt=1 s0 s1 t0 t1 elapsed backoff

  while ((attempt <= SLEEP_MAX_ATTEMPTS)); do
    s0="$(sleep_stamp)"
    t0=$(date +%s)
    log_event "SLEEP_ATTEMPT n=${attempt}/${SLEEP_MAX_ATTEMPTS} ctx=${context}"

    if ! pmset sleepnow >/dev/null 2>&1; then
      osascript -e 'tell application "System Events" to sleep' >/dev/null 2>&1 || true
    fi

    # Give macOS time to complete the transition. If it does, execution
    # stops here until the machine wakes.
    sleep "$SLEEP_VERIFY_SECS"

    t1=$(date +%s)
    s1="$(sleep_stamp)"
    elapsed=$((t1 - t0))

    if [[ -n "$s0" && -n "$s1" && "$s0" != "$s1" ]]; then
      log_event "SLEEP_CONFIRMED n=${attempt} via=kern.sleeptime"
      return 0
    fi
    # Fallback signal for the case where sysctl is unreadable: a wall
    # clock that jumped far past our wait can only mean we were
    # suspended through it.
    if ((elapsed > SLEEP_VERIFY_SECS + 10)); then
      log_event "SLEEP_CONFIRMED n=${attempt} via=clock_jump elapsed=${elapsed}s"
      return 0
    fi

    # Refused. Work out who is holding it and try to clear the way.
    scan_assertions
    local blocker_names=""
    if ((${#PREFLIGHT_BLOCKERS[@]} > 0)); then
      local entry bpid bname btype
      for entry in "${PREFLIGHT_BLOCKERS[@]}"; do
        IFS='|' read -r bpid bname btype <<<"$entry"
        blocker_names+="${bname}(${bpid}):${btype} "
      done
    fi
    log_event "SLEEP_REFUSED n=${attempt} blockers=[${blocker_names% }]"

    if ((attempt >= SLEEP_MAX_ATTEMPTS)); then
      break
    fi

    print_warn "Sleep was refused${blocker_names:+ — holding: ${blocker_names% }}. Retrying…"
    release_all_caffeinate
    backoff=$((attempt * SLEEP_RETRY_BACKOFF_SECS))
    sleep "$backoff"
    attempt=$((attempt + 1))
  done

  return 1
}

# ── Power-state gate ──────────────────────────────────────────
# Returns "AC", "Battery", or "Unknown".
# Unknown is returned on desktop Macs without a battery, or when
# pmset can't be parsed — in both cases we treat it like AC because
# there's no battery to protect.
get_power_source() {
  local batt
  batt="$(pmset -g batt 2>/dev/null)"
  if [[ -z "$batt" ]]; then
    echo "Unknown"
    return
  fi
  if echo "$batt" | grep -q "'AC Power'"; then
    echo "AC"
  elif echo "$batt" | grep -q "'Battery Power'"; then
    echo "Battery"
  else
    echo "Unknown"
  fi
}

# Extract the battery percent if present (e.g., "62%"), else empty.
get_battery_percent() {
  pmset -g batt 2>/dev/null | grep -oE '[0-9]+%' | head -1
}

# Render a small unicode battery gauge for a percentage.
# Usage: render_battery_gauge 62  →  ▓▓▓▓▓▓░░░░ 62%
# Width is 10 blocks by default. Returns an empty string if the input
# isn't a 0–100 integer.
render_battery_gauge() {
  local raw="$1" width="${2:-10}" pct_num filled empty bar
  # Accept "62", "62%", " 62 ", etc.
  pct_num="$(printf '%s' "$raw" | tr -cd '0-9')"
  [[ -z "$pct_num" ]] && return 0
  ((pct_num < 0)) && pct_num=0
  ((pct_num > 100)) && pct_num=100
  filled=$((pct_num * width / 100))
  empty=$((width - filled))
  bar="$(printf '%*s' "$filled" '' | tr ' ' '▓')$(printf '%*s' "$empty" '' | tr ' ' '░')"
  printf '%s %d%%' "$bar" "$pct_num"
}

# Block until external power is connected. If already on AC (or
# unknown power state), returns immediately. When on battery, shows a
# calm warning, then polls pmset every 2 seconds with a spinner.
# Honored flags:
#   --allow-battery : skip the gate entirely
#   --force         : also skips the gate (general "don't block me" override)
# Ctrl+C cleanly aborts via the existing on_interrupt trap.
wait_for_ac_power() {
  [[ "$ALLOW_BATTERY" == true ]] && return 0
  [[ "$FORCE" == true ]] && return 0

  local src pct gauge
  src="$(get_power_source)"
  if [[ "$src" != "Battery" ]]; then
    return 0
  fi

  pct="$(get_battery_percent)"
  gauge="$(render_battery_gauge "$pct")"

  # Styled warning card via gum (or hand-drawn fallback).
  local -a panel_lines=()
  [[ -n "$gauge" ]] && panel_lines+=("Battery:  ${gauge}" "")
  panel_lines+=(
    "Please connect your charger. goodnight will resume"
    "automatically the moment AC power is detected."
    ""
    "Press Ctrl+C to abort, or override with:"
    "  goodnight --allow-battery"
  )
  ui_panel warning "⚡  External power required" "${panel_lines[@]}"
  log_event "POWER_GATE_WAITING battery_pct=${pct:-unknown}"

  local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  local tick=0
  local start_ts now_ts elapsed
  start_ts=$(date +%s)

  # Poll loop. Use plain `sleep 2` — the FIFO-based micro_sleep isn't
  # set up yet at this point in the flow.
  while true; do
    src="$(get_power_source)"
    if [[ "$src" != "Battery" ]]; then
      break
    fi
    now_ts=$(date +%s)
    elapsed=$((now_ts - start_ts))
    pct="$(get_battery_percent)"
    gauge="$(render_battery_gauge "$pct")"
    if [[ "$USE_SPINNER" == true ]]; then
      # Static format string; every dynamic value passes through %s so
      # stray `%` characters in $pct / $gauge can never corrupt it.
      printf "\r\033[K  %s%s%s  %sWaiting for charger…%s  %ds  %s%s%s" \
        "$CYAN" "${frames[$tick]}" "$RESET" \
        "$DIM" "$RESET" \
        "$elapsed" \
        "$YELLOW" "${gauge:-on battery}" "$RESET"
    else
      # Non-TTY: emit a status line every 30 seconds so callers have
      # something to watch.
      if ((elapsed % 30 == 0)); then
        echo "  … still waiting for charger (${elapsed}s elapsed${pct:+, battery ${pct}})"
      fi
    fi
    tick=$(((tick + 1) % ${#frames[@]}))
    sleep 2
  done

  # Clear the spinner line.
  [[ "$USE_SPINNER" == true ]] && printf "\r\033[K"

  pct="$(get_battery_percent)"
  gauge="$(render_battery_gauge "$pct")"
  if [[ -n "$gauge" ]]; then
    print_ok "External power detected  ${GREEN}${gauge}${RESET} — resuming."
  else
    print_ok "External power detected — resuming."
  fi
  log_event "POWER_GATE_RELEASED battery_pct=${pct:-unknown}"
  echo ""
}

# ── Self-update check ─────────────────────────────────────────
# Compares the running script's sha256 to the remote canonical script.
# Rate-limited to once per UPDATE_CACHE_TTL_SECS (default 24h) via a
# timestamp file under ~/.cache/sleep-after-claude. Fails open:
# network errors, missing curl/shasum, or any unexpected output cause
# the check to be silently skipped so offline users aren't blocked.
check_for_update() {
  [[ "$SKIP_UPDATE_CHECK_FORCED" == true ]] && return 0
  [[ "$SKIP_UPDATE_CHECK" == true ]] && return 0
  command -v curl >/dev/null 2>&1 || return 0
  command -v shasum >/dev/null 2>&1 || return 0

  mkdir -p "$UPDATE_CACHE_DIR" 2>/dev/null || return 0
  local stamp="$UPDATE_CACHE_DIR/last-update-check"
  if [[ -f "$stamp" ]]; then
    local last_ts now_ts
    last_ts="$(cat "$stamp" 2>/dev/null || echo 0)"
    now_ts="$(date +%s)"
    if [[ "$last_ts" =~ ^[0-9]+$ ]] && ((now_ts - last_ts < UPDATE_CACHE_TTL_SECS)); then
      return 0
    fi
  fi

  # Download remote script with a short timeout so the check never
  # blocks for long on a slow network. ui_spin shows a spinner when
  # gum is installed; otherwise runs curl directly.
  local tmp_remote
  tmp_remote="$(mktemp -t sac-update-check.XXXXXX 2>/dev/null)" || return 0
  if ! ui_spin "Checking for updates…" -- curl -fsSL --max-time 5 "$UPDATE_CHECK_URL" -o "$tmp_remote" >/dev/null 2>&1; then
    rm -f "$tmp_remote"
    return 0
  fi
  # Basic sanity so a CDN error page doesn't fool us.
  if [[ ! -s "$tmp_remote" ]] || ! head -1 "$tmp_remote" | grep -q '^#!/usr/bin/env bash'; then
    rm -f "$tmp_remote"
    return 0
  fi

  local local_sha remote_sha self_path
  self_path="${BASH_SOURCE[0]:-$0}"
  [[ -f "$self_path" ]] || {
    rm -f "$tmp_remote"
    return 0
  }
  local_sha="$(shasum -a 256 "$self_path" 2>/dev/null | awk '{print $1}')"
  remote_sha="$(shasum -a 256 "$tmp_remote" 2>/dev/null | awk '{print $1}')"
  rm -f "$tmp_remote"

  # Record that we checked, regardless of result, to honor TTL.
  date +%s >"$stamp" 2>/dev/null || true

  if [[ -z "$local_sha" || -z "$remote_sha" ]] || [[ "$local_sha" == "$remote_sha" ]]; then
    return 0
  fi

  echo ""
  print_step "A newer version of sleep-after-claude is available."
  echo -e "    ${DIM}Local sha:  ${local_sha:0:12}…${RESET}"
  echo -e "    ${DIM}Remote sha: ${remote_sha:0:12}…${RESET}"
  if [[ "$STDIN_IS_TTY" != true ]]; then
    print_warn "Not a TTY — skipping update prompt. Run ${BOLD}goodnight${RESET} interactively to update."
    return 0
  fi
  if ui_confirm "Update now?"; then
    echo ""
    print_step "Running installer..."
    # Run the installer with SAC_SKIP_HOOK_INSTALL=1 to avoid a
    # double-install of hooks (user already has them if they got
    # here via --smart default — the installer's hook step would
    # be a no-op, but the announcement is unnecessary noise
    # mid-session).
    if SAC_SKIP_HOOK_INSTALL=1 curl -fsSL --max-time 30 "$UPDATE_INSTALLER_URL" | bash; then
      echo ""
      print_ok "Update complete — re-executing with the new version."
      echo ""
      # F-05: exec into the freshly-installed script so the rest of
      # this invocation runs the new code, not the stale in-memory
      # copy. We re-invoke via the same path we were started from
      # (usually ~/bin/sleep-after-claude) and preserve the original
      # argv captured at script entry. Add SAC_SKIP_UPDATE_CHECK=1 in
      # the child env so we don't re-prompt in the update-check we
      # just completed. Use `exec` so the process replaces itself.
      local self_path_for_exec
      self_path_for_exec="${BASH_SOURCE[0]:-$0}"
      if [[ -x "$self_path_for_exec" ]]; then
        export SAC_SKIP_UPDATE_CHECK=1
        exec "$self_path_for_exec" "${SAC_ORIGINAL_ARGS[@]}"
      fi
      # Fallthrough: exec should never return. If it does
      # (unwritable path, script not on disk, etc.) warn and
      # continue with the stale in-memory script.
      print_warn "Could not re-exec after update — continuing with old version."
    else
      print_warn "Update failed. Continuing with the currently-installed version."
    fi
  else
    echo ""
    print_step "Skipping update. Run ${BOLD}goodnight --check-update${RESET} later to re-prompt."
  fi
}

# jq predicate identifying a hook entry as one of ours.
#
# Ordering matters. The command-string sentinel is checked FIRST and the
# ._managed_by JSON tag second, because the tag is the fragile half: it
# is a key we invented, sitting next to keys Claude Code owns, and
# anything that rewrites settings.json is free to drop it while faithfully
# preserving the command it annotates. That is not hypothetical — it is
# exactly how this command silently stopped working. Detection must key on
# the payload that has to survive for the hook to run at all.
# Two questions, deliberately distinct:
#
#   gn_functional  does this entry still carry a command that does the
#                  job? This is what health must ask. The tag alone is
#                  not enough: an entry whose command was emptied or
#                  replaced would otherwise report healthy, skip repair,
#                  and leave an active turn markerless for the watcher
#                  to sleep over — the original bug wearing the opposite
#                  mask.
#
#   gn_owned       is this entry ours to rewrite or remove? Broader on
#                  purpose, because a mangled entry we installed is
#                  still ours to clean up, so ownership accepts the tag.
HOOK_MATCH_JQ='def gn_cmds: [ (.hooks // [])[] | (.command // "") ];
  def gn_functional: (gn_cmds | any(test("goodnight-hook|goodnight/busy")));
  def gn_owned: gn_functional or (._managed_by == "goodnight");'

# Report the health of goodnight'"'"'s Claude Code hook integration.
# Echoes exactly one word:
#   ok       UserPromptSubmit, Stop and SessionEnd hooks all present
#            and usable
#   partial  one of the two present — markers would leak or never appear
#   missing  neither present
#   nofile   no settings.json at all
#   badjson  settings.json exists but does not parse
#   nojq     jq absent, so the hook bodies could not run even if present
# Smart mode needs jq at HOOK runtime, so a missing jq is a health
# failure regardless of what the file says.
hooks_health() {
  command -v jq >/dev/null 2>&1 || {
    echo nojq
    return
  }
  [[ -f "$CLAUDE_SETTINGS_FILE" ]] || {
    echo nofile
    return
  }
  local counts
  # Parenthesised deliberately: in jq `|` binds looser than `,`, so
  # `[…] | length, […] | length` would parse as one pipeline and emit
  # the wrong pair.
  counts="$(jq -r "${HOOK_MATCH_JQ}"'
    ([ (.hooks.UserPromptSubmit // [])[] | select(gn_functional) ] | length),
    ([ (.hooks.Stop            // [])[] | select(gn_functional) ] | length),
    ([ (.hooks.SessionEnd      // [])[] | select(gn_functional) ] | length)
  ' "$CLAUDE_SETTINGS_FILE" 2>/dev/null)" || {
    echo badjson
    return
  }
  [[ -n "$counts" ]] || {
    echo badjson
    return
  }
  local ups stop send
  ups="$(printf '%s\n' "$counts" | sed -n 1p)"
  stop="$(printf '%s\n' "$counts" | sed -n 2p)"
  send="$(printf '%s\n' "$counts" | sed -n 3p)"
  [[ "$ups" =~ ^[0-9]+$ && "$stop" =~ ^[0-9]+$ && "$send" =~ ^[0-9]+$ ]] || {
    echo badjson
    return
  }
  # SessionEnd counts toward health, not just the other two. An install
  # predating it reports `partial`, which routes it through repair once
  # and leaves it whole. Otherwise an upgraded machine keeps leaking a
  # marker on every quit or crash until the stale window expires, and
  # never finds out it is missing the hook that would prevent it.
  if ((ups > 0 && stop > 0 && send > 0)); then
    echo ok
  elif ((ups > 0 || stop > 0 || send > 0)); then
    echo partial
  else
    echo missing
  fi
}

# Return 0 only when the integration is fully operational. A partial
# install is deliberately NOT "installed": without UserPromptSubmit no
# marker is ever written, so a marker-trusting watcher would read a busy
# machine as idle and sleep it mid-task. Fail toward staying awake.
hooks_installed() {
  [[ "$(hooks_health)" == "ok" ]]
}

# Return 0 when our hook entries exist but have lost the ._managed_by
# tag. They still work — detection matches the command sentinel — but
# --uninstall-hooks and reinstall de-duplication both key on the tag, so
# an untagged install is a booby trap for the next write. Repair fixes
# it in place rather than appending a second copy.
hooks_need_retag() {
  command -v jq >/dev/null 2>&1 || return 1
  [[ -f "$CLAUDE_SETTINGS_FILE" ]] || return 1
  jq -e "${HOOK_MATCH_JQ}"'
    [ ((.hooks.UserPromptSubmit // []) + (.hooks.Stop // []) + (.hooks.SessionEnd // []))[]
      | select(gn_owned) | select(._managed_by != "goodnight") ] | length > 0
  ' "$CLAUDE_SETTINGS_FILE" >/dev/null 2>&1
}

# Restore a degraded hook integration to full health, in place.
#
# Two failure shapes are repaired:
#   untagged  our commands survived but ._managed_by was stripped —
#             re-tag the existing entries (never append a duplicate)
#   partial   one event lost its entry entirely — reinstall both sides
#
# Returns 0 if the integration is healthy afterwards, 1 otherwise.
# Never prompts: this runs on the unattended path.
repair_claude_hooks() {
  local health
  health="$(hooks_health)"

  if [[ "$health" == "nojq" ]]; then
    return 1
  fi

  # Re-tag first — cheap, non-destructive, and it makes a subsequent
  # reinstall de-duplicate correctly instead of doubling the hooks.
  if hooks_need_retag; then
    local tmp
    tmp="$(mktemp)" || return 1
    if jq "${HOOK_MATCH_JQ}"'
      def retag: if gn_owned then (._managed_by = "goodnight") else . end;
      .hooks = (.hooks // {})
      | (if (.hooks.UserPromptSubmit | type) == "array" then .hooks.UserPromptSubmit |= map(retag) else . end)
      | (if (.hooks.Stop            | type) == "array" then .hooks.Stop            |= map(retag) else . end)
      | (if (.hooks.SessionEnd      | type) == "array" then .hooks.SessionEnd      |= map(retag) else . end)
    ' "$CLAUDE_SETTINGS_FILE" >"$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
      cp "$CLAUDE_SETTINGS_FILE" "${CLAUDE_SETTINGS_FILE}.bak.$(date +%s)" 2>/dev/null || true
      mv "$tmp" "$CLAUDE_SETTINGS_FILE" 2>/dev/null || rm -f "$tmp"
      log_event "HOOKS_RETAGGED"
    else
      rm -f "$tmp"
    fi
    health="$(hooks_health)"
  fi

  # Anything short of a complete install gets a full (idempotent)
  # reinstall. install_claude_hooks de-duplicates by command sentinel as
  # well as by tag, so this cannot stack copies.
  if [[ "$health" != "ok" ]]; then
    install_claude_hooks >/dev/null 2>&1 || true
    log_event "HOOKS_REINSTALLED prior_state=$health"
    health="$(hooks_health)"
  fi

  [[ "$health" == "ok" ]]
}

# ── Session activity model ────────────────────────────────────
#
# Two independent signals answer "is any agent still working?", and the
# watcher requires BOTH to be quiet before it will sleep the machine.
#
#   1. Busy markers   — written by our UserPromptSubmit hook, removed by
#                       Stop/SessionEnd. Precise and instant, but only as
#                       trustworthy as the hooks themselves.
#   2. Transcript mtime — Claude appends to
#                       $CLAUDE_PROJECTS_DIR/<slug>/<session_id>.jsonl
#                       throughout a turn. Needs no cooperation, cannot
#                       be silently uninstalled, and covers sessions we
#                       have no marker for at all (background agents,
#                       sessions started before the hooks existed).
#
# Marker presence decides WHICH sessions to care about; transcript mtime
# decides whether a marked session is genuinely alive. That combination
# is what makes a crashed session, or one parked on a permission prompt,
# stop blocking sleep — the old code would wait on its marker for a full
# 24 hours.

# Locate the transcript for a session id. Echoes the path, or nothing.
transcript_for_session() {
  local sid="$1" f
  [[ -n "$sid" ]] || return 1
  [[ -d "$CLAUDE_PROJECTS_DIR" ]] || return 1
  for f in "$CLAUDE_PROJECTS_DIR"/*/"${sid}.jsonl"; do
    [[ -f "$f" ]] || continue
    printf '%s' "$f"
    return 0
  done
  return 1
}

# Return 0 if ANY agent — Claude Code, Codex, or anything added via
# SAC_EXTRA_ACTIVITY_DIRS — wrote to its session log within the last N
# seconds. One find(1) per root, and -quit stops at the first hit, so
# cost does not grow with session-history size.
transcript_active_within() {
  local secs="$1" mins dir hit
  # find -mmin takes minutes; round up so a sub-minute window still
  # looks at the most recent minute rather than truncating to zero.
  mins=$(((secs + 59) / 60))
  ((mins < 1)) && mins=1
  for dir in "${AGENT_ACTIVITY_DIRS[@]}"; do
    [[ -d "$dir" ]] || continue
    hit="$(find "$dir" -name '*.jsonl' -mmin -"$mins" -print -quit 2>/dev/null)"
    [[ -n "$hit" ]] && return 0
  done
  return 1
}

# Echo the epoch mtime of the most recently written agent session log
# across every activity root, or nothing when there are none.
newest_agent_activity() {
  local dir
  {
    for dir in "${AGENT_ACTIVITY_DIRS[@]}"; do
      [[ -d "$dir" ]] || continue
      find "$dir" -name '*.jsonl' -print0 2>/dev/null |
        xargs -0 stat -f '%m' 2>/dev/null
    done
  } | sort -rn | head -1
}

# Total CPU time consumed by every live agent process, in centiseconds.
# Echoes 0 when none are running or the figures cannot be read, so a
# failure here degrades to "no veto" rather than to a stuck watch.
agent_cpu_centiseconds() {
  local pids csv name
  pids="$(
    for name in "${AGENT_PROCESS_NAMES[@]}"; do
      pgrep -x "$name" 2>/dev/null
    done | sort -u
  )"
  [[ -n "$pids" ]] || {
    echo 0
    return
  }
  csv="$(printf '%s' "$pids" | tr '\n' ',' | sed 's/,$//')"
  # macOS renders cumulative CPU as [dd-][hh:]mm:ss.ss, so parse from
  # the right rather than assuming a field count.
  # Captured and validated at a single exit point. The obvious
  # `... | awk ... || echo 0` is wrong under `set -o pipefail`: awk's
  # END block still prints its 0 when ps fails, and the failing pipeline
  # then fires the fallback as well, emitting "0\n0" and breaking this
  # function's one-number contract.
  local out
  out="$(
    ps -p "$csv" -o time= 2>/dev/null | awk '
      {
        t = $1; d = 0
        if (index(t, "-")) { split(t, a, "-"); d = a[1]; t = a[2] }
        n = split(t, f, ":"); s = 0
        if (n == 3)      s = f[1] * 3600 + f[2] * 60 + f[3]
        else if (n == 2) s = f[1] * 60 + f[2]
        else             s = f[1]
        total += d * 86400 + s
      }
      END { printf "%d\n", total * 100 }
    ' 2>/dev/null
  )" || out=""
  [[ "$out" =~ ^[0-9]+$ ]] || out=0
  printf '%s\n' "$out"
}

# Delete busy markers that no longer represent live work:
#   - session transcript missing entirely (session id we can't verify,
#     and the marker itself is older than the stale window)
#   - session transcript untouched for longer than the stale window
#     (crashed, or parked waiting on input — either way, not working)
# Echoes the number of markers reaped.
reap_dead_markers() {
  [[ -d "$BUSY_DIR" ]] || {
    echo 0
    return
  }
  local f sid tpath probe mtime age reaped=0 now cutoff
  now="$(date +%s)"
  cutoff=$((SMART_STALE_MARKER_MINS * 60))
  for f in "$BUSY_DIR"/*; do
    [[ -f "$f" ]] || continue
    sid="$(basename "$f")"
    # The session transcript is the authority on liveness. Only when
    # there is none to consult does the marker's own age stand in, so an
    # unrecognised session still gets a full stale window of benefit of
    # the doubt before we discount it.
    tpath="$(transcript_for_session "$sid" || true)"
    probe="${tpath:-$f}"
    # stat rather than `find -mmin`: one fork either way, but this
    # compares exact seconds instead of find's minute granularity, so
    # the stale window means what it says.
    mtime="$(stat -f %m "$probe" 2>/dev/null)"
    [[ "$mtime" =~ ^[0-9]+$ ]] || continue
    age=$((now - mtime))
    if ((age > cutoff)); then
      rm -f "$f" 2>/dev/null && reaped=$((reaped + 1))
    fi
  done
  echo "$reaped"
}

# Count busy markers that survive the liveness check above.
count_busy_sessions() {
  [[ -d "$BUSY_DIR" ]] || {
    echo 0
    return
  }
  reap_dead_markers >/dev/null
  local f count=0
  for f in "$BUSY_DIR"/*; do
    [[ -f "$f" ]] && count=$((count + 1))
  done
  echo "$count"
}

# ── Claude Code hook integration ──────────────────────────────
# These functions manage three hooks in ~/.claude/settings.json:
#   - UserPromptSubmit: touch $BUSY_DIR/<session_id> when user sends
#     a new message to Claude (session is now working).
#   - Stop: remove $BUSY_DIR/<session_id> when Claude finishes its
#     response and returns control (session is now idle).
#
# With those markers in place, --smart mode can sleep the moment all
# Claude sessions are idle (no file in $BUSY_DIR) without relying on
# the claude process to actually exit.

# Install the three hooks by merging into the existing ~/.claude/settings.json.
# Requires jq. Preserves any other hooks the user has.
install_claude_hooks() {
  if ! command -v jq >/dev/null 2>&1; then
    print_error "jq is required to install hooks. Install it with: ${BOLD}brew install jq${RESET}"
    return 1
  fi
  mkdir -p "$(dirname "$CLAUDE_SETTINGS_FILE")" 2>/dev/null || true
  mkdir -p "$BUSY_DIR" 2>/dev/null || true

  local prompt_cmd stop_cmd
  # These commands run inside Claude's hook subshell. Stdin is a JSON
  # blob with .session_id.
  #
  # F-03 fix: use the literal string $HOME in the hook command so it
  # expands at HOOK RUNTIME, not at install time. This survives home-
  # directory moves and differs-across-contexts (cron, launchd, etc.).
  # The default busy dir is "${HOME}/.local/state/goodnight/busy" —
  # rebuild the equivalent expression without freezing the absolute
  # path. If the user set a non-default BUSY_DIR, we freeze that
  # path (no way to round-trip an arbitrary override into a
  # shell-evaluated string safely).
  local busy_path_expr
  if [[ "$BUSY_DIR" == "${HOME}/.local/state/goodnight/busy" ]]; then
    busy_path_expr='"$HOME/.local/state/goodnight/busy"'
  else
    # Non-default path — freeze the absolute value but single-quote
    # it so $ and other specials in the path are literal, not
    # interpreted by Claude's hook shell (F-04 hardening).
    local quoted_busy
    # Escape any single quotes in the path so the shell single-quote
    # stays balanced: a'b → 'a'\''b'
    quoted_busy="${BUSY_DIR//\'/\'\\\'\'}"
    busy_path_expr="'${quoted_busy}'"
  fi
  # Every command carries the "# goodnight-hook" sentinel as a trailing
  # shell comment: inert at runtime, but it makes the entry
  # self-identifying even after a settings.json rewrite drops the
  # sibling ._managed_by key. See HOOK_MATCH_JQ.
  local sentinel="# ${HOOK_SENTINEL}"
  prompt_cmd="mkdir -p ${busy_path_expr} 2>/dev/null; sid=\$(jq -r .session_id 2>/dev/null); [ -n \"\$sid\" ] && touch ${busy_path_expr}/\"\$sid\"; exit 0 ${sentinel}"
  stop_cmd="sid=\$(jq -r .session_id 2>/dev/null); [ -n \"\$sid\" ] && rm -f ${busy_path_expr}/\"\$sid\"; exit 0 ${sentinel}"
  # Stop fires at the end of each assistant turn. SessionEnd covers the
  # ways a session can leave without a final turn — quit mid-response,
  # closed terminal, crash — which is precisely how the marker
  # directory had accumulated 30 orphans. Same body as stop_cmd; the
  # remove is idempotent.
  local end_cmd="$stop_cmd"

  # Back up existing file
  if [[ -f "$CLAUDE_SETTINGS_FILE" ]]; then
    cp "$CLAUDE_SETTINGS_FILE" "${CLAUDE_SETTINGS_FILE}.bak.$(date +%s)"
  else
    echo '{}' >"$CLAUDE_SETTINGS_FILE"
  fi

  # Merge the hooks. Strip any prior goodnight entry first so reinstalls
  # replace rather than accumulate.
  #
  # De-duplication matches on the command sentinel as well as the
  # ._managed_by tag (gn_owned). Matching on the tag alone is what would
  # turn a repair into a duplicate: an entry that had lost its tag would
  # survive the strip, then the fresh copy would be appended beside it
  # and every prompt would fire the hook twice.
  local tmp
  tmp="$(mktemp)"
  if ! jq --arg prompt_cmd "$prompt_cmd" --arg stop_cmd "$stop_cmd" --arg end_cmd "$end_cmd" \
    "${HOOK_MATCH_JQ}"'
    .hooks = (.hooks // {})
    | .hooks.UserPromptSubmit = [ (.hooks.UserPromptSubmit // [])[] | select(gn_owned | not) ]
    | .hooks.Stop             = [ (.hooks.Stop             // [])[] | select(gn_owned | not) ]
    | .hooks.SessionEnd       = [ (.hooks.SessionEnd       // [])[] | select(gn_owned | not) ]
    | .hooks.UserPromptSubmit += [{
        matcher: "",
        _managed_by: "goodnight",
        hooks: [{ type: "command", command: $prompt_cmd }]
      }]
    | .hooks.Stop += [{
        matcher: "",
        _managed_by: "goodnight",
        hooks: [{ type: "command", command: $stop_cmd }]
      }]
    | .hooks.SessionEnd += [{
        matcher: "",
        _managed_by: "goodnight",
        hooks: [{ type: "command", command: $end_cmd }]
      }]
  ' "$CLAUDE_SETTINGS_FILE" >"$tmp"; then
    rm -f "$tmp"
    print_error "Could not install goodnight hooks: $CLAUDE_SETTINGS_FILE is not valid JSON."
    return 1
  fi
  if ! mv "$tmp" "$CLAUDE_SETTINGS_FILE"; then
    rm -f "$tmp"
    print_error "Could not install goodnight hooks: failed to update $CLAUDE_SETTINGS_FILE."
    return 1
  fi

  print_ok "Installed goodnight hooks into ${BOLD}$CLAUDE_SETTINGS_FILE${RESET}"
  print_step "Busy markers will appear at ${BOLD}$BUSY_DIR${RESET}"
  print_step "Start a new Claude session, then use ${BOLD}goodnight --smart${RESET} to sleep when all sessions are idle."
}

# Remove goodnight's hook entries from ~/.claude/settings.json, leaving
# any user-defined entries untouched.
uninstall_claude_hooks() {
  if [[ ! -f "$CLAUDE_SETTINGS_FILE" ]]; then
    print_warn "No Claude settings file at $CLAUDE_SETTINGS_FILE — nothing to remove."
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    print_error "jq is required to uninstall hooks. Install it with: ${BOLD}brew install jq${RESET}"
    return 1
  fi
  local tmp
  tmp="$(mktemp)"
  # Matches on the command sentinel as well as the tag, so an entry that
  # has lost ._managed_by is still removable instead of becoming an
  # un-uninstallable orphan.
  if ! jq "${HOOK_MATCH_JQ}"'
    .hooks = (.hooks // {})
    | .hooks.UserPromptSubmit = [ (.hooks.UserPromptSubmit // [])[] | select(gn_owned | not) ]
    | .hooks.Stop             = [ (.hooks.Stop             // [])[] | select(gn_owned | not) ]
    | .hooks.SessionEnd       = [ (.hooks.SessionEnd       // [])[] | select(gn_owned | not) ]
    # Drop empty arrays so settings.json stays tidy.
    | if (.hooks.UserPromptSubmit | length) == 0 then del(.hooks.UserPromptSubmit) else . end
    | if (.hooks.Stop            | length) == 0 then del(.hooks.Stop)            else . end
    | if (.hooks.SessionEnd      | length) == 0 then del(.hooks.SessionEnd)      else . end
    | if (.hooks | length) == 0 then del(.hooks) else . end
  ' "$CLAUDE_SETTINGS_FILE" >"$tmp"; then
    rm -f "$tmp"
    print_error "Could not remove goodnight hooks: $CLAUDE_SETTINGS_FILE is not valid JSON."
    return 1
  fi
  if ! mv "$tmp" "$CLAUDE_SETTINGS_FILE"; then
    rm -f "$tmp"
    print_error "Could not remove goodnight hooks: failed to update $CLAUDE_SETTINGS_FILE."
    return 1
  fi
  print_ok "Removed goodnight hooks from ${BOLD}$CLAUDE_SETTINGS_FILE${RESET}"
}

# Smart-watch loop.
#
# Sleeps the machine once every tracked agent has been quiet for
# SMART_IDLE_SECONDS. "Quiet" requires two independent signals to agree:
#
#   busy markers  == 0  (no session is mid-turn, per the Claude hooks)
#   transcript writes within the idle window == none
#
# Requiring both means a hook that silently stopped firing cannot cause
# a premature sleep — the transcript check still sees the work. It also
# means a marker left behind by a crashed or prompt-blocked session
# cannot wedge the loop forever: count_busy_sessions reaps any marker
# whose transcript has gone quiet past the stale window.
#
# Deliberate change from earlier behaviour: there is no longer a
# cold-start hold. The old loop refused to sleep until it had personally
# witnessed a busy marker appear, which meant the common case — every
# agent already finished before you type `goodnight` — waited forever
# and the machine never slept. Starting quiet is now a valid path to
# sleep, and the transcript check is what makes that safe.
#
# Returns:
#   0  idle reached
#   2  hard timeout reached (caller sleeps anyway)
smart_watch_loop() {
  local now busy recent_write activity_ts last_activity
  local cpu_now cpu_delta cpu_window cpu_busy
  local prev_cpu=-1 prev_cpu_ts=0 cpu_hits=0
  local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  local tick=0 poll
  local start_ts elapsed idle_for remaining
  local last_log=0 entry_sleep_stamp
  start_ts=$(date +%s)
  # Floor the clock at watch start: with no session logs at all there is
  # nothing to measure quiet from, and the watch should still be able to
  # conclude after one idle window rather than never.
  last_activity=$start_ts
  entry_sleep_stamp="$(sleep_stamp)"

  while true; do
    now=$(date +%s)
    elapsed=$((now - start_ts))

    # Did the Mac sleep while we were watching — lid closed, Apple menu,
    # another tool? Then the job is done and this process is simply the
    # last thing to notice.
    #
    # Without this the wall clock, which kept running through the
    # suspension, reads as elapsed watch time: close the lid at
    # midnight, open it at nine, and the timeout branch below fires
    # instantly and puts the machine straight back to sleep in your
    # hands. Exit instead, and say why.
    if [[ -n "$entry_sleep_stamp" ]]; then
      local now_sleep_stamp
      now_sleep_stamp="$(sleep_stamp)"
      if [[ -n "$now_sleep_stamp" && "$now_sleep_stamp" != "$entry_sleep_stamp" ]]; then
        clear_line
        print_ok "The Mac slept while goodnight was watching — nothing left to do."
        log_event "SLEPT_EXTERNALLY after=${elapsed}s"
        return 3
      fi
    fi

    # Hard cap. The previous loop had none: a single stuck marker meant
    # `goodnight` ran until morning and the Mac never slept. --timeout
    # now bounds every wait path in the program.
    if ((SMART_TIMEOUT_SECS > 0 && elapsed >= SMART_TIMEOUT_SECS)); then
      clear_line
      print_warn "Timeout of ${TIMEOUT_HOURS}h reached — proceeding to sleep anyway."
      log_event "SMART_TIMEOUT after=${elapsed}s busy=$(count_busy_sessions)"
      return 2
    fi

    busy="$(count_busy_sessions)"
    # Work from the timestamp of the last observed activity rather than
    # a boolean "was anything written recently".
    #
    # The boolean version stacked two full windows: it only stopped
    # reporting activity once a log had already been quiet for
    # SMART_IDLE_SECONDS, and the countdown then started from there — so
    # the machine slept roughly 2×--idle after the last write, not
    # --idle. Reading the mtime directly makes the wait mean what the
    # flag says.
    if [[ "$busy" != "0" ]]; then
      last_activity=$now
    else
      activity_ts="$(newest_agent_activity)"
      if [[ "$activity_ts" =~ ^[0-9]+$ ]] && ((activity_ts > last_activity)); then
        last_activity=$activity_ts
      fi
    fi
    # Third signal: an agent burning CPU is working even if it has
    # written nothing. Delta over the interval actually elapsed, so the
    # threshold means the same thing whichever poll rate is in force.
    cpu_busy=false
    if [[ "$CPU_GUARD" == true ]]; then
      cpu_now="$(agent_cpu_centiseconds)"
      if ((prev_cpu >= 0)) && [[ "$cpu_now" =~ ^[0-9]+$ ]]; then
        cpu_window=$((now - prev_cpu_ts))
        ((cpu_window < 1)) && cpu_window=1
        cpu_delta=$((cpu_now - prev_cpu))
        if ((cpu_delta > cpu_window * AGENT_CPU_BUSY_PCT)); then
          cpu_hits=$((cpu_hits + 1))
        else
          cpu_hits=0
        fi
        if ((cpu_hits >= AGENT_CPU_BUSY_SAMPLES)); then
          cpu_busy=true
          last_activity=$now
        fi
      fi
      [[ "$cpu_now" =~ ^[0-9]+$ ]] && prev_cpu=$cpu_now && prev_cpu_ts=$now
    fi

    idle_for=$((now - last_activity))
    ((idle_for < 0)) && idle_for=0
    # Only used for the non-TTY status line, to name which of the two
    # signals is holding things up.
    recent_write=false
    [[ "$busy" == "0" ]] && ((idle_for < SMART_IDLE_SECONDS)) && recent_write=true

    if [[ "$busy" == "0" ]]; then
      if ((idle_for >= SMART_IDLE_SECONDS)); then
        clear_line
        print_ok "All agents idle for $(elapsed_label "$idle_for") — proceeding to sleep."
        log_event "SMART_IDLE_REACHED waited=${elapsed}s idle_for=${idle_for}s"
        return 0
      fi
      remaining=$((SMART_IDLE_SECONDS - idle_for))
      if [[ "$USE_SPINNER" == true ]]; then
        printf "\r\033[K  %s%s%s  %sAll agents idle…%s  sleeping in %s" \
          "$GREEN" "${frames[$tick]}" "$RESET" \
          "$DIM" "$RESET" \
          "$(elapsed_label "$remaining")"
      elif ((now - last_log >= 60)); then
        last_log=$now
        echo "  … all agents idle, sleeping in $(elapsed_label "$remaining")"
      fi
      # Tighten the poll only for the last stretch of the countdown.
      # The interval is the race window — a session that resumes just
      # after a check is one we could sleep on top of — so it wants to
      # be small at the moment we are about to act, and no smaller than
      # it needs to be for the several minutes before that.
      if ((remaining <= 30)); then
        poll=1
      else
        poll=5
      fi
    else
      if [[ "$USE_SPINNER" == true ]]; then
        local why
        if [[ "$busy" != "0" ]]; then
          why="${busy} session(s) working"
        elif [[ "$cpu_busy" == true ]]; then
          why="an agent is busy on CPU"
        else
          why="agent output still being written"
        fi
        printf "\r\033[K  %s%s%s  %sWaiting — %s…%s  %s elapsed" \
          "$CYAN" "${frames[$tick]}" "$RESET" \
          "$DIM" "$why" "$RESET" \
          "$(elapsed_label "$elapsed")"
      elif ((now - last_log >= 300)); then
        last_log=$now
        echo "  … still waiting (busy=$busy recent_output=$recent_write cpu_busy=$cpu_busy, $(elapsed_label "$elapsed") elapsed)"
      fi
      # Nothing is imminent, so poll lazily. At 5s this is ~700 wakeups
      # over an eight-hour night instead of ~14,000.
      poll=5
    fi

    tick=$(((tick + 1) % ${#frames[@]}))
    micro_sleep "$poll"
  done
}

# ── Argument parsing ──────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout | -t)
      if [[ -z "${2:-}" ]] || ! is_positive_integer "$2"; then
        echo -e "${RED}✖  --timeout requires a positive integer ≥ 1 (hours)${RESET}" >&2
        exit 1
      fi
      TIMEOUT_HOURS="$2"
      shift 2
      ;;
    --pid | -p)
      if [[ -z "${2:-}" ]] || ! is_integer "$2"; then
        echo -e "${RED}✖  --pid requires a numeric process ID${RESET}" >&2
        exit 1
      fi
      TARGET_PID="$2"
      TARGET_PID_EXPLICIT=true
      # Naming a PID is an unambiguous request to watch that process,
      # so it selects PID mode outright. Without this the smart-mode
      # default would silently ignore the flag the user just passed.
      WATCH_PID_MODE=true
      shift 2
      ;;
    --delay | -d)
      if [[ -z "${2:-}" ]] || ! is_integer "$2"; then
        echo -e "${RED}✖  --delay requires a non-negative integer (seconds)${RESET}" >&2
        exit 1
      fi
      DELAY_SECS="$2"
      shift 2
      ;;
    --log-file)
      if [[ -z "${2:-}" ]]; then
        echo -e "${RED}✖  --log-file requires a path${RESET}" >&2
        exit 1
      fi
      LOG_FILE="$2"
      LOG_ENABLED=true
      shift 2
      ;;
    --no-sound)
      NO_SOUND=true
      shift
      ;;
    --caffeinate-only)
      CAFFEINATE_ONLY=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --list | -l)
      LIST_MODE=true
      shift
      ;;
    --notify | -n)
      NOTIFY=true
      shift
      ;;
    --log)
      LOG_ENABLED=true
      shift
      ;;
    --wait-for-start)
      # Waiting for a process to appear only means anything in the
      # process-watch flow, so it selects that mode explicitly rather
      # than being quietly dropped by the smart-mode default.
      WAIT_FOR_START=true
      WATCH_PID_MODE=true
      shift
      ;;
    --preflight | -P)
      PREFLIGHT_ONLY=true
      shift
      ;;
    --no-preflight)
      SKIP_PREFLIGHT=true
      shift
      ;;
    --force | --yes | -f | -y)
      FORCE=true
      shift
      ;;
    --brief | -b)
      BRIEF=true
      shift
      ;;
    --json)
      JSON_OUTPUT=true
      shift
      ;;
    --skip-update-check)
      SKIP_UPDATE_CHECK=true
      shift
      ;;
    --check-update)
      # Opt in to the update check for this run and bypass the 24h
      # rate-limit cache, then continue with the normal flow.
      SKIP_UPDATE_CHECK=false
      rm -f "$UPDATE_CACHE_DIR/last-update-check" 2>/dev/null || true
      shift
      ;;
    --no-auto-caffeinate)
      NO_AUTO_CAFFEINATE=true
      shift
      ;;
    --allow-battery)
      ALLOW_BATTERY=true
      shift
      ;;
    --log-summary)
      LOG_SUMMARY=true
      shift
      ;;
    --sleep-now)
      # Skip Claude detection and the watch loop entirely. Run
      # preflight, interactively handle blockers, ensure caffeinate
      # is released, then sleep immediately.
      SLEEP_NOW=true
      shift
      ;;
    --smart)
      # Hook-based idle detection: sleep when all Claude sessions have
      # fired their Stop hook (i.e., none are processing a message).
      # Requires --install-hooks to have been run once. This is the
      # default when hooks are installed — the flag is still accepted
      # for explicit invocation and scripts.
      SMART_WATCH=true
      shift
      ;;
    --watch-pid)
      # Legacy process-exit watching: watches kill -0 $pid and sleeps
      # when the claude process dies. Pre-hooks behavior. Use when you
      # actually want to run Claude non-interactively and wait for the
      # process to exit.
      WATCH_PID_MODE=true
      shift
      ;;
    --idle)
      if [[ -z "${2:-}" ]] || ! is_positive_integer "$2"; then
        echo -e "${RED}✖  --idle requires a positive integer (seconds)${RESET}" >&2
        exit 1
      fi
      SMART_IDLE_SECONDS="$2"
      shift 2
      ;;
    --stale)
      if [[ -z "${2:-}" ]] || ! is_positive_integer "$2"; then
        echo -e "${RED}✖  --stale requires a positive integer (minutes)${RESET}" >&2
        exit 1
      fi
      SMART_STALE_MARKER_MINS="$2"
      shift 2
      ;;
    --unattended)
      # Never prompt. Every question resolves to its safe default.
      UNATTENDED=true
      shift
      ;;
    --no-repair)
      NO_REPAIR=true
      shift
      ;;
    --no-cpu-guard)
      # Stop treating agent CPU burn as activity. Only reason to want
      # this is an agent process that idles hot enough to trip the
      # threshold and hold the watch open.
      CPU_GUARD=false
      shift
      ;;
    --no-log)
      LOG_ENABLED=false
      shift
      ;;
    --doctor)
      DOCTOR_MODE=true
      shift
      ;;
    --version | -V)
      echo "sleep-after-claude ${SAC_VERSION}"
      exit 0
      ;;
    --install-hooks)
      INSTALL_HOOKS=true
      shift
      ;;
    --uninstall-hooks)
      UNINSTALL_HOOKS=true
      shift
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    *)
      echo -e "${RED}✖  Unknown argument: $1${RESET}" >&2
      exit 1
      ;;
  esac
done

# ── Default mode selection ────────────────────────────────────
# If the user passed no explicit watch mode, pick one based on whether
# Claude Code hooks are installed:
#   - hooks installed → --smart (hook-based idle detection)
#   - hooks absent    → --watch-pid (legacy process-exit watching)
#                       with a one-line note pointing at --install-hooks
#
# --install-hooks / --uninstall-hooks / --preflight / --list /
# --log-summary / --sleep-now bypass this (they set their own paths
# and don't use either watch mode).
if [[ "$SMART_WATCH" != true && "$WATCH_PID_MODE" != true &&
  "$SLEEP_NOW" != true && "$PREFLIGHT_ONLY" != true &&
  "$LIST_MODE" != true && "$LOG_SUMMARY" != true &&
  "$INSTALL_HOOKS" != true && "$UNINSTALL_HOOKS" != true ]]; then
  # Smart mode is now the unconditional default.
  #
  # It used to fall back to PID-watching whenever hook detection failed,
  # which is how a single stripped JSON key turned `goodnight` into a
  # command that waited for an interactive Claude REPL to exit — that is
  # to say, until the 6h timeout, every night, silently. Smart mode
  # repairs its own hooks and degrades to transcript-activity detection
  # if it can't, so there is no failure it needs PID mode to cover.
  # PID mode remains available, but only when asked for by name.
  SMART_WATCH=true
fi

# ── Open persistent FIFO FD for fork-free micro_sleep ─────────
if [[ "$USE_BUILTIN_SLEEP" == true ]]; then
  if FIFO_DIR="$(mktemp -d -t sleep-after-claude.XXXXXX 2>/dev/null)"; then
    FIFO_PATH="$FIFO_DIR/fifo"
    if mkfifo "$FIFO_PATH" 2>/dev/null && exec 9<>"$FIFO_PATH"; then
      :
    else
      rm -rf "$FIFO_DIR" 2>/dev/null || true
      FIFO_DIR=""
      USE_BUILTIN_SLEEP=false
    fi
  else
    USE_BUILTIN_SLEEP=false
  fi
fi

# ── Cleanup ───────────────────────────────────────────────────
WATCH_STARTED=false
cleanup_fd_and_tmp() {
  [[ "$USE_BUILTIN_SLEEP" == true ]] && exec 9<&- 2>/dev/null || true
  [[ -n "$FIFO_DIR" && -d "$FIFO_DIR" ]] && rm -rf "$FIFO_DIR" 2>/dev/null || true
  # F-07: release the watch lock on any exit path.
  release_goodnight_lock
}

# F-07: Mutual-exclusion lock to prevent two concurrent `goodnight`
# invocations from racing on caffeinate release and double-pmset.
# macOS bash doesn't ship flock; `mkdir` is atomic across processes
# so we use the directory-as-lock pattern. Stale-lock detection: if
# the PID in the lock's marker file is no longer alive, the lock is
# reclaimed (prevents permanent deadlock after a crash).
GOODNIGHT_LOCK_DIR="${HOME}/.local/state/goodnight/lock"
GOODNIGHT_LOCK_ACQUIRED=false

acquire_goodnight_lock() {
  mkdir -p "$(dirname "$GOODNIGHT_LOCK_DIR")" 2>/dev/null || true
  # First attempt
  if mkdir "$GOODNIGHT_LOCK_DIR" 2>/dev/null; then
    echo "$$" >"$GOODNIGHT_LOCK_DIR/pid"
    GOODNIGHT_LOCK_ACQUIRED=true
    return 0
  fi
  # Lock taken — check liveness of the holder.
  local holder_pid
  holder_pid="$(cat "$GOODNIGHT_LOCK_DIR/pid" 2>/dev/null || echo "")"
  if [[ -n "$holder_pid" ]] && kill -0 "$holder_pid" 2>/dev/null; then
    print_error "Another goodnight is already running (PID $holder_pid)."
    print_step "Wait for it to finish, or cancel it first with: ${BOLD}kill $holder_pid${RESET}"
    return 1
  fi
  # Stale lock — steal it.
  print_warn "Stale lock at $GOODNIGHT_LOCK_DIR (holder PID $holder_pid dead) — reclaiming."
  rm -rf "$GOODNIGHT_LOCK_DIR" 2>/dev/null || true
  if mkdir "$GOODNIGHT_LOCK_DIR" 2>/dev/null; then
    echo "$$" >"$GOODNIGHT_LOCK_DIR/pid"
    GOODNIGHT_LOCK_ACQUIRED=true
    return 0
  fi
  print_error "Could not acquire goodnight lock."
  return 1
}

release_goodnight_lock() {
  if [[ "$GOODNIGHT_LOCK_ACQUIRED" == true ]] && [[ -d "$GOODNIGHT_LOCK_DIR" ]]; then
    rm -rf "$GOODNIGHT_LOCK_DIR" 2>/dev/null || true
    GOODNIGHT_LOCK_ACQUIRED=false
  fi
}

on_interrupt() {
  clear_line
  echo ""
  if [[ "$WATCH_STARTED" == true ]]; then
    # Smart mode watches markers and session logs, not a PID, so the old
    # wording logged "PID unknown" for what is now the default mode, and
    # named Claude alone when the watch covers several agents.
    if [[ "$SMART_WATCH" == true ]]; then
      print_warn "Cancelled — machine will ${BOLD}not${RESET} sleep. Agents left running."
      log_event "CANCELLED mode=smart busy=$(count_busy_sessions)"
    else
      print_warn "Cancelled — machine will ${BOLD}not${RESET} sleep. PID ${TARGET_PID:-unknown} still running."
      log_event "CANCELLED mode=watch-pid pid=${TARGET_PID:-unknown}"
    fi
  else
    print_warn "Cancelled."
  fi
  # F-12: Don't call cleanup_fd_and_tmp directly here — the EXIT
  # trap will run it on exit. Calling it both here AND via the EXIT
  # trap is idempotent today but fragile if future cleanup steps
  # aren't.
  echo ""
  exit 0
}
trap on_interrupt INT TERM HUP
trap cleanup_fd_and_tmp EXIT

# ── --install-hooks / --uninstall-hooks fast paths ───────────
# These are pure config-file operations — no preflight, no watch.
if [[ "$INSTALL_HOOKS" == true ]]; then
  print_header
  install_claude_hooks
  exit $?
fi
if [[ "$UNINSTALL_HOOKS" == true ]]; then
  print_header
  uninstall_claude_hooks
  exit $?
fi

# ── --doctor mode ─────────────────────────────────────────────
# One command that answers "is this thing actually going to work
# tonight?" without reading any source. The failure that prompted it
# was invisible from the outside: the hooks looked installed, markers
# were still being written, and the command still appeared to run —
# it had just silently stopped using any of that. Anything the watch
# depends on is therefore reported here as observed state, not as a
# claim. Exits non-zero when the integration is degraded so it can be
# used as a health check.
if [[ "$DOCTOR_MODE" == true ]]; then
  print_header
  doctor_rc=0
  ui_kv "Version" "$SAC_VERSION"
  ui_kv "Binary" "${BASH_SOURCE[0]:-$0}"

  ui_section "Hook integration" "Claude Code settings: $CLAUDE_SETTINGS_FILE"
  dr_health="$(hooks_health)"
  case "$dr_health" in
    ok)
      print_ok "Hooks healthy — UserPromptSubmit, Stop and SessionEnd all present."
      ;;
    partial)
      print_error "Hooks PARTIAL — UserPromptSubmit, Stop and SessionEnd are not all installed."
      print_step "Repair with: ${BOLD}goodnight --install-hooks${RESET}"
      doctor_rc=1
      ;;
    missing)
      print_error "Hooks MISSING — no goodnight entries in settings.json."
      print_step "Install with: ${BOLD}goodnight --install-hooks${RESET}"
      doctor_rc=1
      ;;
    nojq)
      print_error "jq not found on PATH — hook bodies cannot run."
      print_step "Install with: ${BOLD}brew install jq${RESET}"
      doctor_rc=1
      ;;
    nofile)
      print_error "No settings file at $CLAUDE_SETTINGS_FILE."
      doctor_rc=1
      ;;
    badjson)
      print_error "settings.json is not valid JSON — hooks cannot be read."
      doctor_rc=1
      ;;
  esac
  if [[ "$dr_health" != "nojq" ]] && hooks_need_retag; then
    print_warn "Hook entries have lost their ._managed_by tag."
    print_step "They still fire (matched by command sentinel), but reinstall would duplicate them."
    print_step "Fix with: ${BOLD}goodnight --install-hooks${RESET}"
  fi
  if command -v jq >/dev/null 2>&1 && [[ -f "$CLAUDE_SETTINGS_FILE" ]]; then
    for dr_evt in UserPromptSubmit Stop SessionEnd; do
      dr_n="$(jq -r "${HOOK_MATCH_JQ}"' [ (.hooks."'"$dr_evt"'" // [])[] | select(gn_functional) ] | length' \
        "$CLAUDE_SETTINGS_FILE" 2>/dev/null || echo "?")"
      ui_kv "$dr_evt" "${dr_n} goodnight entr$([[ "$dr_n" == "1" ]] && echo y || echo ies)"
    done
  fi

  ui_section "Session markers" "$BUSY_DIR"
  dr_before=0
  if [[ -d "$BUSY_DIR" ]]; then
    for dr_f in "$BUSY_DIR"/*; do [[ -f "$dr_f" ]] && dr_before=$((dr_before + 1)); done
  fi
  dr_reaped="$(reap_dead_markers)"
  dr_live="$(count_busy_sessions)"
  ui_kv "Markers found" "$dr_before"
  ui_kv "Stale (reaped)" "$dr_reaped"
  ui_kv "Live / working" "$dr_live"

  ui_section "Agent activity" "Session logs watched for signs of work in progress"
  dr_any_root=false
  for dr_dir in "${AGENT_ACTIVITY_DIRS[@]}"; do
    if [[ -d "$dr_dir" ]]; then
      dr_any_root=true
      ui_kv "Watching" "$dr_dir"
    else
      ui_kv "Absent" "$dr_dir"
    fi
  done
  if [[ "$dr_any_root" != true ]]; then
    print_warn "No agent session directories found — activity fallback unavailable."
  else
    dr_mt="$(newest_agent_activity)"
    if [[ -n "$dr_mt" ]]; then
      dr_age=$(($(date +%s) - dr_mt))
      ui_kv "Last agent output" "$(elapsed_label "$dr_age") ago"
    else
      ui_kv "Last agent output" "none recorded"
    fi
    if transcript_active_within "$SMART_IDLE_SECONDS"; then
      print_warn "Agent output written within the last $(elapsed_label "$SMART_IDLE_SECONDS") — a watch would still be waiting."
    else
      print_ok "No agent output in the last $(elapsed_label "$SMART_IDLE_SECONDS")."
    fi
    # The watch stats every one of these on each idle tick and nothing
    # prunes them, so the cost grows quietly for as long as the machine
    # is used. Surfacing the count keeps that visible rather than
    # letting it creep.
    dr_logs=0
    for dr_dir in "${AGENT_ACTIVITY_DIRS[@]}"; do
      [[ -d "$dr_dir" ]] || continue
      dr_logs=$((dr_logs + $(find "$dr_dir" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')))
    done
    ui_kv "Session logs" "${dr_logs} scanned per idle tick"
  fi
  dr_cpu="$(agent_cpu_centiseconds)"
  if [[ "$dr_cpu" =~ ^[0-9]+$ ]]; then
    ui_kv "Agent CPU guard" "$([[ "$CPU_GUARD" == true ]] && echo "on, busy above ${AGENT_CPU_BUSY_PCT}% of one core" || echo "off")"
    ui_kv "Agent processes" "${AGENT_PROCESS_NAMES[*]}"
  fi

  ui_section "Watch configuration"
  ui_kv "Mode" "$(hooks_installed && echo "smart (markers + transcripts)" || echo "smart (transcripts only — degraded)")"
  ui_kv "Idle threshold" "$(elapsed_label "$SMART_IDLE_SECONDS")"
  ui_kv "Stale window" "${SMART_STALE_MARKER_MINS}m"
  ui_kv "Hard timeout" "${TIMEOUT_HOURS}h"
  ui_kv "Log" "$([[ "$LOG_ENABLED" == true ]] && echo "$LOG_FILE" || echo "disabled")"

  ui_section "Sleep readiness"
  scan_assertions
  if [[ "$PREFLIGHT_SCAN_OK" != true ]]; then
    print_warn "pmset assertion scan unavailable — sleep readiness unknown."
  elif [[ ${#PREFLIGHT_BLOCKERS[@]} -eq 0 ]]; then
    print_ok "No sleep blockers."
  else
    print_warn "${#PREFLIGHT_BLOCKERS[@]} sleep blocker(s):"
    for dr_entry in "${PREFLIGHT_BLOCKERS[@]}"; do
      IFS='|' read -r dr_pid dr_name dr_type <<<"$dr_entry"
      echo -e "    • ${BOLD}${dr_name}${RESET} (PID $dr_pid) — ${dr_type}"
    done
    print_step "Sleep is verified and retried ${SLEEP_MAX_ATTEMPTS}×, so these are survivable — but they will delay it."
  fi
  ui_kv "Power" "$(get_power_source)"

  ui_section "Verdict"
  if ((doctor_rc == 0)); then
    if [[ "$dr_live" == "0" ]] && ! transcript_active_within "$SMART_IDLE_SECONDS"; then
      ui_panel success "Healthy — would sleep" \
        "Every agent is idle. Running goodnight now would sleep the Mac" \
        "after $(elapsed_label "$SMART_IDLE_SECONDS") of continued quiet."
    else
      ui_panel info "Healthy — would wait" \
        "${dr_live} session(s) still working." \
        "Running goodnight now would wait for them, then sleep."
    fi
  else
    ui_panel danger "Degraded" \
      "goodnight would fall back to transcript-only detection." \
      "It would still work, but less precisely. Fix the errors above."
  fi
  echo ""
  exit "$doctor_rc"
fi

# ── --list mode ───────────────────────────────────────────────
if [[ "$LIST_MODE" == true ]]; then
  print_header
  list_matches="$(find_claude_processes)"
  list_all="$(find_all_claude_processes_raw)"
  list_target_pids=""
  [[ -n "$list_matches" ]] && list_target_pids="$(echo "$list_matches" | awk '{print $1}' | sort -u)"

  list_excluded=""
  if [[ -n "$list_all" ]]; then
    while IFS= read -r line; do
      pid="$(echo "$line" | awk '{print $1}')"
      if ! echo "$list_target_pids" | grep -qx "$pid"; then
        list_excluded+="${line}"$'\n'
      fi
    done <<<"$list_all"
    list_excluded="${list_excluded%$'\n'}"
  fi

  if [[ -z "$list_matches" ]]; then
    print_warn "No target Claude processes detected."
  else
    print_step "Target Claude process(es):"
    echo ""
    echo "$list_matches" | while IFS= read -r line; do
      echo -e "    ${GREEN}✔${RESET} ${line}"
    done
  fi
  if [[ -n "$list_excluded" ]]; then
    echo ""
    print_step "Excluded (not watched):"
    echo ""
    echo "$list_excluded" | while IFS= read -r line; do
      epid="$(echo "$line" | awk '{print $1}')"
      ecmd="$(echo "$line" | awk '{$1=""; sub(/^ /,""); print}' | cut -c1-65)"
      echo -e "    ${YELLOW}⊘${RESET} ${DIM}PID $epid  ${ecmd}${RESET}"
    done
  fi
  if [[ -n "$list_matches" ]]; then
    echo ""
    print_step "Use ${BOLD}--pid <pid>${RESET} to watch a specific one."
  fi
  echo ""
  exit 0
fi

# ── --preflight mode ──────────────────────────────────────────
if [[ "$PREFLIGHT_ONLY" == true ]]; then
  preflight_scan
  if [[ "$JSON_OUTPUT" == true ]]; then
    render_preflight_json
  else
    [[ "$BRIEF" == false ]] && print_header
    render_preflight
  fi
  exit 0
fi

# ── --log-summary mode ────────────────────────────────────────
# Renders the session log as pretty markdown via `glow` when it's
# installed; falls back to plain `tail` otherwise. Groups events by
# PREFLIGHT_* / WATCH_* / CLAUDE_* / SLEEP_* so the reader can skim
# an unattended night's activity at a glance.
if [[ "$LOG_SUMMARY" == true ]]; then
  if [[ ! -f "$LOG_FILE" ]]; then
    print_warn "No log file at $LOG_FILE — run with --log first."
    exit 0
  fi
  {
    echo "# sleep-after-claude session log"
    echo ""
    echo "**File:** \`$LOG_FILE\`"
    echo "**Total events:** $(wc -l <"$LOG_FILE" | tr -d ' ')"
    echo ""
    echo "## Recent events (last 50)"
    echo ""
    echo '```'
    tail -50 "$LOG_FILE"
    echo '```'
    echo ""
    echo "## Counts by category"
    echo ""
    echo "| Category | Count |"
    echo "|---|---|"
    # Derived from the log itself rather than a hand-kept list.
    # A parallel vocabulary drifts the moment an event is added or
    # renamed, and it had: every event the current code emits was
    # reporting zero. Counting what is actually there cannot drift.
    awk '{
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[A-Z][A-Z0-9_]{3,}$/) { print $i; break }
      }
    }' "$LOG_FILE" | sort | uniq -c | sort -rn |
      while read -r count event; do
        echo "| $event | $count |"
      done
  } | {
    ui_markdown
  }
  exit 0
fi

# ── Power-state gate ──────────────────────────────────────────
# Must be the FIRST check on the actionable path — we don't want to
# burn battery downloading updates or waiting for Claude when the
# machine is unplugged. Desktop Macs (no battery) pass through.
print_header
if [[ -n "$SAC_CONFIG_WARNINGS" ]]; then
  while IFS= read -r _cfg_warn; do
    [[ -n "$_cfg_warn" ]] && print_warn "$_cfg_warn"
  done <<<"$SAC_CONFIG_WARNINGS"
fi
wait_for_ac_power

# ── Self-update check ─────────────────────────────────────────
# Runs on the actionable path (default watch-and-sleep, --dry-run,
# --caffeinate-only, --wait-for-start). Skipped for pure introspection
# modes (--help/--list/--preflight) which returned above. Rate-limited
# to once per 24h via ~/.cache/sleep-after-claude/last-update-check.
check_for_update

# ── --sleep-now fast path ─────────────────────────────────────
# Skips Claude detection and the watch loop entirely. Runs preflight,
# interactively handles blockers, releases/auto-starts caffeinate as
# usual, then sleeps immediately. For when the user knows they want
# to sleep now regardless of any running Claude sessions (e.g.,
# idle Claude REPLs left open from earlier).
if [[ "$SLEEP_NOW" == true ]]; then
  if [[ "$SKIP_PREFLIGHT" == false ]]; then
    preflight_scan
    if [[ "$JSON_OUTPUT" == true ]]; then
      render_preflight_json
    else
      render_preflight
    fi
    if [[ "$PREFLIGHT_SCAN_OK" != true ]]; then
      log_event "PREFLIGHT_SCAN_FAILED (sleep-now)"
      if [[ "$FORCE" == false && "$UNATTENDED" == false ]]; then
        if [[ "$STDIN_IS_TTY" == true ]]; then
          if ! ui_confirm "Sleep-blocker scan failed. Proceed anyway?"; then
            print_warn "Aborted by user."
            echo ""
            exit 0
          fi
          echo ""
        else
          print_error "Sleep-blocker scan failed and stdin is not a TTY for confirmation."
          exit 1
        fi
      fi
    elif [[ ${#PREFLIGHT_BLOCKERS[@]} -gt 0 ]]; then
      log_event "PREFLIGHT_BLOCKERS count=${#PREFLIGHT_BLOCKERS[@]} (sleep-now)"
      if ! prompt_and_handle_blockers; then
        echo ""
        exit 0
      fi
      echo ""
    fi
  fi
  if [[ "$DRY_RUN" == true ]]; then
    echo ""
    print_done "Dry run complete — ${BOLD}not sleeping${RESET} the Mac."
    play_sound
    log_event "DRY_RUN_EXIT (sleep-now)"
    exit 0
  fi
  # Release any caffeinate processes already running so macOS is free
  # to sleep. Don't auto-start a new one — we're sleeping immediately.
  # shellcheck disable=SC2207
  SLEEP_NOW_CAFF_PIDS=($(pgrep caffeinate 2>/dev/null || true))
  if [[ ${#SLEEP_NOW_CAFF_PIDS[@]} -gt 0 ]]; then
    print_step "Releasing caffeinate (${SLEEP_NOW_CAFF_PIDS[*]})..."
    kill "${SLEEP_NOW_CAFF_PIDS[@]}" 2>/dev/null || true
  fi
  echo ""
  print_step "Sleeping Mac in ${BOLD}${DELAY_SECS}s${RESET}..."
  play_sound
  sleep "$DELAY_SECS"
  echo ""
  ui_panel success "Good night" "Requesting macOS sleep now."
  echo ""
  if attempt_sleep "sleep-now"; then
    exit 0
  fi
  print_error "The Mac did not sleep after ${SLEEP_MAX_ATTEMPTS} attempts."
  print_warn "Something is holding a PreventSystemSleep assertion. Inspect with:"
  print_step "${BOLD}pmset -g assertions${RESET}"
  log_event "SLEEP_FAILED (sleep-now) attempts=${SLEEP_MAX_ATTEMPTS}"
  notify_macos "goodnight could not sleep the Mac — see log"
  exit 1
fi

# ── --smart mode: hook-based idle detection ──────────────────
# When enabled, goodnight watches the busy directory populated by the
# Claude Code hooks installed via --install-hooks. No PID watching,
# no process-exit waiting — sleep happens as soon as all sessions
# have fired their Stop hook.
if [[ "$SMART_WATCH" == true ]]; then
  SMART_HOOK_STATE="$(hooks_health)"

  # Self-heal before giving up. A degraded integration is the expected
  # steady state, not an exceptional one: settings.json is co-owned by
  # Claude Code and by whatever else the user has wired into it, and our
  # entries get rewritten by things that have no idea we exist.
  if [[ "$SMART_HOOK_STATE" != "ok" && "$NO_REPAIR" == false ]]; then
    print_warn "Claude Code hook integration degraded (${SMART_HOOK_STATE}) — repairing."
    log_event "HOOKS_DEGRADED state=$SMART_HOOK_STATE"
    if repair_claude_hooks; then
      SMART_HOOK_STATE="$(hooks_health)"
      print_ok "Hook integration repaired (${SMART_HOOK_STATE})."
    else
      SMART_HOOK_STATE="$(hooks_health)"
    fi
  elif [[ "$SMART_HOOK_STATE" == "ok" && "$NO_REPAIR" == false ]] && hooks_need_retag; then
    # Functional but untagged: works today, becomes a duplicate-hook
    # trap the next time anything reinstalls. Fix it quietly.
    repair_claude_hooks >/dev/null 2>&1 || true
  fi

  # Hooks repaired in this process only take effect for Claude sessions
  # started afterwards — a session already running has its hook config
  # loaded. Say so plainly rather than implying full coverage.
  if [[ "$SMART_HOOK_STATE" == "ok" ]]; then
    :
  else
    ui_panel warning "Running without Claude hook markers" \
      "Hook state: ${SMART_HOOK_STATE}." \
      "" \
      "Falling back to transcript-activity detection, which watches" \
      "agent output directly and needs no hooks. It is slower to notice" \
      "a finished turn but cannot miss one that is still running." \
      "" \
      "Sleep will follow $(elapsed_label "$SMART_IDLE_SECONDS") with no agent output."
    log_event "SMART_FALLBACK_TRANSCRIPT_ONLY state=$SMART_HOOK_STATE"
  fi

  mkdir -p "$BUSY_DIR" 2>/dev/null || true
  # Clear orphaned markers up front so the very first tick reports a
  # truthful count instead of inheriting months of dead sessions.
  SMART_REAPED="$(reap_dead_markers)"
  if [[ "$SMART_REAPED" != "0" ]]; then
    print_step "Cleared ${BOLD}${SMART_REAPED}${RESET} stale session marker(s)."
    log_event "MARKERS_REAPED count=$SMART_REAPED"
  fi
  # Run preflight + blocker handling first (same as default flow).
  if [[ "$SKIP_PREFLIGHT" == false ]]; then
    preflight_scan
    if [[ "$JSON_OUTPUT" == true ]]; then
      render_preflight_json
    else
      render_preflight
    fi
    if [[ "$PREFLIGHT_SCAN_OK" != true ]]; then
      log_event "PREFLIGHT_SCAN_FAILED (smart)"
      if [[ "$FORCE" == false && "$UNATTENDED" == false ]]; then
        if ! ui_confirm "Sleep-blocker scan failed. Proceed anyway?"; then
          print_warn "Aborted."
          exit 0
        fi
      fi
    elif [[ ${#PREFLIGHT_BLOCKERS[@]} -gt 0 ]]; then
      log_event "PREFLIGHT_BLOCKERS count=${#PREFLIGHT_BLOCKERS[@]} (smart)"
      if ! prompt_and_handle_blockers; then
        exit 0
      fi
    fi
  fi
  if [[ "$DRY_RUN" == true ]]; then
    INITIAL_CAFF_PIDS=()
  else
    ensure_caffeinate_running
    # shellcheck disable=SC2207
    INITIAL_CAFF_PIDS=($(pgrep caffeinate 2>/dev/null || true))
  fi

  SMART_TIMEOUT_SECS=$((TIMEOUT_HOURS * 3600))

  ui_section "Smart watch" "Waiting until every agent has finished, paused, or gone quiet."
  print_step "Idle threshold: ${BOLD}$(elapsed_label "$SMART_IDLE_SECONDS")${RESET} with no session busy and no agent output"
  print_step "Stale window:   ${BOLD}${SMART_STALE_MARKER_MINS}m${RESET} before a silent session stops counting"
  print_step "Hard timeout:   ${BOLD}${TIMEOUT_HOURS}h${RESET}"
  print_step "Busy markers:   ${BOLD}$BUSY_DIR${RESET}"
  print_step "Agent logs:     ${BOLD}${AGENT_ACTIVITY_DIRS[*]}${RESET}"
  [[ "$LOG_ENABLED" == true ]] && print_step "Log:            ${BOLD}${LOG_FILE}${RESET}"
  print_step "Press ${BOLD}Ctrl+C${RESET} to cancel"
  echo ""

  # F-07: Acquire the watch lock to prevent concurrent goodnight
  # instances from racing on caffeinate release and pmset sleepnow.
  if ! acquire_goodnight_lock; then
    exit 1
  fi
  log_event "SMART_WATCH_START version=$SAC_VERSION busy_count=$(count_busy_sessions) hooks=$SMART_HOOK_STATE idle=${SMART_IDLE_SECONDS}s stale=${SMART_STALE_MARKER_MINS}m timeout=${TIMEOUT_HOURS}h"
  WATCH_STARTED=true
  smart_watch_loop
  SMART_WATCH_RC=$?
  WATCH_STARTED=false
  clear_line
  if ((SMART_WATCH_RC == 3)); then
    # The Mac already slept by other means. Releasing caffeinate and
    # issuing another sleep here would put it straight back down in
    # the user's hands, seconds after they woke it.
    log_event "SMART_WATCH_EXIT_ALREADY_SLEPT"
    notify_macos "Mac already slept — goodnight stood down"
    print_done "Nothing to do — the Mac slept on its own."
    exit 0
  elif ((SMART_WATCH_RC == 2)); then
    log_event "SMART_WATCH_TIMEOUT — proceeding to sleep"
    notify_macos "goodnight timeout reached — sleeping"
  else
    log_event "SMART_WATCH_IDLE — proceeding to sleep"
    notify_macos "All agents idle — sleeping"
  fi

  # Reuse the existing release-caffeinate + sleep sequence from the
  # default watch flow. Jump there by falling through — set
  # TARGET_PID to a sentinel so the "Detect Claude PID" block below
  # skips its lookups.
  TARGET_PID="smart"
  TARGET_CMD="smart-watch"
  TARGET_CMD_FULL="smart-watch"
  TARGET_BIN="smart-watch"
  SMART_WATCH_DONE=true
fi

# ── Detect Claude PID ─────────────────────────────────────────

if [[ "${SMART_WATCH_DONE:-false}" != true ]]; then
  if [[ -z "$TARGET_PID" ]]; then
    MATCHES="$(find_claude_processes)"

    if [[ -z "$MATCHES" && "$WAIT_FOR_START" == true ]]; then
      print_step "Waiting for Claude to start..."
      while [[ -z "$MATCHES" ]]; do
        sleep 2
        MATCHES="$(find_claude_processes)"
      done
      print_ok "Claude detected."
    fi

    if [[ -z "$MATCHES" ]]; then
      print_error "No Claude process found. Is Claude Code running?"
      print_step "Run ${BOLD}sleep-after-claude --list${RESET} to check what's detectable."
      print_step "Or use ${BOLD}--wait-for-start${RESET} to wait for Claude to launch."
      exit 1
    fi

    MATCH_COUNT="$(echo "$MATCHES" | wc -l | tr -d ' ')"
    TARGET_PID="$(echo "$MATCHES" | awk 'NR==1{print $1}')"
    TARGET_CMD="$(echo "$MATCHES" | awk 'NR==1{$1=""; sub(/^ /, ""); print}' | cut -c1-55)"

    if [[ "$MATCH_COUNT" -gt 1 ]]; then
      print_warn "Multiple Claude processes found — watching the first one:"
      echo ""
      echo "$MATCHES" | while IFS= read -r line; do
        echo -e "    ${DIM}$line${RESET}"
      done
      echo ""
      print_step "Use ${BOLD}--pid <pid>${RESET} to watch a specific one."
      echo ""
    fi

    print_ok "Watching: ${BOLD}PID $TARGET_PID${RESET} ${DIM}→ $TARGET_CMD${RESET}"

  else
    if ! kill -0 "$TARGET_PID" 2>/dev/null; then
      print_error "PID $TARGET_PID not found or already exited."
      exit 1
    fi
    TARGET_CMD="$(ps -p "$TARGET_PID" -o command= 2>/dev/null | cut -c1-55 || echo "unknown")"
    print_ok "Watching: ${BOLD}PID $TARGET_PID${RESET} ${DIM}→ $TARGET_CMD${RESET}"
  fi

  TARGET_CMD_FULL="$(ps -p "$TARGET_PID" -o command= 2>/dev/null || echo "")"
  # Extract just the binary path (first whitespace-separated token). argv
  # can legitimately mutate at runtime via setproctitle/exec -a/etc., so
  # we compare only the binary for PID-reuse detection — a full-string
  # compare would false-positive on a legitimate argv change and sleep
  # the Mac mid-task.
  TARGET_BIN="$(echo "$TARGET_CMD_FULL" | awk '{print $1}')"

  # ── Pre-flight scan + verdict + optional confirmation ─────────
  if [[ "$SKIP_PREFLIGHT" == false ]]; then
    preflight_scan
    if [[ "$JSON_OUTPUT" == true ]]; then
      render_preflight_json
    else
      render_preflight
    fi

    if [[ "$PREFLIGHT_SCAN_OK" != true ]]; then
      log_event "PREFLIGHT_SCAN_FAILED"
      if [[ "$FORCE" == false && "$UNATTENDED" == false ]]; then
        if [[ "$STDIN_IS_TTY" == true ]]; then
          if ! ui_confirm "Sleep-blocker scan failed. Proceed anyway?"; then
            print_warn "Aborted by user. Claude is still running; caffeinate untouched."
            echo ""
            exit 0
          fi
          echo ""
        else
          print_error "Sleep-blocker scan failed and stdin is not a TTY for confirmation."
          print_step "Pass ${BOLD}--force${RESET} to proceed anyway, or ${BOLD}--no-preflight${RESET} to skip the scan."
          exit 1
        fi
      else
        print_warn "Sleep-blocker scan failed but --force was given — proceeding."
        echo ""
      fi
    elif [[ ${#PREFLIGHT_BLOCKERS[@]} -gt 0 ]]; then
      log_event "PREFLIGHT_BLOCKERS count=${#PREFLIGHT_BLOCKERS[@]}"
      # Interactive blocker-handling menu: terminate (user apps only),
      # skip, or abort. --force short-circuits to "skip with warning".
      if ! prompt_and_handle_blockers; then
        echo ""
        exit 0
      fi
      echo ""
    fi
  fi

  # ── Ensure caffeinate is running ──────────────────────────────
  # If no caffeinate is active we start one now so the Mac doesn't
  # drift to sleep while we're watching. Skippable with
  # --no-auto-caffeinate for users who manage caffeinate themselves.
  if [[ "$DRY_RUN" == true ]]; then
    INITIAL_CAFF_PIDS=()
  else
    ensure_caffeinate_running

    # ── Capture caffeinate PIDs at start ──────────────────────────
    # Captured AFTER ensure_caffeinate_running so any auto-started
    # caffeinate is included and will be released at the end of watch.
    # shellcheck disable=SC2207
    INITIAL_CAFF_PIDS=($(pgrep caffeinate 2>/dev/null || true))
  fi

  TIMEOUT_SECS=$((TIMEOUT_HOURS * 3600))

  ui_section "Starting watch" "goodnight will wait quietly, then release caffeinate and sleep."
  print_step "Timeout:  ${BOLD}${TIMEOUT_HOURS}h${RESET}"
  print_step "Delay:    ${BOLD}${DELAY_SECS}s${RESET} before sleep"
  if [[ ${#INITIAL_CAFF_PIDS[@]} -gt 0 ]]; then
    print_step "Caffeinate PIDs captured: ${BOLD}${INITIAL_CAFF_PIDS[*]}${RESET}"
  else
    print_warn "No caffeinate processes currently running"
  fi
  [[ "$CAFFEINATE_ONLY" == true ]] && print_step "Mode:     ${BOLD}caffeinate-only${RESET} (will not sleep the Mac)"
  [[ "$DRY_RUN" == true ]] && print_step "Mode:     ${BOLD}dry-run${RESET} (will not sleep the Mac)"
  [[ "$NO_SOUND" == true ]] && print_step "Sound:    ${BOLD}off${RESET}"
  [[ "$NOTIFY" == true ]] && print_step "Notify:   ${BOLD}on${RESET}"
  [[ "$LOG_ENABLED" == true ]] && print_step "Log:      ${BOLD}${LOG_FILE}${RESET}"
  [[ "$USE_SPINNER" == false ]] && print_step "TTY:      ${BOLD}non-interactive${RESET} (spinner disabled)"
  print_step "Press ${BOLD}Ctrl+C${RESET} to cancel"
  if [[ "${SMART_WATCH_DONE:-false}" != true ]] && ! hooks_installed; then
    echo -e "  ${DIM}Tip: Claude Code hooks aren't installed — this watch waits for the${RESET}"
    echo -e "  ${DIM}process to exit, which an interactive Claude REPL won't do. Run${RESET}"
    echo -e "  ${DIM}${BOLD}goodnight --install-hooks${RESET}${DIM} once to enable idle-aware detection.${RESET}"
  fi
  echo ""

  # F-07: Acquire the watch lock (if smart-mode didn't already — it's
  # idempotent). Prevents concurrent invocations racing on caffeinate
  # and pmset.
  if [[ "${SMART_WATCH_DONE:-false}" != true ]]; then
    if ! acquire_goodnight_lock; then
      exit 1
    fi
  fi
  log_event "WATCH_START pid=$TARGET_PID cmd=\"$TARGET_CMD\""

  # ── Wait loop ─────────────────────────────────────────────────
  WATCH_STARTED=true
  START_TIME=$(date +%s)
  # Same suspension guard as smart mode. This path measures its deadline
  # against the wall clock too, so without it a lid closed mid-watch
  # reads as elapsed watch time and the timeout fires on wake.
  PID_ENTRY_SLEEP_STAMP="$(sleep_stamp)"
  FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  TICK=0
  TICK_COUNT=0
  ELAPSED=0
  LAST_STATUS_LOG=0
  TIMED_OUT=false
  PID_REUSED=false

  # Skip the kill -0 loop entirely when smart mode already handled the
  # wait — we only need to fall through to the release+sleep sequence.
  while [[ "${SMART_WATCH_DONE:-false}" != true ]] && kill -0 "$TARGET_PID" 2>/dev/null; do
    if ((TICK_COUNT % 10 == 0)); then
      NOW=$(date +%s)
      ELAPSED=$((NOW - START_TIME))
    fi

    if [[ -n "$TARGET_BIN" ]] && ((TICK_COUNT % 300 == 0)) && ((TICK_COUNT > 0)); then
      CURRENT_CMD="$(ps -p "$TARGET_PID" -o command= 2>/dev/null || echo "")"
      CURRENT_BIN="$(echo "$CURRENT_CMD" | awk '{print $1}')"
      if [[ -n "$CURRENT_BIN" && "$CURRENT_BIN" != "$TARGET_BIN" ]]; then
        clear_line
        print_warn "PID $TARGET_PID was reused by another process — treating as finished."
        log_event "PID_REUSED pid=$TARGET_PID was=\"$TARGET_CMD_FULL\" now=\"$CURRENT_CMD\""
        PID_REUSED=true
        break
      fi
    fi

    # Checked on the same cadence as ELAPSED and *before* the timeout
    # branch below. On a rarer cadence the two could cross: wake from a
    # suspension that outlasted --timeout on a tick that skips this
    # check, and the timeout fires first — putting the Mac back to
    # sleep in the user's hands, which is the exact failure this guard
    # exists to prevent.
    if [[ -n "$PID_ENTRY_SLEEP_STAMP" ]] && ((TICK_COUNT % 10 == 0)); then
      NOW_SLEEP_STAMP="$(sleep_stamp)"
      if [[ -n "$NOW_SLEEP_STAMP" && "$NOW_SLEEP_STAMP" != "$PID_ENTRY_SLEEP_STAMP" ]]; then
        clear_line
        print_ok "The Mac slept while goodnight was watching — nothing left to do."
        log_event "SLEPT_EXTERNALLY (watch-pid) after=${ELAPSED}s"
        notify_macos "Mac already slept — goodnight stood down"
        print_done "Nothing to do — the Mac slept on its own."
        exit 0
      fi
    fi

    if [[ $ELAPSED -ge $TIMEOUT_SECS ]]; then
      clear_line
      print_warn "Timeout of ${TIMEOUT_HOURS}h reached — forcing sleep anyway."
      TIMED_OUT=true
      break
    fi

    if [[ "$USE_SPINNER" == true ]]; then
      # Static format; all dynamics go through %s so stray `%` can't
      # corrupt the format string (same safety pattern as wait_for_ac_power).
      printf "\r\033[K  %s%s%s  %sWaiting for PID %s…%s  %s elapsed" \
        "$CYAN" "${FRAMES[$TICK]}" "$RESET" \
        "$DIM" "$TARGET_PID" "$RESET" \
        "$(elapsed_label "$ELAPSED")"
    else
      if ((ELAPSED - LAST_STATUS_LOG >= 300)); then
        echo "  … still waiting for PID $TARGET_PID ($(elapsed_label $ELAPSED) elapsed)"
        LAST_STATUS_LOG=$ELAPSED
      fi
    fi

    TICK=$(((TICK + 1) % ${#FRAMES[@]}))
    TICK_COUNT=$((TICK_COUNT + 1))
    micro_sleep 0.1
  done

  clear_line
  WATCH_STARTED=false

  if [[ "$TIMED_OUT" == false && "$PID_REUSED" == false ]]; then
    TOTAL_ELAPSED=$(($(date +%s) - START_TIME))
    print_ok "Process ${BOLD}PID $TARGET_PID${RESET} finished after $(elapsed_label $TOTAL_ELAPSED)"
    log_event "CLAUDE_FINISHED pid=$TARGET_PID elapsed=${TOTAL_ELAPSED}s"
    notify_macos "Claude finished after $(elapsed_label $TOTAL_ELAPSED)"
  elif [[ "$TIMED_OUT" == true ]]; then
    log_event "TIMEOUT pid=$TARGET_PID after ${TIMEOUT_HOURS}h"
    notify_macos "Claude timeout reached — forcing sleep"
  else
    notify_macos "Claude PID reused — proceeding with sleep"
  fi
fi

# ── Re-scan assertions only (lightweight, no full rescan needed) ──
if [[ "$SKIP_PREFLIGHT" == false ]]; then
  scan_assertions
  if [[ ${#PREFLIGHT_BLOCKERS[@]} -gt 0 ]]; then
    print_post_watch_blockers
  fi
fi

if [[ "$DRY_RUN" == true ]]; then
  echo ""
  print_done "Dry run complete — ${BOLD}not sleeping${RESET} the Mac."
  play_sound
  log_event "DRY_RUN_EXIT"
  exit 0
fi

# ── Release caffeinate ────────────────────────────────────────
echo ""
print_step "Releasing caffeinate..."

if [[ ${#INITIAL_CAFF_PIDS[@]} -eq 0 ]]; then
  print_warn "No captured caffeinate PIDs — nothing to release"
else
  ALIVE_PIDS=()
  for pid in "${INITIAL_CAFF_PIDS[@]}"; do
    kill -0 "$pid" 2>/dev/null && ALIVE_PIDS+=("$pid")
  done

  if [[ ${#ALIVE_PIDS[@]} -eq 0 ]]; then
    print_warn "Captured caffeinate PIDs already exited — nothing to do"
  else
    kill "${ALIVE_PIDS[@]}" 2>/dev/null || true
    sleep 0.3

    STUCK_PIDS=()
    for pid in "${ALIVE_PIDS[@]}"; do
      kill -0 "$pid" 2>/dev/null && STUCK_PIDS+=("$pid")
    done

    if [[ ${#STUCK_PIDS[@]} -eq 0 ]]; then
      print_ok "caffeinate stopped (${#ALIVE_PIDS[@]} process(es): ${ALIVE_PIDS[*]})"
    elif kill -9 "${STUCK_PIDS[@]}" 2>/dev/null; then
      print_warn "caffeinate force-killed with SIGKILL: ${STUCK_PIDS[*]}"
      log_event "CAFFEINATE_SIGKILL pids=${STUCK_PIDS[*]}"
    else
      print_warn "Could not kill caffeinate PIDs ${STUCK_PIDS[*]} — try: sudo kill -9 ${STUCK_PIDS[*]}"
      log_event "CAFFEINATE_KILL_FAILED pids=${STUCK_PIDS[*]}"
    fi
  fi
fi

# ── Early exits ───────────────────────────────────────────────
echo ""

if [[ "$CAFFEINATE_ONLY" == true ]]; then
  print_done "Caffeinate released. Mac will sleep on its own idle timer."
  play_sound
  log_event "CAFFEINATE_ONLY_EXIT"
  exit 0
fi

# ── Sleep the Mac ─────────────────────────────────────────────
print_step "Sleeping Mac in ${BOLD}${DELAY_SECS}s${RESET}..."
play_sound
sleep "$DELAY_SECS"

echo ""
ui_panel success "Good night" "Requesting macOS sleep now."
echo ""

if attempt_sleep "watch"; then
  exit 0
fi

print_error "The Mac did not sleep after ${SLEEP_MAX_ATTEMPTS} attempts."
print_warn "Something is holding a PreventSystemSleep assertion. Inspect with:"
print_step "${BOLD}pmset -g assertions${RESET}"
log_event "SLEEP_FAILED attempts=${SLEEP_MAX_ATTEMPTS}"
notify_macos "goodnight could not sleep the Mac — see log"
exit 1
__SCRIPT_END__
