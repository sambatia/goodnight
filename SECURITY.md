# Security Policy

## Supported versions

This project ships from `main` as a rolling release via `curl | bash`. Security fixes are applied to `main` and immediately available to new installs. There are no backported maintenance branches.

| Version | Supported |
|---------|-----------|
| `main`  | ✅        |
| Any tagged release (if / when published) | ✅ until superseded |
| Older commits pinned via `SLEEP_AFTER_CLAUDE_INSTALLER_URL` | ⚠️ at-your-own-risk |

## Threat model (summary)

goodnight runs locally on macOS with the user's own privileges. It:

- shells out to `pgrep`, `ps`, `pmset`, `caffeinate`, `osascript`, `afplay`, `curl`, `shasum`, `jq`
- reads and writes `~/.claude/settings.json` (when hooks are installed), `~/.local/state/goodnight/`, `~/.cache/sleep-after-claude/`, and the user's shell rc file (at install time)
- makes outbound network requests to `raw.githubusercontent.com` for self-update and to `github.com/jqlang/jq/releases` for one-time `jq` auto-install
- has **no** server-side component, no telemetry, no analytics, no phone-home

In-scope concerns:

- supply-chain integrity of the `curl | bash` installer, the auto-downloaded `jq` binary, and the self-update payload
- safety of the hook command strings written into `~/.claude/settings.json`
- correctness of preflight fail-closed behavior (a green "sleep OK" verdict on a broken scan is a real security/data-loss issue)
- race conditions between concurrent `goodnight` invocations

Out of scope:

- physical access to an unlocked Mac
- root-level privilege escalation via bugs in `pmset` / `caffeinate` / macOS itself
- arbitrary-code-execution vulnerabilities in Claude Code or other unrelated software the user has installed

## Reporting a vulnerability

**Do not open a public GitHub issue for security problems.**

Preferred channel: use GitHub's private vulnerability reporting on this repository:

> [Security advisories → Report a vulnerability](https://github.com/sambatia/goodnight/security/advisories/new)

Alternative: open a minimal public issue titled "Security issue — please contact me privately" (no details) and the maintainer will reach out via your GitHub profile's visible contact channels.

Please include, where possible:

- a clear description of the issue
- the file, function, and ideally line numbers involved
- a reproduction or proof-of-concept
- the macOS version and bash version you were running
- whether you believe exploitation is likely in practice or only theoretical

## What to expect

- **Acknowledgement:** within 7 days.
- **Initial assessment:** within 14 days.
- **Fix timeline:** depends on severity. Critical issues that allow a remote attacker to substitute the installer payload, poison the `jq` binary, or bypass the preflight fail-closed contract are prioritized.
- **Credit:** reporters are credited in the commit message and release notes unless anonymity is requested.

## Hardening guidance for users

If you are particularly security-conscious:

- **Pin the installer URL to a specific commit SHA** via `SLEEP_AFTER_CLAUDE_INSTALLER_URL=https://raw.githubusercontent.com/sambatia/goodnight/<sha>/install-sleep-after-claude.sh`.
- **Pin the installer SHA-256** via `SLEEP_AFTER_CLAUDE_INSTALLER_SHA256=<hex>`. The installer refuses to proceed if the download doesn't match.
- Treat the default `curl | bash` path as HTTPS transport trust plus shape validation. The SHA pin is what turns installer-body substitution into a hard failure.
- **Opt out of automatic `jq` install** by pre-installing `jq` yourself (`brew install jq`); the installer detects existing `jq` and skips the download.
- **Opt out of Claude Code hook installation** via `SAC_SKIP_HOOK_INSTALL=1`.
- **Disable the self-update check** via `--skip-update-check` or `SAC_SKIP_UPDATE_CHECK=1`.
