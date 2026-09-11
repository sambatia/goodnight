# Changelog

Notable changes to `goodnight` (binary: `sleep-after-claude`).

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.1] — 2026-09-12

### Fixed

- **launchd-supervised Apple daemons were offered as terminable "user apps".**
  A live run listed `AddressBookSourceSync` — the Contacts sync daemon — under
  *"User apps — These can be terminated by goodnight."* Killing it accomplishes
  nothing: launchd respawns it immediately. It was the third such daemon to
  reach that list, because classification consulted a hardcoded name list that
  by construction only ever knows the daemons that have already caused a bad
  run. Classification now asks the system instead: a process owned by another
  user cannot be signalled at all, and `launchctl list` distinguishes a
  supervised service (plain reverse-DNS label) from a user-launched application
  (`application.<bundle-id>.<n>.<n>`), which is exactly the difference between
  "quit Spotify" and "do not bother killing AddressBookSourceSync". The name
  list remains as the fallback for a pid that has already exited or that
  launchd does not know.
- **The advice given for such a daemon sent the user looking for a window that
  does not exist.** The fallback hint read *"quit the app that triggered this
  assertion"*, which is right for `cameracaptured` and wrong for a background
  sync service. A launchd-supervised blocker now says so instead.
- **An unset `USER` would have aborted the run.** Four places consult it —
  two ownership checks and two `pgrep -u` calls — and the script runs under
  `set -u`. It is now resolved once, falling back to `id -un`.

## [0.3.0] — 2026-09-11

### Fixed

- **Background shells and monitors were invisible to the CPU guard.** An agent's
  work is mostly done by its children — a background shell, a Monitor, a test
  run — spawned as `zsh`/`node`/`npm`, not as `claude`. `ps -o time=` never
  reports a child's CPU against its parent, so watching only the named agent
  processes missed exactly the work that continues *after* a turn ends and the
  busy marker has been cleared. The guard now walks the whole process tree.
  Measured live: 6 watched processes became 64, with 293 CPU-seconds previously
  outside view on a single agent.

## [0.2.2] — 2026-09-11

### Fixed

- **Our own `caffeinate` was reported as an un-releasable sleep blocker.**
  `caffeinate -dims` holds `PreventSystemSleep` (the `s`), and goodnight
  terminates it before sleeping — but only `PreventUserIdleSystemSleep` from
  caffeinate was classified as releasable. Every run with such a caffeinate up
  therefore opened with a red *"2 active system-sleep blocker(s) — releasing
  caffeinate alone will not be sufficient"* panel whose listed blockers **were**
  caffeinate. A caffeinate owned by another user still counts as a real blocker,
  since it survives the release step.
- **The unattended blocker message said "no one to prompt"** even with the user
  at the keyboard. It now distinguishes `--unattended` (you asked not to be
  asked, and says how to get the menu back) from a genuinely absent TTY.

## [0.2.1] — 2026-09-10

### Fixed

- **Spinner output could duplicate and strand fragments of earlier lines.**
  Line clearing padded a fixed 72 columns with spaces, which leaves a tail
  behind anything longer and — on a terminal narrower than 72 — wraps the
  padding itself into a second line the next `\r` cannot reach. Clearing now
  uses `\033[K` (erase to end of line), which is width-independent.
- **Cancelling smart mode logged `PID unknown`.** Smart mode watches markers and
  session logs, not a PID, so the handler reported a PID it never had for what
  is now the default mode — and named Claude alone when the watch covers several
  agents.

### Changed

- CI checks out with `actions/checkout@v7`.
- `PUBLIC_RELEASE_CHECKLIST.md` now reflects verified live configuration rather
  than intentions. Branch protection is enforced by a repository ruleset, which
  is why that section had read as entirely untouched.
- `.gitignore` covers agent CLI scratch files that were previously excluded only
  in a single local clone.

## [0.2.0] — 2026-09-10

A reliability release. `goodnight` had stopped doing its job some time
earlier and nothing about its behaviour said so; everything here targets
that class — **failures that leave the command apparently running.**

### Fixed

- **Hook detection followed a strippable annotation.** Detection keyed on a
  `_managed_by` JSON key in `~/.claude/settings.json`. Another tool rewrote that
  file and dropped the key while preserving the hook commands, so detection
  reported "not installed", the mode selector silently demoted to `--watch-pid`,
  and every night the command waited for an interactive Claude REPL to exit —
  reaching the 6h timeout instead of detecting idle. Detection now matches a
  `# goodnight-hook` sentinel inside the command itself.
- **Sleep was never verified.** `pmset sleepnow` exits 0 whether or not the Mac
  sleeps, so a refused sleep was reported as success. Sleep is now confirmed
  against `kern.sleeptime` and retried up to 3×; failure is loud.
- **The idle window was applied twice**, so the machine slept after roughly
  2×`--idle` rather than `--idle`.
- **The watch loop had no timeout.** `--timeout` bounded only the PID path, so a
  single wedged marker meant the Mac never slept.
- **A cold start never slept.** The loop refused to sleep until it had witnessed
  a busy marker appear, so "every agent already finished" waited forever.
- **Suspension read as elapsed watch time.** Closing the lid mid-watch and
  reopening it fired the timeout instantly, re-sleeping the Mac in your hands.
- **`runningboardd` was reported as a sleep blocker** on every run, and offered
  for termination despite being a launchd daemon that respawns.
- **Prompt timeouts didn't deliver their safe default**, and `ui_choose` printed
  its menu to stdout — which the caller command-substituted, so the menu came
  back glued to the answer and the blocker menu aborted whatever you picked.

### Added

- `--doctor` — reports live health of the whole integration; non-zero when
  degraded.
- `--version` / `-V`, plus the version in `--doctor` and in the log's
  `SMART_WATCH_START` line, so a night's outcome is attributable to a build.
- **Codex support.** `~/.codex/sessions` is watched alongside
  `~/.claude/projects`; extend with `SAC_EXTRA_ACTIVITY_DIRS`.
- **Agent CPU as a third signal**, covering agents that work silently. Watches
  `claude`, `codex`, `aider`, `gemini`, `opencode`, `cursor-agent`; extend with
  `SAC_EXTRA_AGENT_PROCESSES`. Veto-only and debounced.
- **Self-repairing hooks** — a degraded integration is fixed in place rather
  than silently disabling idle detection.
- A `SessionEnd` hook, so a session that quits mid-turn clears its marker.
- `--unattended`, `--idle`, `--stale`, `--no-cpu-guard`, `--no-repair`,
  `--no-log`.

### Changed

- **Logging is on by default** (`--no-log` opts out), rotated at 2 MB.
- **The update check is opt-in** (`--check-update`); it ends in a blocking
  prompt, and an unattended command must not stall on a question about itself.
- **Smart mode is the unconditional default.** PID mode is reachable only via
  `--pid`, `--wait-for-start` or `--watch-pid`.
- **Stale markers are corroborated against real session activity**, so the
  window drops from 24h to 15m without risking a reap mid-work.
- Every prompt is time-bounded and resolves to its safe default.
- The repository moved from `sambatia/sleep-after-claude` to `sambatia/goodnight`.
  GitHub redirects both `github.com` and `raw.githubusercontent.com`, so existing
  installs keep self-updating. **The old name must never be reclaimed.**

### Notes

Tests grew 133 → 226. Verified in production: waited 3,442s for a live Claude
session and a 4h Codex run, then slept on the first attempt with two blockers
still on record.

Still uncovered by construction: an agent that is neither writing to its session
log nor consuming CPU is indistinguishable from a finished one. `--idle` is the
knob.

## [0.1.0] — 2026-04-20

First public release.

[0.3.0]: https://github.com/sambatia/goodnight/releases/tag/v0.3.0
[0.2.2]: https://github.com/sambatia/goodnight/releases/tag/v0.2.2
[0.2.1]: https://github.com/sambatia/goodnight/releases/tag/v0.2.1
[0.2.0]: https://github.com/sambatia/goodnight/releases/tag/v0.2.0
[0.1.0]: https://github.com/sambatia/goodnight/releases/tag/v0.1.0
