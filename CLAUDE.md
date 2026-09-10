# CLAUDE.md

<!-- Last updated: 2026-04-20 | Audit cycle: 2026-04-20 (docs/comment sync after PR #5) -->

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Knowledge authority

- `README.md` is the public user/contributor source of truth: install path, CLI behavior, flags, test commands, release workflow, and troubleshooting.
- `CLAUDE.md` is the maintainer/agent source of truth: architecture, invariants, conventions, audit history, known risks, and implementation navigation.
- `CONTRIBUTING.md`, `SECURITY.md`, and `PUBLIC_RELEASE_CHECKLIST.md` are domain-specific satellites. Keep them consistent with `README.md` and reference `CLAUDE.md` for implementation details instead of duplicating architecture.
- `.github/workflows/ci.yml` and `.pre-commit-config.yaml` define the enforced verification pipeline. If docs and these files disagree about checks, update the docs to match the configs.

## Repository layout

macOS Bash utility `sleep-after-claude` (aliased to `goodnight`) that watches a Claude Code session and sleeps the Mac when it finishes. Distributed via a self-extracting installer over `curl | bash`.

- `sleep-after-claude` — the tool. Standalone Bash script.
- `install-sleep-after-claude.sh` — self-extracting installer. Embeds a byte-identical copy of `sleep-after-claude` between `__SCRIPT_START__` / `__SCRIPT_END__` markers and extracts it to `~/bin` at install time. Also auto-installs `jq` (SHA-pinned) and Claude Code hooks unless opted out.
- `scripts/check-parity.sh` — verifies the embedded payload matches the standalone script. See "Parity invariant" below.
- `.githooks/pre-commit` — opt-in legacy hook that runs the parity check when either script is staged. Enable with `git config core.hooksPath .githooks`. Superseded by the `pre-commit` framework config at `.pre-commit-config.yaml`.
- `.pre-commit-config.yaml` — canonical pre-commit config. Runs parity + `shellcheck` + `shfmt` + repo hygiene on every commit.
- `tests/` — bats-core regression suite (218 tests). Each `*.bats` file's header comment names the audit finding(s) or subsystem it protects. Live counts: `bats tests/ --count` and `ls tests/*.bats | wc -l`.
- `README.md` — user-facing install/usage guide + documented escape hatches for CDN staleness, SHA pinning, and hook opt-out.

## Parity invariant (critical)

`install-sleep-after-claude.sh` embeds a byte-for-byte copy of `sleep-after-claude` between its `__SCRIPT_START__` and `__SCRIPT_END__` markers. Any edit to `sleep-after-claude` **must** be mirrored into the embedded region of the installer (or vice versa), otherwise `curl | bash` users get a stale tool while local users remain fine — a silent split-brain that shipped undetected in prior cycles.

Enforcement:

```bash
bash scripts/check-parity.sh
```

Exits 0 when identical, non-zero with a diff excerpt on drift.

The preferred way to enforce this (and every other lint) is the `pre-commit` framework — install once per clone:

```bash
pre-commit install
```

This wires `.pre-commit-config.yaml` into `.git/hooks/pre-commit` and runs parity + shellcheck + shfmt + hygiene hooks on every commit. The standalone legacy hook at `.githooks/pre-commit` still exists for users who prefer `git config core.hooksPath .githooks`.

Regression test: `tests/parity.bats` (passes on tree, fails on induced drift, fails on missing markers).

## Installer trust chain

The installer may run in two modes:

1. **Local file execution** — `$0` is a real file path; payload is extracted directly via `awk`.
2. **Piped execution** — invoked as `curl ... | bash`, where `$0` is literally `"bash"` and no installer file exists on disk. In this case the installer re-downloads itself from `$SLEEP_AFTER_CLAUDE_INSTALLER_URL` (default: the `main` branch raw URL) into a temp file, sanity-checks it, then extracts.

The re-download path enforces:

- **Size envelope** — payload must be 2KB–512KB (guards against HTML error pages and truncated CDN responses).
- **Marker presence** — payload must contain both `__SCRIPT_START__` and `__SCRIPT_END__` literal lines.
- **Optional SHA-256 pin** — if `$SLEEP_AFTER_CLAUDE_INSTALLER_SHA256` is set, the downloaded body's `shasum -a 256` must match before extraction proceeds.

On the piped-install exit path, the installer **drains the remainder of its own stdin** (the bytes of the embedded payload that are still streaming from curl) behind a bounded 5s timeout (F-11) so a pathological trickle can't hang the exit. See installer step "Drain the rest of the piped installer" for the detection (`[[ -p /dev/stdin ]]`) and the `gtimeout` / `timeout` / background-watchdog fallback chain.

Regression tests: `tests/installer-trust-chain.bats`, `tests/installer-jq-rejection.bats`, `tests/installer-consent-and-exec.bats`, `tests/installer-deps.bats`.

## `jq` auto-install + SHA-256 pin

Default `goodnight` mode (`--smart`) requires `jq` to read/write `~/.claude/settings.json`. macOS ships without `jq`, so the installer auto-fetches a static binary from `github.com/jqlang/jq` releases and drops it at `~/bin/jq`. This is gated by:

- **Architecture probe** — `arm64` or `amd64`; unknown → skip with warning.
- **Pre-existing-binary probe (F-09)** — checks `~/bin/jq`, `/opt/homebrew/bin/jq`, `/usr/local/bin/jq`, `/usr/bin/jq` before reaching for the network. If found, adds its dir to `$PATH` for the remainder of the installer run.
- **Size envelope** — 500KB–10MB.
- **SHA-256 pin (F-02)** — per-arch expected hash hardcoded in `ensure_jq()`. Mismatch is a hard refusal (not a warning). Override via `SAC_JQ_SHA256=<hex>` when legitimately re-pinning.
- **macOS quarantine strip** — `xattr -d com.apple.quarantine` so Gatekeeper doesn't flag the first invocation.

Failure is non-fatal for the overall install: goodnight still works in legacy `--watch-pid` mode, and the user can run `brew install jq && goodnight --install-hooks` later.

Bumping jq: update `jq_version` + both arch hashes in `ensure_jq()`. Rotate hashes with `curl -fsSL <release-url> | shasum -a 256`.

Regression tests: `tests/installer-deps.bats` (happy + offline), `tests/installer-jq-rejection.bats` (F-02 — mismatched SHA refused, matching accepted).

## Claude Code hook integration

`--smart` mode sleeps the Mac when all Claude Code **sessions** are idle, not when the `claude` process exits. Process-exit watching (`--watch-pid`) doesn't work for the common case: a user leaves a Claude REPL open in a terminal tab, walks away, and the process lives until they quit the tab in the morning.

Hooks work by writing three entries into `~/.claude/settings.json`:

- `UserPromptSubmit` — `touch $BUSY_DIR/<session_id>` when the user sends a new message.
- `Stop` — `rm -f $BUSY_DIR/<session_id>` when Claude finishes its response and returns control.
- `SessionEnd` — same removal, covering the ways a session leaves without a final turn (quit mid-response, closed terminal, crash). Added 2026-09-10 after the marker directory was found holding 30 orphans accumulated over two months.

`BUSY_DIR` defaults to `~/.local/state/goodnight/busy`.

Hook command strings are written carefully:

- **Lazy `$HOME` expansion (F-03)** — when `BUSY_DIR` is the default, the command string embeds the literal `"$HOME/.local/state/goodnight/busy"` so it expands at hook-runtime in Claude's subshell, not at install-time in the installer's shell. Survives home-dir moves and differing-context invocations (cron, launchd, etc.).
- **Path quoting (F-04)** — when `BUSY_DIR` is non-default, the absolute path is single-quoted with `'` escaping so `$` / whitespace / metacharacters in the path can't be interpreted by Claude's hook shell.
- **`# goodnight-hook` sentinel** — a trailing shell comment on every command. Inert at runtime; it is what makes an entry self-identifying. See "Hook detection" below.
- **`_managed_by: goodnight` tag** — a sibling JSON key, kept for readability and as a secondary match.
- **Backup before write** — existing `settings.json` is copied to `settings.json.bak.<timestamp>` before merging.

Hook install opt-out: `SAC_SKIP_HOOK_INSTALL=1` (F-06) — installer announces clearly before touching `~/.claude/settings.json` and honors this env var for users who don't want automatic modification.

Regression tests: `tests/hooks.bats`, `tests/hook-command-runtime.bats` (F-03 runtime test: spawns a fresh shell with an arbitrary `$HOME`, pipes a real `.session_id` blob on stdin, verifies the hook command string resolves correctly), `tests/hook-detection-resilience.bats`.

### Hook detection (critical — this is what silently broke)

`settings.json` is co-owned. Claude Code writes it, and so does every tool the user has wired into their setup. In September 2026 something rewrote Sam's file and dropped the `_managed_by` key while preserving the hook commands verbatim. `hooks_installed` matched on that key alone, concluded the hooks were gone, and `goodnight` fell back to `--watch-pid` — where it waited for an interactive Claude REPL to exit, i.e. until the 6h timeout, every night, with no error. The hooks were firing correctly the entire time; nothing was reading them.

The rule that follows: **detection keys on the command string, not on annotations beside it.** A key we invented sitting next to keys Claude Code owns is fragile by construction; the command has to survive verbatim or the hook does not run at all.

`HOOK_MATCH_JQ` defines the shared predicate — a hook entry is ours if any of its commands matches `goodnight-hook|goodnight/busy`, **or** it carries the `_managed_by` tag. It is used by detection, install de-duplication, uninstall, and repair alike, so those four can never disagree about what counts as ours.

`HOOK_MATCH_JQ` defines **two** predicates, and the distinction matters:

- `gn_functional` — does the entry still carry a command that does the job? This is what *health* asks. The tag alone is not enough: an entry whose command was emptied or replaced would otherwise report healthy, skip repair, and leave an active turn markerless for the watcher to sleep over. That is the original bug wearing the opposite mask.
- `gn_owned` — is the entry ours to rewrite or remove? Broader on purpose, because a mangled entry we installed is still ours to clean up. Install de-duplication and uninstall use this one.

`hooks_health` reports one word: `ok` (all three of `UserPromptSubmit`, `Stop`, `SessionEnd` functional), `partial`, `missing`, `nofile`, `badjson`, or `nojq`. `hooks_installed` is true only for `ok`. **SessionEnd counts toward health** so that an install predating it reports `partial`, routes through repair once, and comes out whole — otherwise an upgraded machine keeps leaking a marker on every quit or crash and never finds out. **`partial` must never count as installed** — without `UserPromptSubmit` no marker is ever written, so a marker-trusting watcher reads a busy machine as idle and sleeps it mid-task. Fail toward staying awake.

`repair_claude_hooks` fixes a degraded install in place and runs automatically on the smart path (`--no-repair` opts out):

- **untagged** → re-tag the existing entries. Never append; that is how a repair becomes a duplicate-hook bug.
- **partial / missing** → full reinstall, which is idempotent because de-duplication matches the sentinel too.

Note `jq` is required at *hook* runtime, not just ours — `nojq` is a health failure regardless of what the file says.

Detection is verified against the real regression shape in `tests/hook-detection-resilience.bats`, including untagged entries, legacy entries with neither tag nor sentinel, partial installs, and the reinstall-does-not-duplicate case.

## Session activity model

Two independent signals decide whether an agent is still working. Both must be quiet before the Mac sleeps.

1. **Busy markers** — hook-driven, precise, instant. Only as trustworthy as the hooks.
2. **Agent session-log mtime** — every agent appends to its own session log as it works. Requires no cooperation, cannot be silently uninstalled, and covers sessions with no marker at all (background agents, sessions predating hook install, sessions whose hooks are broken).

   `AGENT_ACTIVITY_DIRS` lists the roots scanned, defaulting to both:

   | Agent | Log path |
   |---|---|
   | Claude Code | `~/.claude/projects/<slug>/<session_id>.jsonl` |
   | Codex | `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl` |

   Extend with `SAC_EXTRA_ACTIVITY_DIRS` (colon-separated) for any other agent that appends to a log as it works.

   **Codex support is not a nicety.** Busy markers only ever describe Claude Code sessions, so a Claude-only watch will happily sleep the Mac on top of a running Codex job. "Wait until my agents are done" has to mean all of them, not just the ones that can write us a marker.

Markers decide *which* sessions to care about; transcript mtime decides whether a marked session is genuinely alive. That pairing is the point:

- `transcript_for_session <sid>` resolves `$CLAUDE_PROJECTS_DIR/*/<sid>.jsonl`.
- `transcript_active_within <secs>` runs one `find … -mmin -N -print -quit` per root and returns on the first hit; early exit means cost does not scale with session-history size.
- `newest_agent_activity` echoes the newest mtime across all roots (used by `--doctor`).
- `reap_dead_markers` deletes any marker whose transcript has been silent past `SMART_STALE_MARKER_MINS` — a crash, a quit, or a session parked on a permission prompt. A marker with no transcript yet is spared until it ages out on its own mtime, so a prompt submitted a second ago is never reaped out from under a session about to start work.
- `count_busy_sessions` reaps first, then counts what remains.

Corroborating against transcripts is what allows the stale window to be **15 minutes** (`SAC_STALE_MARKER_MINUTES`) instead of the old blind **24 hours**. The old reaper deleted purely by marker age, so it had to be loose enough never to reap real work — which meant a crashed session pinned the machine awake for the rest of the day.

Regression tests: `tests/session-activity.bats`.

## Smart-watch semantics

`smart_watch_loop` sleeps when **both** signals are quiet for `SMART_IDLE_SECONDS` (default 300, `--idle`), and is bounded by `SMART_TIMEOUT_SECS` (`--timeout`, default 6h) regardless.

Three deliberate departures from the previous behaviour, each fixing a way the machine failed to sleep:

- **No cold-start hold.** The old loop refused to sleep until it had personally witnessed a marker appear (the F-01 guard), so the most common invocation of all — every agent already finished before you type `goodnight` — waited forever. Starting quiet is now a valid path to sleep; the transcript check is what makes that safe.
- **A hard timeout.** The old loop was `while true` with no elapsed check. `--timeout` bounded the PID path only, so one wedged marker meant the Mac never slept. Returns `2` on timeout; the caller sleeps anyway.
- **Adaptive poll.** 5s while waiting, tightening to 1s only for the last 30s of the countdown, through `micro_sleep` (no fork per tick). The interval *is* the race window — a session that resumes just after a check is one we could sleep on top of — so it wants to be small at the moment we act and no smaller than necessary before that.
- **Stands down if the Mac slept anyway.** `smart_watch_loop` samples `kern.sleeptime` at entry and each tick; if it moves, the machine slept by other means (lid, Apple menu, another tool) and the loop returns `3` and exits without sleeping. Without this the wall clock — which keeps running through a suspension — reads as elapsed watch time, so closing the lid at midnight and opening it at nine fires the timeout branch instantly and puts the machine straight back to sleep in the user's hands.

### Cost of the two signals

The watch draws on three signals per tick — marker count, newest session-log mtime, and agent CPU delta. Marker counting is O(markers × project dirs) in `stat`s; the session-log scan is O(all transcripts) and those accumulate forever with no pruning. The scan is therefore the expensive half, and it is **skipped entirely whenever a marker already says busy** — its answer cannot change the outcome there. That confines the full traversal to the genuinely-idle case, where the loop is also polling lazily. `reap_dead_markers` uses `stat` and second arithmetic rather than `find -mmin`, which costs the same fork but makes the stale window mean exactly what it says instead of rounding to whole minutes.

Default-mode selection: **smart, unconditionally**. Falling back to `--watch-pid` on a hook-detection failure is precisely what made the outage invisible — the command kept running, just uselessly. Smart mode repairs its own hooks and degrades to transcript-only detection if it cannot, so there is no failure PID mode needs to cover. `--pid`, `--wait-for-start`, and `--watch-pid` each select PID mode explicitly; without that, the smart default would silently ignore the flag the user just passed. Early-exit modes (`--install-hooks`, `--uninstall-hooks`, `--doctor`, `--preflight`, `--list`, `--log-summary`, `--sleep-now`) bypass selection entirely.

Regression tests: `tests/smart-watch-semantics.bats` (source contracts), `tests/smart-watch-runtime.bats` (drives the loop), `tests/default-mode.bats` (selection + repair).

### Third signal: agent CPU

An agent with no busy marker is otherwise judged purely on its session log. Claude Code is safe there — a long tool call holds its marker for the whole turn — but Codex has no marker, so a Codex tool call running longer than `--idle` without writing to its rollout log would look idle.

`agent_cpu_centiseconds` closes that: it sums cumulative CPU across every live `claude` and `codex` process, and the loop compares the delta against the interval actually elapsed. Above `AGENT_CPU_BUSY_PCT` (default 20% of one core) the tick counts as activity and pins `last_activity` to now.

Design constraints, in order of importance:

- **Veto only.** It can set `last_activity=$now` and nothing else. An agent blocked on a network round trip burns no CPU while genuinely working, so CPU is sound as a reason to stay awake and worthless as a reason to sleep. It must never be able to shorten a wait.
- **Bounded.** A veto that never clears is the failure this whole cycle was about, so the hard `--timeout` still applies over the top.
- **Above the noise floor.** Measured idle drift for live agent processes on a working machine is ~5% of one core; 20% carries roughly a 4× margin. Threshold is compared against the real elapsed interval rather than the tick, so it means the same thing at either poll rate.
- **Fails to "no veto".** Missing `pgrep`, unreadable `ps`, unparseable output — all yield 0, which delays nothing.
- **First tick cannot veto**, since there is no previous sample to difference against.

`--no-cpu-guard` / `SAC_AGENT_CPU_BUSY_PCT` are the escape hatches; the only reason to want the former is an agent process that idles hot enough to trip the threshold.

**What is still not covered:** an agent that is neither writing to its log nor consuming CPU — blocked on a very long network call, say. Nothing observable distinguishes that from finished, and `--idle` is the honest knob.

## Verified sleep

`pmset sleepnow` exits 0 whether or not the machine sleeps. When any process holds a `PreventSystemSleep` assertion macOS declines and pmset still reports success — so the old code printed "Good night", exited 0, and left the Mac awake all night with nothing in the log.

`attempt_sleep` is now the only sleep path (`tests/smart-watch-semantics.bats` asserts no bare `pmset sleepnow` survives anywhere):

1. Record `kern.sleeptime` — the kernel's last sleep-transition timestamp, which moves if and only if the machine actually slept.
2. Issue `pmset sleepnow`, falling back to `osascript … sleep` if pmset itself errors.
3. Wait `SLEEP_VERIFY_SECS` (12). If the Mac slept, execution simply stops here until it wakes.
4. Confirm: `kern.sleeptime` advanced, or the wall clock jumped far past the wait (fallback when sysctl is unreadable).
5. On refusal: re-scan assertions, log the holders by name and PID, release any caffeinate that has appeared since, back off, retry up to `SLEEP_MAX_ATTEMPTS` (3).

Failure is loud — non-zero exit, a `SLEEP_FAILED` log line, and a notification.

Regression tests: `tests/verified-sleep.bats` (shimmed `pmset` + `sysctl`; covers confirmed, refused, refused-then-succeeded, pmset-errors, and unreadable-sysctl paths).

## `--doctor`

One command that answers "will this work tonight?" without reading source. It exists because the failure that prompted this cycle was invisible from outside: hooks looked installed, markers were still being written, the command still ran.

Reports hook health per event, re-tag need, marker counts (found / reaped / live), time since last agent output, effective watch configuration, sleep blockers, and power state — then a verdict of would-sleep / would-wait / degraded. **Exits non-zero when degraded**, so it works as a health check. It reaps stale markers as a side effect (that is cleanup, not diagnosis) but never sleeps the machine — asserted explicitly in `tests/doctor.bats`.

### Numeric config is validated at assignment

Every `SAC_*` integer override goes through `_cfg_int`, which falls back to the default and records a warning surfaced on the actionable path. This is not politeness. These values reach arithmetic contexts, and under `set -u` bash reads a non-numeric word there as a variable name, finds it unset, and aborts — so one typo in a tuning knob would end the watch instead of being ignored.

`_cfg_int` answers in `$REPLY` rather than on stdout: command substitution would run it in a subshell and the warning would die there, leaving a bad value silently corrected.

### Two shell-level traps this code has already fallen into

- **`cmd | awk … || echo 0` under `set -o pipefail`.** awk's `END` block still prints when the upstream fails, and the failing pipeline then fires the fallback as well — two values where the contract promises one. Capture into a variable and validate at a single exit point.
- **State assigned inside `$( )` is lost.** Anything a helper needs to accumulate for its caller must come back through `$REPLY` or a file, never a subshell.

`tests/lib/common.bash` now writes `set -uo pipefail` into every extracted-function harness, because the first of these shipped precisely because the tests ran under laxer options than production.

## Unattended operation

This command is started by someone who is about to stop watching it. Anything that can block indefinitely is a defect:

- **Logging is on by default** (`--no-log` opts out), rotated at `LOG_MAX_BYTES` (2 MB) to `.log.1`. A run that takes an irreversible action while nobody is watching and leaves no evidence cannot be debugged the next morning.
- **The update check is opt-in** (`--check-update`). It ends in a blocking y/N prompt; a command you start and walk away from must not stall on a question about itself. `SAC_SKIP_UPDATE_CHECK` remains a hard override so the post-update re-exec cannot loop when the replayed argv contains `--check-update` (F-05).
- **Every prompt is time-bounded** by `PROMPT_TIMEOUT_SECS` (60) and resolves to its safe default. `gum confirm`/`gum choose` get `--timeout`; the plain fallback uses `read -t`.
- **The blocker menu leads with the safe option**, because `gum choose --timeout` returns the *highlighted* element — putting "terminate the user's apps" first would auto-kill them on timeout.
- **`--unattended`** declines every prompt outright.
- **A failed blocker scan no longer aborts the run** under `--force` or `--unattended`. The scan is advisory; the sleep itself is verified and retried, so cancelling the night over a transient `pmset` failure is the worse outcome.
- **Blockers no longer abort** when there is nobody to ask. Aborting guarantees the Mac stays awake; proceeding gets a verified, retried, logged attempt. That trade only became correct once sleep was verified.

Regression tests: `tests/doctor.bats`, `tests/default-mode.bats`, `tests/terminal-ui.bats`.

## Preflight fail-closed contract

The `--preflight` scan parses `pmset -g assertions` to predict whether `pmset sleepnow` will actually succeed. The function `scan_assertions` sets a global `PREFLIGHT_SCAN_OK` that is **true only when** pmset exited 0 AND produced the expected `Listed by owning process` header. A failing scan must never render as a green "clear" verdict.

Rendering contract (both JSON and human-readable):

| Scan state | Brief verdict | JSON `scan_ok` | JSON `can_sleep` |
|---|---|---|---|
| Scan failed | "Sleep-blocker scan unavailable" | `false` | `null` |
| Scan clear | "No sleep blockers detected" | `true` | `true` |
| Scan found blockers | "N sleep blocker(s): ..." | `true` | `false` |

Pre-watch gate: when `PREFLIGHT_SCAN_OK != true`, the tool requires TTY confirmation or `--force` — same behavior as when actual blockers are present. Applies to the default flow, `--smart`, and `--sleep-now`.

Blocker classification (`classify_blocker` at line ~921) groups assertions into `blocker | system | display | user | release` buckets so the renderer can show actionable blockers prominently and system-daemon noise dimly. The interactive menu offered on detected blockers lets the user terminate user-space apps (e.g., Zoom), skip with warning, or abort.

Regression tests: `tests/preflight-fail-closed.bats`, `tests/blocker-classification.bats`.

## Power-state gate

The actionable path (`default watch`, `--smart`, `--dry-run`, `--caffeinate-only`, `--sleep-now`, `--wait-for-start`) begins with `wait_for_ac_power`. When on battery, it renders a styled warning card (gum-powered or hand-drawn fallback) and polls `pmset -g batt` every 2s with a spinner until AC is detected.

Skippable with `--allow-battery` or `--force`. Desktop Macs (no battery detectable) pass through as power source `"Unknown"`. Must be the **first** check on the actionable path — we don't want to burn battery downloading self-update checks or waiting for Claude when unplugged.

Regression tests: `tests/power-gate.bats` (shimmed `pmset` across AC / Battery / Unknown states).

## Self-update check

`check_for_update` runs on the actionable path (after the power gate, before preflight). Compares `shasum -a 256` of the running script to the remote canonical script at `$SLEEP_AFTER_CLAUDE_UPDATE_URL` (default: main-branch raw URL). Rate-limited to once per `UPDATE_CACHE_TTL_SECS` (default 24h) via `~/.cache/sleep-after-claude/last-update-check`.

**Fails open** (silent skip) on: `--skip-update-check`, missing `curl` / `shasum`, network error, unwritable cache dir, non-shebang remote content (CDN error page), or non-TTY stdin (don't prompt in automation). Force an immediate check with `--check-update` (busts the TTL cache).

On mismatch + TTY confirmation:

1. Run `curl … | bash` against `$UPDATE_INSTALLER_URL` with `SAC_SKIP_HOOK_INSTALL=1` (hooks already installed — skip the announcement).
2. On success: `exec` into the freshly-installed binary using `SAC_ORIGINAL_ARGS` (captured at script entry) so the update seamlessly continues the user's current invocation (F-05). `SAC_SKIP_UPDATE_CHECK=1` is set in the child env so the new process doesn't re-prompt.
3. If `exec` fails (unwritable target, etc.): warn and continue with the in-memory stale script.

Regression tests: `tests/update-check.bats` (shimmed `curl` on `PATH` serving local files; isolated `$HOME`).

## Concurrent-run lock (F-07)

Two concurrent `goodnight` invocations racing on caffeinate release and `pmset sleepnow` was a real failure mode (second instance sleeps the Mac while first is still watching). macOS bash ships without `flock`; the fix is a **directory-as-lock** at `~/.local/state/goodnight/lock` using the atomicity of `mkdir`.

- Acquired after preflight, before `WATCH_STARTED=true` — both in `--smart` and the default flow (guarded by `SMART_WATCH_DONE` so we don't double-acquire).
- PID written to `$GOODNIGHT_LOCK_DIR/pid`. On collision: if `kill -0 $holder_pid` succeeds, error out; if the holder is dead, the lock is reclaimed (prevents permanent deadlock after crash).
- Released on every exit path via the EXIT trap (`cleanup_fd_and_tmp` → `release_goodnight_lock`).

Regression tests: `tests/concurrent-lock.bats`, `tests/concurrent-lock-runtime.bats` (spawns two real bash subprocesses racing on the lock; asserts exactly one wins).

## Testing

Tests use bats-core and PATH-shim mocks (fake `pmset` / `curl` / `jq` binaries in per-test TMPDIRs). They run fully offline and are deterministic. Shared helpers live at `tests/lib/common.bash` (`setup_sandbox`, `shim`, `shim_fixture`, `assert_contains`).

```bash
bats tests/                   # full suite
bats tests/parity.bats        # single file
bats tests/ --count           # live test count
bash -n sleep-after-claude install-sleep-after-claude.sh scripts/check-parity.sh
bash scripts/check-parity.sh
```

### What's covered

Every finding fixed in either audit cycle has at least one regression test that would fail if its fix were reverted. Each `tests/*.bats` file's header comment names the finding(s) it protects.

### What's not covered

- The **real** `pmset sleepnow` call — would require actually sleeping the test machine. The *verification and retry logic* around it is covered (`tests/verified-sleep.bats`) by shimming `pmset` and `sysctl`; what remains untested is only whether macOS itself honours the request.
- **Real transcript writes by a live Claude session** — `tests/session-activity.bats` fabricates the `.jsonl` tree and backdates mtimes. The assumption that Claude appends to the transcript throughout a turn is verified by observation, not by test.
- Network behavior of real `curl` against GitHub — tests use `file://` URLs and PATH-shimmed `curl` only.
- The full installer end-to-end in piped mode — the TTY / stdin-pipe semantics are hard to simulate faithfully; individual pieces (size check, marker check, SHA pin, drain timeout, hook install, jq install) have isolated tests.

## Architecture of `sleep-after-claude`

Linear top-to-bottom flow with labeled section banners (`# ── Section ──`). Navigate by banners rather than line numbers — line numbers drift with edits. Major sections, in source order:

1. **macOS guard + TTY/Bash-version detection** — sets `USE_BUILTIN_SLEEP` (Bash ≥ 4 FIFO trick to avoid forking `sleep`), color toggles, and TTY flags that downstream output branches on. Captures `SAC_ORIGINAL_ARGS` up-front for the self-update re-exec path (F-05).
2. **Colours + config defaults** — flag-state booleans, paths, TTL values.
3. **Helpers** — `print_*` helpers, `elapsed_label`, `play_sound`, `as_escape` / `json_escape`, `notify_macos`, `log_event` (warn-once on write failure), `micro_sleep` (FIFO builtin fast-path).
4. **gum / glow integration** — optional polish layer. `have_gum` / `have_glow` detection gates TUI rendering (panels, confirms, menus, spinners, markdown help/log summary rendering). Over SSH: gum defaults off because mobile SSH clients (Termius/Blink) mishandle `/dev/tty` and arrow keys. `SAC_NO_GUM=1` forces fallback; `SAC_FORCE_GUM=1` re-enables over SSH; `SAC_NO_GLOW=1` disables markdown rendering. Confirmation prompts fail closed when stdin is not a TTY.
5. **Claude process detection** (`find_claude_processes`) — two-tier: a "tight" pass using `pgrep -x claude` / `pgrep -f claude-code`, falling back to a broad `pgrep -fi claude` filtered by `EXCLUDE_PATTERN` to weed out Electron apps (Claude.app, Cursor, Windsurf, chrome-native-host, `anthropic-tools`, etc.). When adding a new false-positive, update `EXCLUDE_PATTERN`.
6. **Pre-flight scan** (`scan_assertions`, `preflight_scan`, `render_preflight*`) — inventories caffeinate processes, `pmset -g assertions`, clamshell/lid state, battery, user sessions, then emits a verdict. Gated by `--no-preflight`, restricted by `--brief`, machine-readable via `--json`. See "Preflight fail-closed contract" above.
7. **Blocker classification** (`classify_blocker`, `prompt_and_handle_blockers`, `print_post_watch_blockers`) — groups assertions into severity buckets and drives the interactive terminate/skip/abort menu when blockers are present.
8. **Auto-start caffeinate -dim** (`ensure_caffeinate_running`) — launches a detached `caffeinate -dim` when none is already owned by `$USER`, so the Mac doesn't drift to sleep while we watch. Skippable with `--no-auto-caffeinate`.
9. **Power-state gate** (`get_power_source`, `get_battery_percent`, `render_battery_gauge`, `wait_for_ac_power`) — blocks until AC is connected when on battery. See "Power-state gate" above.
10. **Self-update check** (`check_for_update`) — see "Self-update check" above.
11. **Claude Code hook integration** (`HOOK_MATCH_JQ`, `hooks_health`, `hooks_installed`, `hooks_need_retag`, `repair_claude_hooks`, `install_claude_hooks`, `uninstall_claude_hooks`) — see "Claude Code hook integration" above. All four consumers share `HOOK_MATCH_JQ` so detection, install de-dup, uninstall, and repair cannot disagree about what counts as ours.
    - **Session activity model** (`transcript_for_session`, `transcript_active_within`, `reap_dead_markers`, `count_busy_sessions`, `smart_watch_loop`) — see "Session activity model" and "Smart-watch semantics" above.
    - **Verified sleep** (`sleep_stamp`, `wake_stamp`, `release_all_caffeinate`, `attempt_sleep`) — see "Verified sleep" above.
12. **Argument parsing** — flag table lives inline in the `--help` block. Keep the `case` arms, the default-mode-selection block, and the `--help` text in sync when adding flags.
13. **Default mode selection** — always `--smart`. PID mode is reachable only via `--pid` / `--wait-for-start` / `--watch-pid`, each of which sets it in its own flag arm. See "Smart-watch semantics" above.
14. **FIFO setup + cleanup traps** — opens fd 9 on a named pipe so the watch loop can `read -t` instead of forking `/bin/sleep` every tick. EXIT trap releases the fd, removes the FIFO dir, and releases the concurrent-run lock (F-07). `on_interrupt` (INT/TERM/HUP) no longer calls `cleanup_fd_and_tmp` directly (F-12) — relies on the EXIT trap.
15. **Concurrent-run lock** (`acquire_goodnight_lock`, `release_goodnight_lock`) — see "Concurrent-run lock (F-07)" above.
16. **`--install-hooks` / `--uninstall-hooks` / `--doctor` fast paths** — pure config-file and diagnostic operations; no watch, no sleep. `--doctor` exits non-zero when the integration is degraded.
17. **`--list` / `--preflight` / `--log-summary` modes** — early exits for introspection-only flows. `--log-summary` renders recent events + per-category counts as markdown via `glow` when available, plain text otherwise.
18. **Actionable-path preamble** — `print_header` → `wait_for_ac_power` → `check_for_update`. Every path that might actually sleep the Mac goes through these in this order.
19. **`--sleep-now` fast path** — skips Claude detection and the watch loop entirely. Runs preflight + blocker handling, releases existing caffeinate, then sleeps.
20. **`--smart` mode** — the default watch. Checks `hooks_health`, self-repairs when degraded (unless `--no-repair`), and warns loudly + continues on transcript-only detection if repair fails; it never refuses to run. Reaps orphaned markers up front so the first tick reports a truthful count, runs preflight + blocker handling, acquires the lock, runs `smart_watch_loop`, then falls through to the release-caffeinate + sleep sequence by setting `SMART_WATCH_DONE=true`.
21. **Detect Claude PID** — default watch mode when `TARGET_PID` isn't set by `--pid` or smart-mode. Honors `--wait-for-start`. On multi-match, watches the first and prints the rest with a hint to use `--pid`.
22. **Pre-flight scan + verdict + optional confirmation** — runs on the default / `--watch-pid` path.
23. **Watch loop** — polls the target PID until it exits or `--timeout` fires. PID-reuse detection (every 300 ticks / 30s) compares the **binary path only** (first whitespace token of `ps -p … -o command=`), not the full argv — argv mutation via `setproctitle` / `exec -a` must not trigger a false "reused" signal (F-10).
24. **Release caffeinate + verified sleep** — kill captured caffeinate PIDs (SIGTERM → SIGKILL fallback), respect `--dry-run` / `--caffeinate-only`, then hand off to `attempt_sleep`, which confirms against `kern.sleeptime` and retries. See "Verified sleep" above. Never call `pmset sleepnow` directly.

When modifying behavior, identify which section owns the concern; most flags touch exactly one section.

## Conventions

- Bash, `set -uo pipefail` (intentionally no `-e` — the script relies on non-zero exits from `pgrep` being non-fatal).
- All user-facing output goes through `print_header` / `print_step` / `print_ok` / `print_warn` / `print_error` / `print_done`. Don't emit raw `echo` for status lines — these helpers handle TTY/non-TTY color stripping.
- Styled UI (confirms, menus, panels, spinners) goes through `ui_confirm` / `ui_choose` / `ui_panel` / `ui_spin` so gum / hand-drawn fallback selection happens in one place.
- Markdown help and log-summary output goes through `ui_markdown` so `glow` remains optional and non-TTY output stays plain.
- Integer validation uses `is_integer` / `is_positive_integer`; reuse rather than inlining regex.
- `printf` format strings used with dynamic data must be **static** (every dynamic value passes through `%s`) — stray `%` in battery percents, cmd names, etc. would otherwise corrupt the format. Search "Static format" in the source for the safety pattern.
- `--json` output is consumed by automation; any new preflight field must be added to the JSON emitter **and** the human-readable renderer **and** the JSON-shape assertions in `tests/preflight-fail-closed.bats`.
- `log_event` writes to `$LOG_FILE` unless `--no-log` is passed (logging defaults ON — see "Unattended operation"). `maybe_rotate_log` runs once per invocation, not per event, since the tick loop calls `log_event` often. It warns to stderr **once per session** on first write failure (brace-grouped `{ echo ...; } 2>/dev/null` so bash's own redirection error is also suppressed). Subsequent failures stay silent to avoid spamming the watch loop. Event names are stable — `--log-summary` groups on them.

### Commenting standard

This is a Bash project, so production comments use `#` comments rather than JSDoc/TSDoc. Keep comments close to the function or control-flow block they explain. File headers should state the script's responsibility and consumers. Function comments should document contracts, failure behavior, side effects, and non-obvious safety constraints; do not add comments that merely restate a function name or a simple assignment. If `sleep-after-claude` comments change, mirror the same comment-only update into the embedded payload in `install-sleep-after-claude.sh` and run `bash scripts/check-parity.sh`.

### Formatting / linting

All shell scripts are formatted with `shfmt -i 2 -ci` and linted with `shellcheck -S warning`. Both run automatically via the `pre-commit` framework (`.pre-commit-config.yaml`). Run manually:

```bash
shfmt -w -i 2 -ci sleep-after-claude install-sleep-after-claude.sh scripts/*.sh .githooks/pre-commit tests/lib/common.bash
shellcheck -S warning sleep-after-claude install-sleep-after-claude.sh scripts/*.sh .githooks/pre-commit tests/lib/common.bash
pre-commit run --all-files
```

Intentional shellcheck suppressions live next to the code via `# shellcheck disable=SCxxxx` with a reason. Don't add suppressions without a reason.

For editor experience, `bash-language-server` gives real-time shellcheck diagnostics and cross-file symbol navigation — install it as your editor's LSP for bash.

## Installer conventions

- Shell rc detection: `zsh` → `~/.zshrc`; `bash` → `~/.bash_profile` if exists else `~/.bashrc`. Unknown shells (fish, nushell, etc.) **skip alias install** and print manual instructions — do not fall through to `~/.zshrc`.
- The `goodnight` alias line is written with `$HOME` **expanded at install time** to an absolute path. Reinstalls strip any prior `alias goodnight=` line (and its `# sleep-after-claude shortcut` header comment if directly above) before re-appending — this makes reinstalls at a new path idempotent.
- A `PATH` line (`export PATH="$HOME/bin:$PATH"`) is appended to the same rc file on fresh installs, dedupe-checked so manually-edited `PATH` exports aren't duplicated.
- `jq` auto-install is best-effort — failure is non-fatal; installer continues and falls back to `--watch-pid` mode.
- Claude Code hook install is best-effort — gated by `SAC_SKIP_HOOK_INSTALL=1` (F-06) and by `jq` availability. When the installer modifies `~/.claude/settings.json` it announces the change explicitly first.
- Verification failure (`$TARGET --help` returning non-zero) is a hard error — installer exits 1, not warn-and-continue.
- On piped install (`curl | bash`), the installer drains its remaining stdin before exit with a bounded 5s timeout (F-11) to avoid `curl: (56)` cosmetic errors.

## Audit cycle history

### 2026-09-10 (reliability cycle — silent-failure class)

Triggered by a direct question — "is `goodnight` still working?" — whose honest answer was no, and had been for some time with no symptom anyone would notice. Every fix in this cycle targets the same class: **a failure that leaves the command apparently running.**

Root cause: `hooks_installed` matched only on the `_managed_by` JSON key. Something rewrote `~/.claude/settings.json` and dropped it while preserving the hook commands. Detection reported "not installed", the default-mode selector silently demoted to `--watch-pid`, and the command spent every night waiting for an interactive Claude REPL to exit — reaching the 6h timeout instead of the intended idle detection. The hooks fired correctly throughout; nothing read them.

Fixed:

- **Detection follows the command, not annotations.** `HOOK_MATCH_JQ` matches a `# goodnight-hook` sentinel embedded in the command string, with the JSON tag as a secondary signal. Shared by detection, install de-dup, uninstall, and repair.
- **Self-repair.** `hooks_health` classifies the failure; `repair_claude_hooks` re-tags in place or reinstalls. Runs automatically on the smart path.
- **No silent demotion.** Smart mode is the unconditional default; it degrades loudly to transcript-only detection rather than switching to a mode that cannot work.
- **Transcript-corroborated liveness.** Marker staleness is now checked against real session activity, letting the stale window drop from 24h to 15m — a crashed or prompt-blocked session no longer pins the Mac awake for a day.
- **Cold-start hold removed.** "All agents already finished" — the most common invocation — used to wait forever.
- **Hard timeout in the smart loop.** It was `while true`; `--timeout` bounded only the PID path.
- **Verified sleep.** `pmset sleepnow` returns 0 even when macOS refuses. `attempt_sleep` confirms against `kern.sleeptime` and retries; failure is loud.
- **Unattended by default.** Logging on, update check opt-in, every prompt time-bounded, blockers no longer abort when nobody is there to answer.
- **`--doctor`.** The diagnostic that would have caught this from the outside on day one.

Tests: 133 → 218. New files: `hook-detection-resilience.bats`, `session-activity.bats`, `verified-sleep.bats`, `doctor.bats`. Rewritten: `smart-watch-semantics.bats`, `smart-watch-runtime.bats`, `default-mode.bats`.

**Deliberately broken contracts** (old tests asserted these; they were the bugs): the F-01 cold-start hold, the F-08 24-hour blind reaper, and PID-mode fallback on hook-detection failure. Each replaced by a test asserting the new contract rather than deleted.

**Verified in production 2026-09-10.** The rebuilt command was left running unattended against a machine with a live Claude session and a 4h-old Codex run. It waited 3,442s for both to go quiet, released caffeinate, and confirmed sleep against `kern.sleeptime` on the first attempt — with two sleep blockers still recorded at the moment it asked. That last detail is the point: the previous code would have reported success there regardless.

**Lesson for the next cycle:** the tests were green the whole time this was broken. They asserted that `hooks_installed` returned true for a *tagged* fixture — never that it survived a fixture whose tag had been stripped by someone else. When a component's correctness depends on data another program owns, the test has to model that program misbehaving.

### 2026-04-20 (PR #4 / PR #5 safety follow-up)

Latest audit → remediation → test expansion cycle on `main`, focused on smart-mode correctness, hook failure safety, dry-run side effects, and terminal UI behavior.

- **Escalated / not fixed in code:** latest-cycle **F-01** remains a supply-chain trust decision for piped installs. The installer supports size checks, marker checks, and optional `SLEEP_AFTER_CLAUDE_INSTALLER_SHA256`; without a user-supplied SHA pin, default `curl | bash` still trusts the HTTPS raw GitHub response.
- **Remediation (merged to `main` as PR #4, squash commit `f5785c6`):**
  - **F-02** — smart-mode idle completion now falls through cleanly to the release-caffeinate + sleep path instead of being revalidated as a PID watch.
  - **F-03** — hook install fails closed on invalid `~/.claude/settings.json` and preserves the existing file.
  - **F-04** — hook uninstall fails closed on invalid settings JSON, and hook readiness checks require `jq` rather than marker text alone.
  - **F-05** — dry-run mode no longer auto-starts/releases `caffeinate` or calls `pmset sleepnow`, including `--sleep-now --dry-run`.
  - **F-07** — watch locking and smart-mode flow prevent concurrent runs from racing on shared sleep side effects.
- **Tests:** regression coverage was added or expanded in `tests/smart-watch-runtime.bats`, `tests/hooks.bats`, `tests/default-mode.bats`, and `tests/auto-caffeinate.bats`. Totals are retrievable via `bats tests/ --count`.
- **Terminal UI polish (merged to `main` as PR #5, squash commit `386c5a8`):** help and log-summary rendering go through optional `glow`; confirmations fail closed when non-interactive; terminal UI behavior is covered by `tests/terminal-ui.bats`.
- **Docs:** CLAUDE.md + README.md reflect the post-remediation state, including hooks, self-update, power gate, concurrent lock, terminal UI fallbacks, and the current GitHub Actions pipeline.

### 2026-04-19 (initial audit)

First audit → remediation → test expansion → docs sync cycle covering the original installer + preflight surface.

- **Audit:** 17 findings (1 Critical, 7 High, 9 Notable).
- **Remediation:** 9 findings fixed across 4 commits (F-02, F-03, F-04, F-05, F-06, F-07, F-08, F-10, F-11 of the **initial** numbering). Commits: `d055d0c`, `d410216`, `9a98861`, `6926159`. Notable deferred items were either re-scoped into the 2026-04-20 cycle under new IDs or remain open.
- **Decisions captured in this file:**
  - Parity enforcement via `scripts/check-parity.sh` + `.pre-commit-config.yaml` rather than auto-generating the installer from the standalone (dual-file architecture preserved; single-source-of-truth deferred).
  - Installer trust chain adopted size + marker + optional SHA-256 gating rather than pinning to a commit SHA by default (users can pin via env var; default stays on `main` for frictionless `curl | bash`).
  - Preflight fails closed (not open) on unknown pmset state — a silent "clear" verdict is the worst possible failure for this tool.

> **Note on finding-ID overlap.** The 2026-04-19 and 2026-04-20 cycles both number their findings `F-01…F-NN` independently — the IDs are scoped to the cycle they appear in, not globally unique. A commit message referencing `F-07` means "F-07 of the cycle this commit belongs to." When in doubt, check the commit date.

## graphify

This project has a graphify knowledge graph at graphify-out/.

Rules:
- Before answering architecture or codebase questions, read graphify-out/GRAPH_REPORT.md for god nodes and community structure
- If graphify-out/wiki/index.md exists, navigate it instead of reading raw files
- After modifying code files in this session, run `graphify update .` to keep the graph current (AST-only, no API cost)
