# shared-workflows

Reusable GitHub Actions workflows for dependency management and security scanning.

## Features

- **Native Dependabot cool-down** — configure the waiting period in `dependabot.yml`; Dependabot holds PRs until they mature
- **Version-aware advisory filtering** — advisories already patched at or below the PR's target version are collapsed into a non-blocking "historical" section
- **GHSA + OSV dual-source scan** — every package is queried against both GitHub Advisory and OSV.dev; mismatches surface both
- **OpenSSF Scorecard integration** — Scorecard results for each GitHub Action appear in the scan comment
- **Update-or-create scan comments** — a single stable comment per PR; change detection posts a reply only when advisory IDs actually change
- **Optional auto-merge** — clean scans flip on `gh pr merge --auto`; dirty scans apply a `security-review-needed` label instead
- **Grouped PR support** — handles both single-package and grouped Dependabot PRs

## Prerequisites

- **Dependabot** configured for your repo (GitHub Actions and/or pip/uv ecosystems)
- **Native cool-down** configured in `.github/dependabot.yml` (see Quick Start)
- **No Renovate** — this workflow only scans `dependabot[bot]` PRs; other actors are passed through with a success status

## Quick Start

### 1. Configure Dependabot cool-down

The waiting period is owned by Dependabot itself — the workflow only scans PRs once they're already open. Add `cooldown:` to `.github/dependabot.yml`:

```yaml
# .github/dependabot.yml
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
    cooldown:
      default-days: 7
```

See [Dependabot cool-down docs](https://docs.github.com/en/code-security/dependabot/working-with-dependabot/dependabot-options-reference#cooldown--) for per-severity and per-ecosystem overrides.

### 2. Add the caller workflow

One workflow file invokes the reusable scan on every Dependabot PR:

```yaml
# .github/workflows/dependency-cooldown.yml
name: Dependency Cool-Down

on:
  pull_request:
    branches: [main]
    types: [opened, synchronize, reopened]

permissions:
  contents: write
  pull-requests: write
  statuses: write
  issues: write

concurrency:
  group: cooldown-${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  cooldown:
    uses: j7an/shared-workflows/.github/workflows/dependency-cooldown.yml@v1
    secrets: inherit
    with:
      auto_merge: true
```

`contents: write` is only required when `auto_merge: true`; otherwise `contents: read` is sufficient.

## Inputs

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `enable_scorecard` | boolean | `true` | Include OpenSSF Scorecard results for GitHub Actions in the scan comment |
| `auto_merge` | boolean | `false` | On clean scans, enable `gh pr merge --auto`; on dirty scans, apply the `security-review-needed` label |

## Supported Ecosystems

| Ecosystem | Diff markers parsed | Security sources | Scorecard |
|-----------|--------------------|-----------------|-----------|
| GitHub Actions | `uses: owner/repo@vX.Y.Z` lines | GHSA (ecosystem `ACTIONS`), OSV (`GitHub Actions`) | Yes |
| Python (pip / uv) | `pkg==X.Y.Z`, `pkg>=X.Y.Z`, etc. | GHSA (ecosystem `PIP`), OSV (`PyPI`) | No |

Grouped Dependabot PRs (multiple packages in one PR) are supported — each package is scanned independently and results are merged into one comment. Target versions come from inline `# vX.Y.Z` comments; when those are missing, the workflow falls back to parsing the Dependabot PR body (`Bumps [pkg] from A to B`).

## How It Works

```
Dependabot queues an update
    │
    ▼
Native cooldown holds it for `default-days`
    │
    ▼
Dependabot opens the PR
    │
    ▼
Cool-down workflow fires on pull_request
    ├── Non-dependabot PR? → status "success" (no-op)
    ├── Status → "pending" ("Scanning dependencies...")
    ├── Parses diff to extract package names + target versions
    │     ├── Falls back to PR body text when inline versions are absent
    │     └── Supports github-actions, pip, and uv ecosystems
    ├── For each package:
    │     ├── GHSA GraphQL query (by ecosystem)
    │     ├── OSV.dev POST query (with version if known)
    │     └── OpenSSF Scorecard (github-actions only, if enabled)
    ├── Version-aware filter:
    │     ├── Advisories with firstPatchedVersion ≤ target → historical bucket
    │     └── Advisories affecting target version → blocking bucket
    ├── Update-or-create single scan comment
    ├── If advisory IDs changed since last scan → post change-notification reply
    ├── auto_merge=true + 0 blocking advisories → gh pr merge --auto
    ├── auto_merge=true + ≥1 blocking advisory → label `security-review-needed`
    └── Status → "success" (description carries the outcome)
```

### Version-aware filtering

PR #23 added filtering so that advisories Dependabot has already fixed don't block the PR:

- If GHSA reports `firstPatchedVersion` and the target version is ≥ that value, the advisory is moved into a collapsed `<details>` block labeled "historical advisory/ies (patched at or before target version — not blocking)".
- Only advisories affecting the *target* version count toward the blocking total.
- When the target version can't be determined (no inline comment and no match in the PR body), the workflow falls back to reporting all advisories for the package — safer default.

## Cool-down configuration

All cool-down timing lives in `.github/dependabot.yml` and is enforced by Dependabot itself. There is no bypass label — to ship a zero-day fix immediately, lower `cooldown.default-days` (or remove it for the affected ecosystem) and let Dependabot re-run. Commit history on `dependabot.yml` is the audit trail.

See the [cool-down options reference](https://docs.github.com/en/code-security/dependabot/working-with-dependabot/dependabot-options-reference#cooldown--) for per-severity (`semver-major-days`, `semver-minor-days`, `semver-patch-days`) and package include/exclude lists.

## Security Analysis (Zizmor)

This repo includes a [Zizmor](https://github.com/zizmorcore/zizmor) workflow that runs static security analysis on all workflow YAML files. It detects:

- Template injection in `run:` blocks
- Excessive or missing permissions
- Known CVEs in pinned action commits
- Dangerous triggers (`pull_request_target`, etc.)
- Supply chain risks

Zizmor runs automatically on pushes to `main` and on pull requests. Consumer repos can add the same workflow — see [Adding Zizmor to your repo](#adding-zizmor-to-your-repo).

### Adding Zizmor to your repo

```yaml
# .github/workflows/security.yml
name: Security

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

permissions:
  contents: read
  security-events: write

jobs:
  zizmor:
    name: Workflow Security Analysis
    runs-on: ubuntu-latest
    steps:
      - name: Harden runner
        uses: step-security/harden-runner@fa2e9d605c4eeb9fcad4c99c224cee0c6c7f3594 # v2
        with:
          egress-policy: audit

      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4
        with:
          persist-credentials: false

      - name: Run Zizmor
        uses: zizmorcore/zizmor-action@71321a20a9ded102f6e9ce5718a2fcec2c4f70d8 # v0.5.2
        with:
          min-severity: medium
          min-confidence: medium
```

## Versioning

| Pin | Gets updates | Use when |
|-----|-------------|----------|
| `@v1` | All non-breaking changes | Default — most convenient |
| `@v1.2` | Patch fixes only | Want patches but not new features |
| `@v1.2.3` | Nothing (frozen) | Need exact reproducibility or rollback |

Tags are managed automatically — merging a PR to this repo creates a semver tag based on conventional commit prefixes and updates the floating tags.

## Release Bot App setup

`tag-release.yml` needs a non-`GITHUB_TOKEN` identity to push new tags, otherwise GitHub's recursion guard silently suppresses the downstream `release.yml` run. We use a GitHub App for this.

### Required config

| Kind | Name | Value |
|------|------|-------|
| Repo variable | `RELEASE_BOT_APP_ID` | Numeric App ID |
| Repo secret | `RELEASE_BOT_PRIVATE_KEY` | Full PEM contents including header/footer |

### One-time provisioning

1. Create a GitHub App (org- or user-owned) with **repository permission** `Contents: Read and write` — nothing else.
2. Install the App on this repo (single-repo install recommended).
3. Copy the App ID into `vars.RELEASE_BOT_APP_ID` under **Settings → Secrets and variables → Actions → Variables**.
4. Generate a private key from the App settings and paste the PEM into `secrets.RELEASE_BOT_PRIVATE_KEY` under **Settings → Secrets and variables → Actions → Secrets**.

### Verify

Dispatch **Actions → Tag Release → Run workflow** with `bump=patch`. Within ~30 seconds, a new run of `Publish Release` should appear:

```bash
gh run list --workflow=release.yml --limit 1
```

### Rotation

To rotate the key: generate a new private key in the App settings, update `secrets.RELEASE_BOT_PRIVATE_KEY`, then delete the old key in the App settings. No code change required.
