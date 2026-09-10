# Public release checklist

**Status as of 2026-09-10:** the repo is public, `v0.2.0` is released, and every item that
could be verified from the CLI has been checked against live configuration rather than
assumed. The dozen that remain are either deliberate choices, matters of your judgment
(licence attribution), or settings only reachable through the GitHub web UI — each says
which. Re-verify with the commands named inline rather than trusting these boxes.

A living checklist for taking this repository from private/personal to cleanly public on GitHub. The **automated / local** section has already been handled in-repo by the `chore/public-release-hardening` branch — everything else requires human action in the GitHub UI (or maintainer judgment) and is listed explicitly.

---

## 1. Already handled locally ✅

These items shipped via `chore/public-release-hardening`. Nothing to do here unless you want to customize.

- [x] **`LICENSE`** — MIT, copyright Sameh Abdalla, 2026.
- [x] **`.gitignore`** — covers `.env*`, keys, OS junk, editor junk, logs, caches, `.claude/`, pre-commit cache, `node_modules/`, coverage.
- [x] **`CONTRIBUTING.md`** — setup, workflow, parity rule, style, bug-report guidance.
- [x] **`SECURITY.md`** — private-disclosure process, threat model, hardening guidance for users.
- [x] **`.github/ISSUE_TEMPLATE/bug_report.yml`** — structured bug form.
- [x] **`.github/ISSUE_TEMPLATE/feature_request.yml`** — structured feature form with scope checks.
- [x] **`.github/ISSUE_TEMPLATE/config.yml`** — disables blank issues; routes security reports privately.
- [x] **`.github/pull_request_template.md`** — PR form enforcing parity + test + hygiene checklist.
- [x] **`.github/dependabot.yml`** — weekly GitHub Actions version bumps.
- [x] **`.github/workflows/ci.yml`** — macOS runner: syntax + shellcheck + shfmt + parity + bats on every PR and push to `main`.
- [x] **Installer file-header** — documents all 9 install steps + env-var overrides (already landed in `main`).
- [x] **Sensitive-data scan** — no secrets, tokens, or hardcoded user paths found in tracked files.

No `CODE_OF_CONDUCT.md` is included. The project is small-surface; a formal code of conduct adds maintenance burden without materially improving contributor quality at this scale. Add one if / when the project grows enough community that moderation needs a written standard.

---

## 2. Manual GitHub UI configuration required

Do these **before** flipping the repo to public (or immediately after). Order matters for a few of them.

### 2a. Repo → Settings → General

- [x] **Description** — one-liner. Suggested: *"macOS Bash utility that watches a Claude Code session and sleeps your Mac when it finishes."*
- [ ] **Website** — optional. If you don't have a landing page, leave blank.
- [x] **Topics** — suggested: `macos`, `bash`, `cli`, `claude-code`, `developer-tools`, `power-management`, `sleep`.
- [x] **Features:**
  - [x] Issues — **enabled**.
  - [ ] Projects — currently **on**. Left as-is: turning it off is only worth doing if you are sure no board is in use.
  - [x] Discussions — **enable** (the issue-template `config.yml` already links to the Discussions URL). Alternative: remove the Discussions link from `.github/ISSUE_TEMPLATE/config.yml`.
  - [x] Wiki — disable (README + CLAUDE.md are the canonical docs).
- [x] **Pull Requests:**
  - [x] Allow squash merging — **on** (preferred default merge).
  - [x] Allow merge commits — off (keeps history flat).
  - [x] Allow rebase merging — off.
  - [x] **Automatically delete head branches** after merge — **on**.
  - [ ] Default to PR title for squash-merge commit message — **on** (cleaner history).
- [ ] **Archives** — leave defaults.

> **Two toggles are UI-only — confirmed, not assumed.** `secret_scanning_non_provider_patterns`
> and `secret_scanning_validity_checks` are both still `disabled`. A correctly-shaped
> `PATCH /repos/{owner}/{repo}` with those keys under `security_and_analysis` is rejected
> outright:
>
> ```
> HTTP 422 — Invalid security_and_analysis payload.
> ```
>
> The looser `-f 'security_and_analysis[...][status]=enabled'` field syntax is worse: it
> returns success and silently changes nothing, which is how this was first mis-recorded
> as "accepted but ignored". Neither is a permissions problem — the token carries `repo`.
>
> Both are free on public repos and widen coverage (generic secret shapes beyond known
> providers; checking whether a found secret is still live). Enable by hand at
> *Settings → Code security and analysis*.

### 2b. Repo → Settings → Code security and analysis

Enable all of these:

- [x] **Dependabot alerts** — on.
- [x] **Dependabot security updates** — on.
- [x] **Dependency graph** — on.
- [x] **Secret scanning** — on (GitHub will scan both current code and historical commits).
- [x] **Secret scanning — push protection** — on.
- [ ] **Code scanning** — this project is pure Bash. GitHub's CodeQL does not support bash as a first-class language, so CodeQL is not enabled. If you later add any JavaScript, Python, Go, etc., enable CodeQL at that point. The `shellcheck` job in `.github/workflows/ci.yml` is the effective static-analysis layer for the bash code.

### 2c. Repo → Settings → Rules → Rulesets (or Branches → Branch protection)

Create one ruleset targeting `main` with:

- [x] **Require a pull request before merging** — on.
  - [ ] Require 1 approval — deliberately **0** in the live ruleset (solo maintainer). Note that `require_extra_approval_for_unattributed_changes` is on, so AI-co-authored commits still need a human approval or an admin bypass.
  - [x] Dismiss stale approvals when new commits are pushed — on.
  - [x] Require conversation resolution before merging — on.
- [x] **Require status checks to pass before merging** — on. Required checks (add after the first successful CI run so GitHub knows they exist):
  - [x] `Lint (shellcheck + shfmt + syntax)`
  - [x] `Parity (installer payload ↔ standalone)`
  - [x] `bats regression suite`
- [x] **Require branches to be up to date before merging** — on.
- [x] **Block force pushes** — on.
- [x] **Restrict deletions** — on (prevents accidental deletion of `main`).
- [ ] **Apply to administrators / bypass list is empty** — on (no bypass unless you really need it).
- [x] **Require linear history** — on (matches the squash-merge default above).

### 2d. Repo → Settings → Actions

- [x] **Actions permissions** — set to `selected` (the stricter of the two options), verified via `gh api repos/sambatia/goodnight/actions/permissions`. The CI workflow uses only `actions/checkout@v7` today.
- [x] **Workflow permissions → Read repository contents** — confirmed `default_workflow_permissions=read`, `can_approve_pull_request_reviews=false`. No write permissions needed for the current CI.
- [ ] **Fork pull request workflows from outside collaborators** — "Require approval for all outside collaborators" is the safe default.

### 2e. Repo → Security → Private vulnerability reporting

- [x] **Enable** — so the `SECURITY.md` link `github.com/…/security/advisories/new` actually works for external reporters.

### 2f. Flip visibility

- [x] **Settings → General → Change visibility → Make public**. Confirm the repo name and accept the warning that issues, PRs, and the full git history will become public.

---

## 3. Should be reviewed by a human before / shortly after publishing

- [ ] **README license claim.** `README.md` now points at the MIT `LICENSE` file and the license badge reflects MIT. Before publishing, confirm that MIT is still the intended license.
- [ ] **Confirm the author name and year** in `LICENSE` (currently: *Sameh Abdalla, 2026*). Change if this should be attributed differently (e.g., a future company/organization).
- [x] **Confirm the `sambatia` GitHub username / org** in raw URLs across `sleep-after-claude` and `install-sleep-after-claude.sh`. If the repo ever moves under a different org, the installer and self-update URL defaults must be updated (users can always override via `SLEEP_AFTER_CLAUDE_INSTALLER_URL` / `SLEEP_AFTER_CLAUDE_UPDATE_URL`, but the defaults should be correct).
- [x] **Tag a release.** `v0.1.0` cut 2026-04-20; `v0.2.0` cut 2026-09-10 with the installer SHA-256 published in the release notes so users can pin `SLEEP_AFTER_CLAUDE_INSTALLER_SHA256` against a known-good value. Release procedure is documented in `CLAUDE.md` under "Versioning".
- [x] **Git history scan.** Run 2026-09-10: `gitleaks detect --source . --log-opts=--all` over all 57 commits (~786 KB) — **no leaks found**. Re-run before any future publish. Original guidance retained below. A full historical scan (e.g., with `gitleaks detect --source . --log-opts=--all`) is recommended before publishing — any secret ever committed, even if later removed, remains in history and is retrievable by anyone after the repo goes public. If a secret is found in history, the right response is rotation, not rewriting history (rewrites invalidate cloned forks and break the `curl | bash` install URLs).

---

## 4. Sanity commands

Run once locally before publishing:

```bash
# Lint + syntax + parity
bash -n sleep-after-claude install-sleep-after-claude.sh scripts/check-parity.sh
bash scripts/check-parity.sh
shellcheck -S warning sleep-after-claude install-sleep-after-claude.sh scripts/check-parity.sh
shfmt -d -i 2 -ci sleep-after-claude install-sleep-after-claude.sh scripts/check-parity.sh

# Full test suite
bats tests/

# Pre-commit sweep
pre-commit run --all-files

# Last look for anything sensitive (adjust paths / tools as available)
# gitleaks detect --source . --log-opts=--all --verbose
```

All of the above should exit clean. CI enforces the same invariants on every PR.
