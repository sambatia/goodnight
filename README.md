# 🌙 goodnight

> **Put your Mac to sleep automatically when Claude Code finishes a long task — so your battery, your electricity bill, and your conscience can rest easy.**

![macOS](https://img.shields.io/badge/platform-macOS-silver)
![Shell](https://img.shields.io/badge/made%20with-Bash-1f425f.svg)
![Tests](https://img.shields.io/badge/tests-bats--core-brightgreen)
![License](https://img.shields.io/badge/license-MIT-blue)
![Last commit](https://img.shields.io/github/last-commit/sambatia/goodnight)
![Open issues](https://img.shields.io/github/issues/sambatia/goodnight)


> **Names.** The repo and the command share a name; the binary and its files do not, deliberately.
>
> | | |
> |---|---|
> | repo | `goodnight` |
> | command you type | `goodnight` (alias) |
> | binary / installer | `sleep-after-claude` |
> | state, lock, hook sentinel | `~/.local/state/goodnight/`, `# goodnight-hook` |
> | log / cache / env vars | `sleep-after-claude`, `SLEEP_AFTER_CLAUDE_*`, `SAC_*` |
>
> Renaming the binary would mean migrating every existing install's log, cache and environment for no functional gain, so it keeps its original name.

---

## 🎯 Section 2: What Is This Project?

You've probably had this moment: it's 11 PM. You've just kicked off a long **Claude Code** task — maybe refactoring a large codebase, running a multi-step build, or analyzing a giant repo. The work is going to take 20, 40, maybe 90 minutes. You really just want to go to bed. But if you leave your Mac awake, the fan spins all night, the battery drains, and in the morning you've burned electricity for no reason.

**goodnight** is a tiny command-line tool that fixes exactly this. You type one word — `goodnight` — in your terminal. It watches the Claude Code process you have running. The moment Claude finishes, it quietly puts your Mac to sleep. That's the whole product.

Think of it like a **babysitter for your computer**. You're leaving the house (or going to bed), and you want someone to watch your kid (Claude Code) finish their homework. When they're done, the babysitter turns off the lights, locks the doors, and the house goes quiet. You don't have to stay up. You don't have to check on it. You just go to sleep.

---

## 💡 Section 3: Why This Project Exists

### The Problem (Before)

> It's late. You've asked Claude to do something ambitious — a big refactor, a long audit, a multi-file migration. The progress spinner is spinning. You know it could be anywhere from 10 minutes to an hour.
>
> You face three bad choices:
>
> 1. **Stay up and babysit it.** You're tired. You have a meeting at 9 AM.
> 2. **Go to bed and leave your Mac awake all night.** Fans running. Battery draining. Electricity meter ticking. You wake up to a hot laptop and a dead battery.
> 3. **Guess when it'll be done** and set a manual sleep timer. You'll guess wrong — either the Mac sleeps while Claude is still working (now Claude dies mid-task), or it stays awake for hours after Claude finished at 11:07 PM.

### The Solution (After)

> You run one command: `goodnight`. You close your laptop lid (or just walk away). goodnight watches Claude in the background. The second Claude's process exits, goodnight:
>
> - Waves the "sleep OK" flag to macOS
> - Releases any coffee-pot apps that were keeping the Mac awake
> - Runs `pmset sleepnow` — the macOS system command that initiates sleep
>
> Your Mac goes to sleep at 11:07 PM, exactly one second after Claude stopped. In the morning, you wake up, open your laptop, and Claude's output is right there waiting for you. No fan noise overnight. No drained battery.

### The Opportunity

AI coding assistants like **Claude Code** are becoming the workhorse of serious software development. A single task can legitimately take an hour. Multiply that by thousands of developers running long tasks every night, and the "I had to leave my Mac awake" problem is a real, boring, solvable tax on the industry. goodnight is the tiny piece of plumbing that eliminates it.

### Before vs After

| Situation | Before goodnight | After goodnight |
|---|---|---|
| **It's 11 PM and Claude is running** | Stay up and babysit, OR go to bed with Mac awake | Type `goodnight`, close laptop, go to bed |
| **Mac overnight** | Fans on, battery draining, hot to touch | Sleeping quietly at 3% extra drain |
| **Waking up** | Laptop is warm, battery at 40%, Claude finished 5 hours ago | Laptop is cool, battery at 94%, Claude's result waiting |
| **Trust** | "Did I leave it on? Did it finish?" | "I know exactly what happened — it's in the log." |
| **Cost** | ~$0.10/night in electricity × 100 nights = real money | Negligible |

---

## 🏆 Section 4: Key Benefits

| Benefit | Who It Helps | Impact |
|---|---|---|
| ⏱️ **Automatic sleep the instant Claude finishes** | Late-night coders, async-task users | Saves hours of wasted machine time per week |
| 🔋 **Protects your battery** | MacBook users away from power | Cuts overnight battery drain by ~90% |
| 💰 **Cuts electricity waste** | Everyone — especially long-task runners | Avoids 6–10 hours of idle high-CPU state per task |
| 🧠 **Peace of mind with preflight audit** | Anyone worried about leaving their Mac unattended | Tells you before you walk away whether sleep will actually succeed — no surprises |
| 🛠️ **Zero config, one-liner install** | Non-technical users, ops teams, first-timers | Copy one `curl` command → working tool in ~5 seconds |
| 📋 **Full audit log of what happened** | Debuggers, paranoid users, ops teams | Every event (started watching, Claude finished, sleep attempted) written to a log file you can read the next morning |
| 🔍 **Machine-readable JSON output** | Automation, CI, power users | Feed the preflight verdict into scripts, dashboards, or other tools |
| 🔒 **Security-hardened installer** | Anyone pasting `curl | bash` into their shell | Size checks, marker checks, and optional SHA-256 pinning; users who need stronger provenance can pin both URL and hash |

---

## 🎯 Section 5: Project Objectives

1. **Sleep the Mac automatically when a watched Claude Code process exits**, with a one-word invocation (`goodnight`), for all macOS users — measurable by `pmset sleepnow` being issued within 1 second of process exit.
2. **Predict whether sleep will actually succeed before the user walks away**, for anyone running long tasks, by parsing `pmset -g assertions` and rendering a clear verdict (clear / display-only / hard blockers).
3. **Fail loudly, never silently**, for users relying on the preflight scan — when the scan can't complete, emit "scan unavailable" (not a false "clear"). Guaranteed by `tests/preflight-fail-closed.bats`.
4. **Make `curl | bash` installation frictionless but auditable**, for developers adopting the tool, by supporting optional commit-pinned URLs and SHA-256 pinning via environment variables.
5. **Prevent silent distribution drift**, for all future users, by enforcing that the embedded installer payload stays byte-identical to the standalone script — enforced by `scripts/check-parity.sh` and a pre-commit hook.
6. **Never false-positive a PID reuse**, for long-running Claude sessions, by comparing only the process's binary path (not the full argv string) when detecting whether the target PID was reused by a different process.
7. **Emit durable, inspectable logs**, for post-incident debugging, with a warn-once stderr signal when the log file can't be written so users know durability is broken before they walk away.

---

## 👥 Section 6: Who Is This For? (User Personas)

> **Priya — The Late-Night Refactorer**
>
> **Role:** Senior engineer at a SaaS startup.
> **Pain Point:** She kicks off big migrations with Claude Code at 10 PM. She either sleeps badly because she's listening for the fan to stop, or she leaves her laptop plugged in and warm all night.
> **How goodnight helps her:** She types `goodnight`, closes the lid, and goes to bed. She checks the log file with her morning coffee.

> **Marcus — The DevOps Power User**
>
> **Role:** Platform engineer. Runs Claude Code on a Mac mini in a closet as part of his infra.
> **Pain Point:** The Mac mini has no screen. He can't visually check whether Claude is done. He needs programmatic signals.
> **How goodnight helps him:** He calls `goodnight --preflight --json` in his scripts. He parses `can_sleep` and `scan_ok` to decide whether to trigger sleep or alert Slack.

> **Aisha — The Battery-Conscious Student**
>
> **Role:** CS student with a MacBook Air, no AC power in her dorm.
> **Pain Point:** She runs long Claude tasks for her thesis work. Her battery is dying because her Mac stays awake when she wants to sleep.
> **How goodnight helps her:** She installs goodnight once with `curl | bash`. Now every Claude session is followed by automatic sleep — saving hours of battery every week.

> **Jordan — The Skeptical Security-Aware Dev**
>
> **Role:** Senior staff engineer who refuses to run `curl | bash` blindly.
> **Pain Point:** Wants to install third-party tools, but also wants provenance and verification.
> **How goodnight helps them:** They pin to a specific commit SHA and verify via `SLEEP_AFTER_CLAUDE_INSTALLER_SHA256`. The installer refuses to proceed if the download doesn't match the expected hash.

---

## 🗺️ Section 7: How It Works (Visual Overview)

```mermaid
flowchart LR
  A[User runs 'goodnight'] --> P{On battery?}
  P -->|Yes| W[Wait for AC]
  W --> U[Self-update check]
  P -->|No / AC| U
  U --> M{Hooks installed?}
  M -->|Yes| S[--smart: markers + transcript activity]
  M -->|No| S2[--smart: transcript activity only]
  S --> C{Preflight clear?}
  D --> C
  C -->|Scan failed or blockers| E{User confirms?}
  E -->|Yes or --force| L[Acquire concurrent-run lock]
  E -->|No| X[Abort — Mac stays awake]
  C -->|Clear| L
  L --> WL[Watch loop]
  WL -->|Idle / Claude exited| F[Release caffeinate]
  F --> G[pmset sleepnow]
  G --> Z((💤 Mac sleeps))
```

**Step-by-step walkthrough (default flow):**

1. **Start goodnight.** You type `goodnight` in your terminal.
2. **Pass the power check.** If you're on battery, goodnight shows a "please plug in" card and waits for the charger. Use `--allow-battery` to skip this gate.
3. **Check for updates** — only when asked. `--check-update` compares the local script hash with the remote script and offers to update if they differ. Skipped by default so an unattended run can't stall on the prompt.
4. **Choose the watch mode.** Smart mode, always. If the Claude Code hooks are missing or damaged, goodnight repairs them; if it can't, it falls back to watching agent transcript activity directly and says so. (`--pid`, `--wait-for-start`, and `--watch-pid` select legacy process-exit watching explicitly.)
5. **Run preflight.** Goodnight checks whether anything else on your Mac would block sleep, such as backup jobs, screen sharing, or USB devices.
6. **Acquire the lock.** If everything is clear, goodnight acquires a mutual-exclusion lock so two concurrent `goodnight` invocations cannot race.
7. **Wait for every agent to finish.** Goodnight watches until no Claude session is busy *and* no agent — Claude Code or Codex — has written any output for `--idle` (default 5 minutes), then sleeps. A session that crashed or is parked on a permission prompt stops counting after `--stale` (default 15 minutes). A hard `--timeout` (default 6h) applies regardless.
8. **Release keep-awake helpers.** Goodnight releases any `caffeinate` helpers it started.
9. **Start sleep.** Goodnight issues `pmset sleepnow`.
10. **Write the log.** The full sequence is written to `~/.local/state/sleep-after-claude.log` (on by default; `--no-log` opts out, and the file rotates at 2 MB). Render it later with `goodnight --log-summary`.

---

## 🏗️ Section 8: Architecture & Tech Stack (Explained Simply)

### Components

| Component | Technology | What It Does (Plain English) | Why We Chose It |
|---|---|---|---|
| **Core tool** | Bash script (`sleep-after-claude`) | The single file that does all the work — watches, audits, sleeps your Mac | Bash ships on every Mac. Zero install step, zero runtime dependency |
| **Installer** | Self-extracting Bash (`install-sleep-after-claude.sh`) | The file that `curl | bash` downloads. Extracts the tool to `~/bin`, wires up the `goodnight` alias, SHA-pins and installs `jq`, and sets up Claude Code hooks | A single-file installer users can read before running |
| **Claude Code hooks** | `~/.claude/settings.json` + `jq` | Populates a busy-marker directory so `--smart` mode can detect idle sessions without waiting for the `claude` process to exit | Works for interactive REPLs; doesn't rely on any public Claude Code API |
| **Process detection** | macOS `pgrep` + `ps` | Finds the running Claude Code process by name (used by `--watch-pid`, `--list`) | Built into macOS — no new dependency |
| **Sleep predictor** | macOS `pmset -g assertions` | Reads the OS's list of "things that want to stay awake" so we can predict whether sleep will succeed | Official Apple API, machine-parseable |
| **Power gate** | macOS `pmset -g batt` | Waits for AC before spending battery on a long watch; shows a styled "plug me in" panel while waiting | Protects laptop battery without surprising the user |
| **Sleep trigger** | macOS `pmset sleepnow` (with `osascript` fallback) | The command that actually puts the Mac to sleep | Official, supported, no flags or tricks |
| **Self-update** | `curl` + `shasum` + `exec` | On `--check-update`, compares local ↔ remote SHA-256 and re-execs into the new binary preserving argv | Fails open; never blocks offline users |
| **Liveness** | Claude + Codex session-log mtimes | Detects agent activity without hooks, as a safety net under the hook-driven markers | Needs no cooperation from the agent and can't be silently uninstalled |
| **Sleep verification** | `sysctl kern.sleeptime` | Confirms the Mac actually slept, since `pmset sleepnow` reports success either way | The only signal that moves if and only if the machine slept |
| **Concurrent-run lock** | `mkdir`-as-atomic-lock at `~/.local/state/goodnight/lock` | Prevents two concurrent `goodnight` invocations from racing on caffeinate release and `pmset sleepnow` | macOS bash has no `flock`; `mkdir` is atomic across processes |
| **Shell integration** | Your `~/.zshrc` or `~/.bash_profile` | Adds the `goodnight` alias + `~/bin` on `PATH` | Standard shell practice |
| **Optional TUI polish** | [`gum`](https://github.com/charmbracelet/gum) / [`glow`](https://github.com/charmbracelet/glow) | Prettier confirm prompts, menus, panels, and markdown rendering when installed; silent fallback otherwise | Strictly optional — nothing breaks without them |
| **Test runner** | [bats-core](https://github.com/bats-core/bats-core) | Runs the regression test suite | De-facto standard for bash testing |
| **Parity guard** | `scripts/check-parity.sh` | Verifies the installer's embedded payload never drifts from the standalone script | Custom, tiny, auditable |
| **Logging** | Append-only text file | Writes a record of every important event to `~/.local/state/sleep-after-claude.log` | Simple, durable, greppable (category-groupable via `--log-summary`) |

### The Big Picture

```mermaid
flowchart TB
  subgraph User["Your Mac"]
    CLI[Terminal: 'goodnight']
    SAC[sleep-after-claude script]
    LOG[~/.local/state/<br/>sleep-after-claude.log]
    CLAUDE[Claude Code process]
    PMSET[macOS pmset API]
    CAFF[caffeinate processes]
    SLEEP[System Sleep]
  end

  subgraph Install["First-time install"]
    GH[GitHub raw URL]
    INST[install-sleep-after-claude.sh]
    RC[~/.zshrc or ~/.bash_profile]
  end

  CLI --> SAC
  SAC -->|poll every 100ms| CLAUDE
  SAC -->|reads assertions| PMSET
  SAC -->|kills when done| CAFF
  SAC -->|writes events| LOG
  SAC -->|pmset sleepnow| SLEEP

  GH -->|curl| INST
  INST -->|writes| RC
  INST -->|writes| SAC
```

Everything important happens locally on your Mac. goodnight has no telemetry, analytics, or server-side component. Network access is limited to installation, an optional one-time `jq` download, and the self-update check — which is **off by default**; ask for it with `--check-update`.

---

## 📸 Section 9: Terminal Tour

> **Note:** goodnight is a command-line tool. The current repository does not track static screenshot images; the commands below are the source of truth for the live terminal UI.

### 🖼️ The preflight audit

Run:

```bash
goodnight --preflight
```

The preflight view shows the target Claude process, any detected sleep assertions, power state, active user sessions, and a final verdict. If the scan fails, the verdict is "sleep-blocker scan unavailable" rather than a false "clear".

### 🖼️ The watch loop

Run:

```bash
goodnight
```

After the preflight gate clears, goodnight watches both the Claude Code hook busy markers and agent transcript activity, and sleeps once both have been quiet for `--idle`. Interactive terminals show a spinner; non-interactive output degrades to periodic plain status lines.

### 🖼️ The completion path

When the watched work finishes, goodnight releases the captured `caffeinate` processes, respects `--dry-run` / `--caffeinate-only`, waits the configured `--delay`, and calls `pmset sleepnow` with an AppleScript sleep fallback.

### 🖼️ The JSON preflight

Run:

```bash
goodnight --json --preflight
```

Passing `--json` emits a machine-readable preflight report. The `scan_ok`, `can_sleep`, `blockers[]`, and `power.*` fields are stable and meant for scripts — consumers must treat `can_sleep: null` as "unknown", not "safe".

---

## ✨ Section 10: Features (Detailed)

#### 🎯 Core behavior

- [x] **Smart-mode idle detection** — the default. Sleeps when every Claude session has returned to idle, not when the `claude` process exits. Works for interactive REPLs.
- [x] **Two independent liveness signals** — hook-written busy markers *and* agent session-log activity. Both must be quiet before the Mac sleeps, so a broken hook can't cause a premature sleep and a missing hook can't prevent one.
- [x] **Notices agents that are working silently** — a build or test run writes nothing to its session log while it runs, so goodnight also watches CPU across live `claude`, `codex`, `aider`, `gemini`, `opencode` and `cursor-agent` processes. It can only ever keep the Mac awake longer, never sleep it sooner.
- [x] **Watches Codex too, not just Claude Code** — busy markers only describe Claude sessions, so a Claude-only watch would sleep the Mac on top of a running Codex job. Both `~/.claude/projects` and `~/.codex/sessions` are scanned; add more with `SAC_EXTRA_ACTIVITY_DIRS`.
- [x] **Self-repairing hooks** — a damaged `~/.claude/settings.json` integration is detected and fixed in place rather than silently disabling idle detection.
- [x] **Verified sleep** — `pmset sleepnow` reports success even when macOS refuses. goodnight confirms against the kernel and retries, and tells you when it couldn't.
- [x] **Stands down if you sleep the Mac yourself** — close the lid mid-watch and goodnight notices on wake and exits, instead of putting the machine straight back to sleep in your hands.
- [x] **`--doctor`** — one command that reports whether the whole thing will actually work tonight. Exits non-zero when degraded, so it works as a health check.
- [x] **Process-exit watching** — `--watch-pid` sleeps when the `claude` process dies. Use for non-interactive Claude invocations.
- [x] **Sleep-now shortcut** — `--sleep-now` skips detection entirely: preflight + handle blockers + sleep immediately.
- [x] **Auto-detect Claude Code process** — uses a two-tier `pgrep` scan that avoids false-positives from Electron-based apps.
- [x] **Watch loop with low CPU usage** — uses Bash's built-in `read` with a FIFO to avoid forking `/bin/sleep` every tick.
- [x] **Configurable grace delay** — `--delay <seconds>` for a gentle buffer before sleep.
- [x] **Maximum-time safety net** — `--timeout <hours>` forces sleep after N hours (default 6) even if Claude is somehow stuck.
- [x] **PID-reuse detection** — compares the binary path every 30 seconds to catch PID recycling without false-flagging legitimate argv changes.
- [x] **Concurrent-run lock** — two goodnight invocations can't race on caffeinate release; the second one refuses and points at the live holder's PID.

#### 🧪 Audit & inspection

- [x] **Preflight scan** — parses `pmset -g assertions`, `pmset -g`, `who`, `ioreg`, and battery state to predict whether sleep will succeed.
- [x] **Fail-closed on scan failure** — if `pmset` is broken or rate-limited, the verdict flips to "scan unavailable" (never a false green light).
- [x] **Human-readable verdict** — rich colorized output with system-daemon classification.
- [x] **Brief mode** — `--brief` shows just the target + verdict for quick checks.
- [x] **JSON output** — `--json` emits a fully-structured preflight report for automation.
- [x] **List mode** — `--list` shows what processes goodnight would and wouldn't watch, so you can pick manually with `--pid`.

#### 🔧 Modes & safety

- [x] **Dry-run** — `--dry-run` does everything except actually sleep the Mac.
- [x] **Caffeinate-only** — `--caffeinate-only` releases caffeinate but lets macOS handle sleep on its own idle timer.
- [x] **Auto-start caffeinate** — `--no-auto-caffeinate` opts out when you manage caffeinate yourself.
- [x] **Power-state gate** — on battery, goodnight waits for the charger to be plugged in before kicking off a long watch. `--allow-battery` (or `--force`) bypasses.
- [x] **Skip preflight** — `--no-preflight` for when you've already audited your system.
- [x] **Force mode** — `--force` (a.k.a. `--yes` / `-y`) bypasses confirmation prompts.
- [x] **Wait for Claude to start** — `--wait-for-start` polls for a Claude process to launch before watching.
- [x] **Custom PID** — `--pid <pid>` watches any arbitrary process, not just Claude.

#### 🔄 Self-update

- [x] **Opt-in update check** — `--check-update` compares the local script's SHA-256 to the remote canonical script and prompts on mismatch. Off by default: it ends in a blocking prompt, and a command you start before walking away must not stall on a question about itself.
- [x] **Exec-into-new-binary** — after an in-place update accepted mid-session, goodnight `exec`s the fresh script with your original arguments preserved.
- [x] **Fails open** — offline, rate-limited, or non-TTY contexts silently skip; never blocks normal use.
- [x] **Manual control** — `--check-update` runs the check now and busts the 24h cache; `SAC_SKIP_UPDATE_CHECK=1` is a hard override that suppresses it even then.

#### 🪝 Claude Code hook integration

- [x] **Zero-touch installer** — `~/.claude/settings.json` is populated with `UserPromptSubmit` and `Stop` hooks during install (unless `SAC_SKIP_HOOK_INSTALL=1`).
- [x] **Opt-out / manual install** — `goodnight --install-hooks` / `--uninstall-hooks` work at any time, idempotently. Existing user-defined hooks are preserved.
- [x] **Survives home-dir moves** — hook command strings lazy-expand `$HOME` at hook-runtime, not at install-time.
- [x] **Stale-marker reaper** — a busy marker is dropped once its session's transcript has been silent past `--stale` (default 15 minutes, override via `SAC_STALE_MARKER_MINUTES`). Because staleness is corroborated against real activity rather than the marker's own age, a long-running task is never reaped mid-work.

#### 📢 Notifications & logging

- [x] **macOS notification** — `--notify` displays a native notification when Claude finishes.
- [x] **Completion sound** — plays `/System/Library/Sounds/Glass.aiff` on finish (`--no-sound` to disable).
- [x] **Append-only log, on by default** — every event lands in `~/.local/state/sleep-after-claude.log`, rotated at 2 MB. A command that sleeps your Mac while you're asleep should never leave you with nothing to read in the morning. `--no-log` opts out.
- [x] **Custom log path** — `--log-file <path>` redirects events elsewhere.
- [x] **Pretty log summary** — `--log-summary` groups events by category and renders via `glow` (falls back to plain text).
- [x] **Warn-once on log-write failure** — you'll see a stderr warning the first time logging breaks, then silent.

#### 🛡️ Installer safety

- [x] **Piped-install detection** — the installer detects `curl | bash` mode and re-downloads itself to a temp file to extract the payload.
- [x] **Size envelope check** — rejects payloads smaller than 2KB or larger than 512KB (defends against HTML error pages).
- [x] **Marker verification** — refuses to proceed without `__SCRIPT_START__` / `__SCRIPT_END__` tags.
- [x] **Optional SHA-256 pin** — `SLEEP_AFTER_CLAUDE_INSTALLER_SHA256` verifies the download against a known hash.
- [x] **SHA-pinned `jq` auto-install** — the installer fetches a static `jq` binary from `github.com/jqlang/jq`, checks its SHA-256 against a pinned hash per arch, and refuses mismatches. Override via `SAC_JQ_SHA256`.
- [x] **Bounded stdin drain** — the piped-install exit path drains the rest of its own stdin behind a 5s watchdog so `curl | bash && next_cmd` chains don't hang if the CDN trickles.
- [x] **Alias dedupe on reinstall** — stale alias lines pointing to old paths are stripped before the fresh line is appended.
- [x] **PATH dedupe** — the installer won't accumulate duplicate `~/bin` entries on repeat runs.
- [x] **Unknown-shell gating** — fish / nushell users get explicit manual instructions instead of a silent fallback to `~/.zshrc`.
- [x] **Hook-install opt-out** — `SAC_SKIP_HOOK_INSTALL=1` suppresses the `~/.claude/settings.json` modification; installer announces clearly before touching it.
- [x] **Exit non-zero on verification fail** — `curl | bash && next_command` chains won't proceed with a broken install.

#### 🧪 Quality

- [x] **Full bats regression test suite** — one file per risk area, covering every remediated finding from the audit cycles. Live count via `bats tests/ --count`.
- [x] **Parity guard** — script that enforces the installer and standalone script match byte-for-byte.
- [x] **Pre-commit framework integration** — `.pre-commit-config.yaml` runs parity + shellcheck + shfmt + hygiene on every commit.
- [x] **GitHub Actions CI** — macOS runner enforces syntax, shellcheck, shfmt, parity, and bats on PRs and pushes to `main`.

#### 🗺️ Planned

- [ ] **Uninstall command** — one-shot removal of the binary, alias, and logs.
- [ ] **Sub-hour timeout units** — accept `--timeout 30m` instead of hours-only.
- [ ] **Caffeinate ownership check** — only kill `caffeinate` processes parented by Claude Code.
- [ ] **Immutable pinned release URL** — tagged GitHub Releases with baked-in SHA-256.

---

## 🚀 Section 11: Getting Started (Step-by-Step for Beginners)

### Prerequisites

You need **macOS** — any modern version works (tested on macOS 26.x / Darwin 25.x). Apple-silicon and Intel Macs are both supported.

| Requirement | Version | How to check | How to get it |
|---|---|---|---|
| macOS | Any recent version | `sw_vers -productVersion` | Any Mac |
| Bash or zsh | Any shipped version | `bash --version` | Pre-installed on macOS |
| `curl` | Any | `curl --version` | Pre-installed on macOS |
| Claude Code | Optional, but the whole point | `claude --version` | [claude.com/product/claude-code](https://claude.com/product/claude-code) |

You do **not** need Node, Python, Homebrew, or anything else.

### Installation

Open **Terminal** (Applications → Utilities → Terminal) and paste this one command:

```bash
curl -fsSL https://raw.githubusercontent.com/sambatia/goodnight/main/install-sleep-after-claude.sh | bash
```

**What this does, in plain English:**

1. Downloads the installer script from GitHub.
2. Verifies you're on macOS.
3. Creates `~/bin` if it doesn't exist (this is a standard "my personal tools" folder).
4. Extracts the `sleep-after-claude` program into `~/bin/sleep-after-claude`.
5. Adds a `goodnight` alias to your shell's config file (`~/.zshrc` or `~/.bash_profile`) and makes sure `~/bin` is on your `PATH`.
6. Auto-installs `jq` into `~/bin/jq` if it isn't already on your machine (SHA-pinned, so a tampered mirror is refused).
7. Installs Claude Code hooks into `~/.claude/settings.json` so `--smart` idle detection works on first run. Skip this step with `SAC_SKIP_HOOK_INSTALL=1`. (goodnight re-checks and repairs these on every run.)
8. Runs a quick health check to make sure the install worked.

When it finishes, you'll see: **"Installation complete 🌙"**.

### Verification

Close your Terminal window and open a new one (so your shell picks up the new alias), then run:

```bash
goodnight --help
```

You should see a help menu listing every flag. If you see "command not found", check the troubleshooting section below.

### Configuration (Environment Variables)

goodnight needs zero configuration for normal use. These are optional knobs:

| Variable | Required? | Description | Example Value |
|---|---|---|---|
| `SLEEP_AFTER_CLAUDE_INSTALLER_URL` | No | Override the installer source URL (useful for pinning to a commit SHA) | `https://raw.githubusercontent.com/sambatia/goodnight/<commit-sha>/install-sleep-after-claude.sh` |
| `SLEEP_AFTER_CLAUDE_INSTALLER_SHA256` | No | Require the downloaded installer to match a specific SHA-256 | `a41a6cfe20b6d4929cff4a5db00ad0c6...` |
| `SLEEP_AFTER_CLAUDE_UPDATE_URL` | No | Override the self-update source URL (same format as installer URL) | main-branch raw URL |
| `SAC_JQ_SHA256` | No | Override the expected SHA-256 for the auto-installed `jq` binary (for legitimate jq re-releases) | 64-hex hash |
| `SAC_SKIP_HOOK_INSTALL` | No | Set to `1` to tell the installer not to modify `~/.claude/settings.json` | `1` |
| `SAC_SKIP_UPDATE_CHECK` | No | Hard override that suppresses the update check even when `--check-update` is passed | `1` |
| `SAC_STALE_MARKER_MINUTES` | No | Minutes of transcript silence before a session stops counting as busy (default 15) | `30` |
| `SAC_IDLE_SECONDS` | No | Quiet period required before sleeping (default 300) | `600` |
| `SAC_SLEEP_MAX_ATTEMPTS` | No | Sleep attempts before reporting failure (default 3) | `5` |
| `SAC_EXTRA_ACTIVITY_DIRS` | No | Extra colon-separated roots to scan for agent session logs | `~/.myagent/logs` |
| `SAC_AGENT_CPU_BUSY_PCT` | No | Percent of one core above which an agent counts as working (default 20) | `35` |
| `SAC_EXTRA_AGENT_PROCESSES` | No | Extra agent process names for the CPU guard (space or comma separated) | `myagent,otheragent` |
| `SAC_NO_GUM` / `SAC_FORCE_GUM` | No | Force-off / force-on the `gum` TUI integration | `1` |
| `SAC_NO_GLOW` | No | Force-off the `glow` markdown-rendering integration | `1` |

There are no API keys, database URLs, or secrets. goodnight doesn't talk to any server after install (except the once-per-24h self-update check, which can be disabled).

### Running It

Start a Claude Code task in one terminal window. In **another** terminal window, run:

```bash
goodnight
```

You should see:

- A preflight audit (2–3 seconds)
- A verdict (usually "No active sleep blockers detected")
- A spinner saying "Waiting for PID 12345…"

Close your laptop lid, walk away, go to bed. When Claude finishes, the Mac sleeps.

### Useful variants

```bash
goodnight                      # Smart mode — wait for every agent, then sleep
goodnight --doctor             # Is this actually going to work tonight?
goodnight --idle 600           # Require 10 minutes of quiet instead of 5
goodnight --unattended         # Never prompt; every question takes its safe default
goodnight --watch-pid          # Legacy PID-exit watching
goodnight --sleep-now          # Skip the watch — preflight + sleep immediately
goodnight --preflight          # Just audit your system, don't watch or sleep
goodnight --dry-run            # Watch and detect, but don't actually sleep
goodnight --notify --log       # macOS notification + audit log
goodnight --pid 12345          # Watch a specific PID
goodnight --wait-for-start     # Wait for Claude to launch, then watch
goodnight --json --preflight   # Machine-readable output
goodnight --log-summary        # Render the session log as pretty markdown
goodnight --install-hooks      # Set up Claude Code hooks for --smart mode
goodnight --check-update       # Force an update check now (bypass the 24h cache)
```

<details>
<summary>🆘 Troubleshooting Common Issues</summary>

**"command not found: goodnight"**

Your shell hasn't loaded the new alias. Either open a new terminal window, or run `source ~/.zshrc` (or `source ~/.bash_profile`).

---

**"awk: can't open file bash" during install**

The GitHub CDN is serving a stale cached copy of the installer (up to 5 minutes). Bust the cache:

```bash
curl -fsSL "https://raw.githubusercontent.com/sambatia/goodnight/main/install-sleep-after-claude.sh?v=$(date +%s)" | bash
```

---

**"No Claude process found. Is Claude Code running?"**

goodnight can't find a running `claude` or `claude-code` process. Either start Claude first, or pass `--wait-for-start` to have goodnight poll until Claude launches.

---

**"Sleep blockers detected"**

Something on your Mac is telling macOS to stay awake — commonly Time Machine, a backup tool, screen-sharing, or a video call app. The preflight lists the exact process. Quit the blocker, or pass `--force` if you know it's safe.

---

**"Checksum mismatch" during install**

You set `SLEEP_AFTER_CLAUDE_INSTALLER_SHA256` but the downloaded installer doesn't match. Either your pinned hash is wrong, or the installer at that URL has changed. Re-pin to the current hash or remove the variable.

---

**Mac doesn't actually sleep after Claude finishes**

Check `~/.local/state/sleep-after-claude.log` for a `SLEEP_FAILED` entry — it names the processes that held the sleep assertion across all retries. Re-run with `--preflight` to see the current blocker list — the most common cause is a background app (Zoom, Discord, backup) acquiring a sleep assertion after goodnight started watching.

---

**Unknown-shell users (fish, nushell)**

The installer skips the alias step and tells you the manual line to add. For fish, put this in `~/.config/fish/config.fish`:

```fish
alias goodnight "$HOME/bin/sleep-after-claude"
```

---

**"Running without Claude hook markers"**

goodnight couldn't repair the hooks in `~/.claude/settings.json` — usually because `jq` isn't on `PATH`. It falls back to watching agent transcript activity, which still works but notices a finished turn less promptly. Run `goodnight --doctor` for the specific reason, then `brew install jq && goodnight --install-hooks` if that's the cause.

Note that repaired hooks only apply to Claude Code sessions started *afterwards* — a session already running has its hook config loaded.

---

**Which agents does it actually watch?**

| Signal | Claude Code | Codex | aider · gemini · opencode · cursor-agent | anything else |
|---|---|---|---|---|
| Busy markers | ✅ | — | — | — |
| Session-log writes | ✅ | ✅ | — | — |
| CPU activity | ✅ | ✅ | ✅ | — |

Claude Code is fully covered — a long tool call holds its marker for the whole turn. The others are covered whenever they're writing or computing, which is nearly always. Add more with `SAC_EXTRA_AGENT_PROCESSES` (CPU) and `SAC_EXTRA_ACTIVITY_DIRS` (logs).

**It slept while an agent was still working**

Three signals have to agree it's idle: no busy marker, no session-log writes, and no agent burning CPU. A build or test run trips the third even when it's silent, so the usual culprit is an agent that was neither writing nor computing — blocked on a long network call, say. Nothing observable tells that apart from finished. Raise the window for long jobs:

```bash
goodnight --idle 1800        # half an hour of quiet required
```

**goodnight is waiting and I don't know what for**

Run `goodnight --doctor` in another terminal. It reports how many sessions are still marked busy, how long ago any agent last wrote output, and what's holding sleep. A session that has genuinely stalled stops counting after `--stale` minutes.

---

**"Another goodnight is already running (PID X)"**

A previous `goodnight` invocation is still holding the concurrent-run lock. Either wait for it to finish or `kill X`. Stale locks (dead holder PID) are auto-reclaimed on the next attempt.

---

**"Please connect your charger" panel when you want to proceed on battery**

goodnight waits for AC power by default to protect your laptop battery. Pass `--allow-battery` (or `--force`) to bypass.

---

**goodnight wants to update mid-session and you don't want it to**

Nothing — the update check is off by default. It only runs when you pass `--check-update`, and `SAC_SKIP_UPDATE_CHECK=1` suppresses it even then.

</details>

---

## 📁 Section 12: Project Structure

```
goodnight/
├── sleep-after-claude                  # The tool (standalone)
├── install-sleep-after-claude.sh       # Self-extracting installer
├── scripts/
│   └── check-parity.sh                 # Verifies installer payload matches standalone
├── .githooks/
│   └── pre-commit                      # Legacy parity hook (superseded by pre-commit framework)
├── .pre-commit-config.yaml             # Canonical lint pipeline (parity + shellcheck + shfmt + hygiene)
├── tests/                              # bats-core regression suite — one file per risk area
│   ├── *.bats                          # see "What the tests cover" table below
│   ├── lib/
│   │   └── common.bash                 # Shared helpers (sandbox, shims, asserts)
│   └── fixtures/
│       └── pmset-assertions-*.txt      # Real captured pmset output for shimmed tests
├── README.md                           # This file
└── CLAUDE.md                           # Agent + architecture knowledge
```

### File-by-file guide

| Path | Purpose |
|---|---|
| `sleep-after-claude` | The actual tool users run. Single-file Bash script with labeled section banners (`# ── Section ──`). Run `bash -n` to syntax-check. |
| `install-sleep-after-claude.sh` | The installer users `curl | bash`. Embeds a byte-identical copy of `sleep-after-claude` between marker lines. Also auto-installs `jq` (SHA-pinned) and Claude Code hooks unless opted out. |
| `scripts/check-parity.sh` | Extracts the embedded payload and diffs it against the standalone. Exits 0 on match, non-zero with diff on drift. |
| `.githooks/pre-commit` | Legacy parity-only hook. Superseded by the `pre-commit` framework below. |
| `.pre-commit-config.yaml` | Canonical pre-commit config. Enable with `pre-commit install`. Runs parity + shellcheck + shfmt + repo hygiene on every commit. |
| `tests/*.bats` | bats-core test files. One file per risk area. Each test's name references the audit finding it protects. |
| `tests/lib/common.bash` | Shared helpers: `setup_sandbox`, `shim`, `shim_fixture`, `assert_contains`. |
| `tests/fixtures/pmset-assertions-*.txt` | Real captured output from `pmset -g assertions`. Used to feed shimmed `pmset` binaries in tests. |
| `CLAUDE.md` | Context for AI agents working on this repo (but readable by humans too). Architecture, conventions, audit-cycle history. |
| `README.md` | You are reading it. |

---

## 🔌 Section 13: API Reference

> **This project does not expose a network API.** goodnight is a command-line tool that runs entirely on your local Mac and talks only to macOS system binaries.

If you're looking for the command-line flags (goodnight's equivalent of an API), they are:

**Watch modes** (`--smart` is always the default; the others must be asked for by name)

| Flag | Short | Description |
|---|---|---|
| `--smart` | — | Idle-aware watch (the default). Sleeps when no session is busy and no agent has written output for `--idle`. |
| `--idle <secs>` | `300` | Quiet period required before sleeping. |
| `--stale <mins>` | `15` | Transcript silence after which a session stops counting as busy. |
| `--unattended` | — | Never prompt; every question resolves to its safe default. |
| `--doctor` | — | Report live health of the whole integration, then exit. Non-zero when degraded. |
| `--no-repair` | — | Don't auto-repair degraded Claude Code hooks. |
| `--no-cpu-guard` | — | Don't treat agent CPU activity as a reason to stay awake. |
| `--watch-pid` | — | Legacy process-exit watching — sleep when the `claude` process dies. Use when running Claude non-interactively. |
| `--sleep-now` | — | Skip the watch entirely. Preflight + handle blockers + sleep immediately. |

**Watch options**

| Flag | Short | Description |
|---|---|---|
| `--pid <pid>` | `-p <pid>` | Watch a specific process ID instead of auto-detecting |
| `--timeout <hrs>` | `-t <hrs>` | Force sleep after N hours (default 6) |
| `--delay <secs>` | `-d <secs>` | Grace period before sleeping (default 1) |
| `--wait-for-start` | — | Poll until a Claude process launches |
| `--caffeinate-only` | — | Release caffeinate but don't sleep the Mac |
| `--no-auto-caffeinate` | — | Don't auto-start `caffeinate -dim` when none is running |
| `--dry-run` | — | Simulate (detect + wait, but don't sleep) |
| `--allow-battery` | — | Proceed even if the Mac is on battery (default: wait for AC) |

**Hook management**

| Flag | Short | Description |
|---|---|---|
| `--install-hooks` | — | Install or repair the Claude Code hooks in `~/.claude/settings.json` |
| `--uninstall-hooks` | — | Remove goodnight's Claude Code hooks, leaving any user-defined hooks in place |

**Inspection & output**

| Flag | Short | Description |
|---|---|---|
| `--list` | `-l` | Show what processes would be watched |
| `--preflight` | `-P` | Run preflight scan and exit |
| `--no-preflight` | — | Skip the preflight scan |
| `--log-summary` | — | Render the session log as pretty markdown (via `glow` if installed) |
| `--force` | `-f` / `--yes` / `-y` | Skip confirmation prompts on blockers and battery |
| `--brief` | `-b` | Terse preflight output (just the verdict) |
| `--json` | — | Emit preflight as JSON |
| `--no-sound` | — | Skip the completion sound |
| `--notify` | `-n` | Send a macOS notification when done |
| `--log` | — | Write events to the log file (already the default) |
| `--log-file <path>` | — | Custom log path (implies `--log`) |
| `--check-update` | — | Force an immediate update check (bypasses the 24h cache) |
| `--skip-update-check` | — | Accepted for compatibility; the check is already off by default |
| `--no-log` | — | Disable logging for this run (logging is on by default) |
| `--help` | `-h` | Show help and exit |

### JSON output schema

The `--json` preflight emits this shape:

```json
{
  "target": { "pid": 12345, "command": "claude ..." } | null,
  "excluded": [{ "pid": 999, "command": "..." }],
  "caffeinate_pids": [111, 222],
  "assertions": [{ "severity": "blocker|system|display|user|release", "pid": N, "name": "...", "type": "..." }],
  "blockers": [{ "pid": N, "name": "...", "type": "..." }],
  "power": { "battery_percent": "94%", "battery_source": "Battery", "system_sleep_min": "1", "display_sleep_min": "2", "hibernate_mode": "3", "lid": "open|closed|unknown" },
  "scan_ok": true,
  "can_sleep": true | false | null,
  "blocker_count": 0
}
```

`can_sleep` is **`null`** when `scan_ok` is `false` — consumers must not treat this as "ok to sleep".

---

## 🧪 Section 14: Testing

### How to run tests

```bash
bats tests/                    # Run the full suite
bats tests/parity.bats         # Run a single file
bats tests/ --count            # Print the live test count
bash scripts/check-parity.sh   # Verify embedded payload parity
bash -n sleep-after-claude     # Syntax-check the tool
```

You need [bats-core](https://github.com/bats-core/bats-core) installed:

```bash
brew install bats-core
```

### What the tests cover

| Test file | What it protects |
|---|---|
| `parity.bats` | Parity guard passes clean, fails on drift, fails on missing markers |
| `installer-trust-chain.bats` | Piped install: warn message, size envelope, marker check, SHA-256 pin (match + mismatch) |
| `installer-consent-and-exec.bats` | Installer hook-install opt-out + self-update re-exec contract |
| `installer-alias-and-shell.bats` | Fresh install = one alias; reinstall replaces stale alias; fish shell skips alias; verification failure exits non-zero |
| `installer-deps.bats` | `jq` auto-install: already-installed short-circuit, offline-safe degradation, presence of `ensure_jq` guards |
| `installer-jq-rejection.bats` | `jq` SHA-256 mismatch → hard refusal; matching hash allows install |
| `preflight-fail-closed.bats` | `scan_ok=false` + `can_sleep=null` on pmset failure; correct values on clear/blocker fixtures; JSON always valid |
| `blocker-classification.bats` | Severity-bucket assignment + interactive termination hint rendering |
| `power-gate.bats` | Battery vs AC vs Unknown power-state handling with a shimmed `pmset` |
| `auto-caffeinate.bats` | `ensure_caffeinate_running` leaves existing caffeinate alone, starts one when missing, respects `--no-auto-caffeinate` |
| `hooks.bats` | `--install-hooks` / `--uninstall-hooks` idempotency; smart-watch primitive |
| `hook-command-runtime.bats` | Hook command strings evaluate correctly in a fresh shell with an arbitrary `$HOME` (F-03 runtime) |
| `smart-watch-semantics.bats` | Cold-start guard, idle countdown, busy-marker state transitions (F-01 / F-08) |
| `smart-watch-runtime.bats` | Full `smart_watch_loop` behavior driven with scripted `BUSY_DIR` |
| `default-mode.bats` | Default-mode selection: `--smart` when hooks installed, `--watch-pid` otherwise |
| `concurrent-lock.bats` | Lock acquire / stale-lock reclaim / release contract (F-07) |
| `concurrent-lock-runtime.bats` | Two real racing bash subprocesses — exactly one wins |
| `trap-and-drain.bats` | `on_interrupt` doesn't double-call cleanup (F-12); installer stdin drain bounded (F-11) |
| `update-check.bats` | Self-update rate-limit, fail-open, TTY prompt, re-exec contract |
| `log-event.bats` | Write success; warn-once on first failure; silent when disabled; no raw shell error leak |
| `pid-reuse-compare.bats` | Binary extraction correctness; argv mutation doesn't trigger reuse; different binary does trigger reuse (F-10) |

### How to read the output

bats prints one line per test:

```
ok 1 F-04: parity check passes on the committed tree
ok 2 F-04: parity check fails when embedded payload drifts
not ok 3 F-05: JSON reports scan_ok=true ...
#   (in test file tests/preflight-fail-closed.bats, line 52)
```

A line starting with `ok` passed; `not ok` failed (with an error trace). The numbers in test names (e.g., `F-04`, `F-05`) reference audit findings — a failing test tells you exactly which fix regressed.

---

## 🚢 Section 15: Deployment Guide

"Deployment" for goodnight means **publishing a new version users can install via `curl | bash`**. Since the tool runs locally on end-user Macs, there's no server to deploy.

### Release checklist

- [ ] 1. Make your code changes in `sleep-after-claude` **and** mirror them into the embedded payload of `install-sleep-after-claude.sh`.
- [ ] 2. Run `bash scripts/check-parity.sh` — must output `check-parity: OK`.
- [ ] 3. Run `bats tests/` — all tests must pass.
- [ ] 4. Run `bash -n sleep-after-claude install-sleep-after-claude.sh` — syntax check.
- [ ] 5. Smoke-test the installer in a sandbox: `HOME=/tmp/test SHELL=/bin/zsh bash install-sleep-after-claude.sh`.
- [ ] 6. Commit with a message referencing any finding IDs or change summary.
- [ ] 7. Push to `main` on GitHub.
- [ ] 8. Wait ~5 minutes for the raw.githubusercontent.com CDN cache to expire (or document the cache-bust URL for early adopters).
- [ ] 9. (Recommended) Tag a GitHub Release so users can pin via `SLEEP_AFTER_CLAUDE_INSTALLER_URL=<raw-url-at-tag>`.

### Environment-specific notes

| Environment | Notes |
|---|---|
| **Local dev** | Run against your own Mac. Use `HOME=/tmp/sandbox` to test installer behavior in isolation. |
| **CI** | GitHub Actions runs syntax, shellcheck, shfmt, parity, and bats on macOS for PRs and pushes to `main`. |
| **Production (end-user Macs)** | Users get the tool via `curl | bash`. The GitHub raw URL is the production "server". |

---

## 🗺️ Section 16: Roadmap

### Phase 1 — Core functionality ✅ (Shipped)

- [x] Detect Claude Code process by name
- [x] Watch loop with low CPU footprint
- [x] Preflight scan + verdict
- [x] `pmset sleepnow` trigger
- [x] `curl | bash` installer
- [x] Shell alias integration (zsh, bash)

### Phase 2 — Audit-cycle hardening ✅ (Shipped — 2026-04-19)

- [x] Installer trust chain (size, markers, SHA-256 pin)
- [x] Parity enforcement (standalone ↔ embedded payload)
- [x] Preflight fails closed on scan failure
- [x] Alias dedupe + absolute paths on reinstall
- [x] Unknown-shell gating
- [x] Log-write warn-once
- [x] PID-reuse binary-only compare
- [x] Full bats regression suite

### Phase 3 — Smart-mode & operational polish ✅ (Shipped — 2026-04-20)

- [x] Claude Code hook integration (`--install-hooks` / `--uninstall-hooks`)
- [x] `--smart` idle-based watch as the default when hooks are present
- [x] `--sleep-now` fast path for "sleep immediately, don't wait"
- [x] Self-update check with exec-into-new-binary (rate-limited to 24h)
- [x] Concurrent-run mutual-exclusion lock
- [x] Power-state gate (waits for AC by default; `--allow-battery` override)
- [x] Auto-install `jq` with SHA-256 pin
- [x] `--log-summary` for pretty session-log rendering via `glow`
- [x] `gum` / `glow` TUI polish with graceful fallbacks
- [x] Bounded installer stdin drain (avoids `curl: (56)` noise on piped install)

### Phase 4 — Release hygiene & reach (Current focus)

- [x] GitHub Actions CI running bats on macOS runners
- [ ] Tagged GitHub Releases with immutable pinned URLs + baked-in SHA-256
- [ ] Uninstall command (`goodnight --uninstall`)
- [ ] Sub-hour timeout units (`--timeout 30m`)

### Phase 5 — Advanced features (Later)

- [ ] Caffeinate ownership filtering (only kill Claude-parented caffeinate)
- [ ] Preflight format adaptation to future macOS versions
- [ ] Homebrew tap for users who prefer `brew install`
- [ ] Linux support (if there's a real demand — tricky given sleep semantics)

---

## 🤝 Section 17: Contributing

### Reporting a bug

Open an issue on GitHub with:

- Your macOS version (`sw_vers -productVersion`)
- The exact command you ran
- What you expected to happen
- What actually happened
- (If relevant) the tail of `~/.local/state/sleep-after-claude.log`

### Suggesting a feature

Open an issue labeled `enhancement` describing:

- The problem you're trying to solve
- Your proposed behavior
- Any alternatives you considered

### Submitting a pull request

1. Fork the repo and create a feature branch.
2. Make your code changes in `sleep-after-claude`.
3. **Mirror the change into the embedded payload of `install-sleep-after-claude.sh`** — this is enforced.
4. Run `bash scripts/check-parity.sh` — must pass.
5. Add or update a test in `tests/*.bats` for any behavior change.
6. Run `bats tests/` — must pass.
7. Install the pre-commit suite once per clone (parity + shellcheck + shfmt + hygiene):
   ```bash
   brew install shellcheck shfmt bats-core pre-commit
   pre-commit install
   ```
   All subsequent `git commit` invocations will auto-lint.
8. Commit with a descriptive message.
9. Open the PR against `main`.

### Code style

- Bash, `set -uo pipefail` (not `-e` — by design).
- Formatted with `shfmt -i 2 -ci`.
- Linted with `shellcheck -S warning`. Intentional suppressions must include a reason.
- All user-facing output goes through the `print_*` helpers.
- Section banners (`# ── Section ──`) to navigate long scripts.
- No tabs.
- See `CLAUDE.md` for the full convention list.

---

## 📄 Section 18: License

This project is released under the **MIT License** — see [`LICENSE`](./LICENSE) for the full text. You're free to use, modify, redistribute, and build on goodnight in both personal and commercial contexts, subject to preserving the copyright notice.

---

## 🙏 Section 19: Acknowledgments

- **Apple** — for `pmset`, `caffeinate`, `pgrep`, and the rest of the macOS toolchain this project is built on.
- **[bats-core](https://github.com/bats-core/bats-core)** — the bash testing framework that makes this project's regression suite possible.
- **[Anthropic](https://www.anthropic.com/)** — for Claude Code, without which there'd be no "wait for Claude to finish" problem to solve.
- **Claude Code** — which assisted the audit → remediation → test → docs cycle that hardened this project into its current shape.

Built with late-night frustration and way too much respect for battery life.

— *goodnight. 🌙*
