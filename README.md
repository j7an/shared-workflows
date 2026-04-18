# shared-workflows

Reusable GitHub Actions workflows for dependency management and security scanning.

## Features

- **Dual-layer cool-down enforcement** — Dependabot's native `cooldown.default-days` gates PR creation; the workflow's `cooldown_days` input enforces release age on every scan, closing the rebase-bypass path that native cool-down alone leaves open
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
| `cooldown_days` | number | `7` | Minimum release age in days before auto-merge is allowed. Set to `0` to disable workflow-side release-age enforcement (pre-v2.0.2 behavior — relies entirely on Dependabot's native cooldown) |
| `fail_on_cooldown` | boolean | `false` | If `true`, cooldown blocks set the gate status to `failure` instead of `pending`. Use when branch protection requires a hard-red blocker rather than a self-healing pending state |

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

The workflow enforces cool-down at two layers, each independently configurable:

### Layer 1 — Dependabot native cool-down (PR creation)

Configured in `.github/dependabot.yml`. Dependabot holds new PRs until the target version is at least `cooldown.default-days` old. This gate runs once, at PR creation. **It does NOT re-check on `@dependabot rebase`** — a rebase re-resolves to the latest version and skips this gate entirely.

```yaml
# .github/dependabot.yml
updates:
  - package-ecosystem: "github-actions"
    cooldown:
      default-days: 7
```

See the [cool-down options reference](https://docs.github.com/en/code-security/dependabot/working-with-dependabot/dependabot-options-reference#cooldown--) for per-severity (`semver-major-days`, `semver-minor-days`, `semver-patch-days`) and package include/exclude lists.

### Layer 2 — Workflow-side release-age gate (every scan)

Configured via the `cooldown_days` input on the caller workflow (default `7`). The workflow re-evaluates release age on every scan, including after `@dependabot rebase`. If any target version is younger than `cooldown_days`, the workflow:

- Applies the `cooldown-pending` label
- Sets the `dependency-cooldown / gate` status to `pending` (or `failure` if `fail_on_cooldown: true`)
- Skips `gh pr merge --auto` even if the advisory scan is clean

Once the next scan finds all versions past the threshold, the label is removed and the gate flips to `success`. To disable workflow-side enforcement entirely (pre-v2.0.2 behavior), set `cooldown_days: 0` in the caller workflow.

### Bypass

There is no per-PR bypass label. To ship a zero-day fix immediately:

- Lower `cooldown.default-days` in `.github/dependabot.yml` for the affected ecosystem, OR
- Set `cooldown_days: 0` in the caller workflow temporarily, OR
- Merge manually (the gate state is informational; you control your branch protection rules)

Commit history on `dependabot.yml` and your caller workflow is the audit trail.

## Labels

The workflow manages two labels on Dependabot PRs. **Both are reconciled on every scan** — applied when the condition is true, removed when it becomes false.

| Label | Color | Applied when | Removed when |
|-------|-------|--------------|--------------|
| `security-review-needed` | red (`B60205`) | Advisory scan finds vulnerabilities affecting target versions | Re-scan finds zero applicable advisories |
| `cooldown-pending` | amber (`FBCA04`) | Any target version is younger than `cooldown_days` | Re-scan finds all versions past the threshold |

The reconciliation is authoritative — a PR that was dirty at first scan and clean after rebase will have neither label at merge time.

## Scheduled re-scan for long-pending PRs (v2.4.0+)

A Dependabot PR that opens *during* its dependency's cooldown window scans once and then sits in the `pending` gate state until either Dependabot rebases or a human prods `@dependabot recreate`. To rescan automatically on a schedule, consumers can add a thin caller workflow that invokes `cooldown-rescan.yml`:

```yaml
# .github/workflows/dependency-cooldown-rescan.yml
name: Dependency Cooldown Rescan

on:
  schedule:
    - cron: "0 6 * * *"   # daily at 06:00 UTC; tune per consumer
  workflow_dispatch:

permissions:
  contents: read
  pull-requests: read
  actions: write
  statuses: read

jobs:
  rescan:
    uses: j7an/shared-workflows/.github/workflows/cooldown-rescan.yml@v2
```

How it works: on each invocation, the rescan workflow lists open Dependabot PRs in the caller repo, finds those whose `dependency-cooldown / gate` commit status is `pending`, and reruns the most recent `dependency-cooldown.yml` workflow run for each via `gh run rerun`. The replayed run uses the original `pull_request` payload (so the head SHA is stable) but with the current runtime clock — release-age gates re-evaluate freshly.

The workflow only triggers PRs with a `pending` gate. PRs in `success` or `failure` are left alone.

### Cadence

Cadence is owned by the caller. Sweep at least once per cooldown-window step (e.g., a 7-day cooldown is comfortably handled by a daily sweep; a 1-day cooldown wants every-few-hours). GitHub may delay scheduled runs by up to ~30 minutes under load, so use `workflow_dispatch:` as the manual escape hatch.

### Dry-run rollout

For initial validation, pass `dry_run: true` so the sweep logs decisions without calling `gh run rerun`:

```yaml
jobs:
  rescan:
    uses: j7an/shared-workflows/.github/workflows/cooldown-rescan.yml@v2
    with:
      dry_run: true
```

Trigger via `workflow_dispatch`, inspect the `$GITHUB_STEP_SUMMARY` table, then remove the `with:` block once the filter logic looks right.

### Inputs

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `dry_run` | boolean | `false` | When `true`, log decisions to `$GITHUB_STEP_SUMMARY` but do not call `gh run rerun`. Use for initial-rollout validation and incident diagnostics. |

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
| `@vX` | All non-breaking changes within major `X` | Default — most convenient |
| `@vX.Y` | Patch fixes only within minor `X.Y` | Want patches but not new features |
| `@vX.Y.Z` | Nothing (frozen) | Need exact reproducibility or rollback |

Tags are managed automatically — merging a PR to this repo creates a semver tag based on conventional commit prefixes and updates the floating tags.

## Known caller-side constraints

The reusable workflows in this repo are **self-contained at runtime**: they must
not fetch `j7an/shared-workflows` source at runtime, and they must not reference
caller-scoped context variables as if they were reusable-workflow-scoped.

The following are forbidden inside any `workflow_call` file:

| Pattern | Why it's wrong |
|---------|---------------|
| `ref: ${{ github.workflow_sha }}` | Resolves to the **caller's** event SHA, not this workflow's commit |
| `ref: ${{ github.sha }}` | Same problem — resolves to caller context |
| `ref: ${{ github.ref }}` | Same problem — resolves to caller's branch/tag ref |

This policy exists because violating it caused [#29](https://github.com/j7an/shared-workflows/issues/29):
v2.0.2 shipped with a broken `actions/checkout` step that failed deterministically
on every cross-repo consumer PR. The CI gate that should have caught it was
structurally incapable of doing so, because `ci-cooldown.yml` self-consumes via
local path (`uses: ./...`), which makes the caller repo the same as the checkout
target and masks caller-context bugs by coincidence.

If a future reusable workflow needs to execute a script that's under version
control in this repo, **inline the script into the workflow YAML**. The bats test
suite under `tests/` provides unit-test coverage against the standalone
`scripts/*.sh` files, and `scripts/check-inline-sync.sh` verifies the inline
copies stay in sync — so test feedback is preserved without introducing a runtime
source-fetch dependency.

### For authors adding a new reusable workflow

Before opening a PR that adds or modifies a `workflow_call` file:

1. **Review the constraints above** — no runtime source fetching, no caller-context refs
2. **The lint rule enforces this in CI** — `scripts/lint-workflow-call.sh` runs as the `lint-workflow-call` job in `ci-scripts.yml` and will fail your PR if it detects a forbidden pattern
3. **Cross-repo smoke testing is planned** ([#30](https://github.com/j7an/shared-workflows/issues/30)) — a companion repo will exercise reusable workflows from a genuinely external caller context to catch bugs that the self-consumption harness cannot detect

## Release Bot App setup

`tag-release.yml` needs a non-`GITHUB_TOKEN` identity to push new tags, otherwise GitHub's recursion guard silently suppresses the downstream `release.yml` run. We use a GitHub App for this.

### Required config

| Kind | Name | Value |
|------|------|-------|
| Repo variable | `RELEASE_BOT_APP_ID` | Numeric App ID |
| Secret | `RELEASE_BOT_PRIVATE_KEY` | Full PEM contents including header/footer |

### One-time provisioning

1. Create a GitHub App (org- or user-owned) with **repository permission** `Contents: Read and write` — nothing else.
2. Install the App on this repo (single-repo install recommended).
3. Copy the App ID into `vars.RELEASE_BOT_APP_ID` under **Settings → Secrets and variables → Actions → Variables**.
4. Generate a private key from the App settings and store the PEM as `RELEASE_BOT_PRIVATE_KEY`. A repo-level Actions secret works with the sample caller below; if you scope release credentials to the `release` environment, expose the same secret name there instead.

### Verify

Dispatch **Actions → Tag Release → Run workflow** with `bump=patch`. Within ~30 seconds, a new run of `Publish Release` should appear:

```bash
gh run list --workflow=release.yml --limit 1
```

### Rotation

To rotate the key: generate a new private key in the App settings, update `secrets.RELEASE_BOT_PRIVATE_KEY`, then delete the old key in the App settings. No code change required.

## Using shared-workflows for releases

`tag-release.yml` and `release.yml` are reusable workflows. Downstream repos can cut and publish releases by adding a thin caller that delegates to this repo — no copy-pasted release logic.

### Minimal caller (recommended)

```yaml
# .github/workflows/release.yml
name: Release
on:
  workflow_dispatch:

permissions:
  contents: write

jobs:
  tag:
    uses: j7an/shared-workflows/.github/workflows/tag-release.yml@v2
    secrets:
      RELEASE_BOT_PRIVATE_KEY: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}
  publish:
    needs: tag
    uses: j7an/shared-workflows/.github/workflows/release.yml@v2
    with:
      tag: ${{ needs.tag.outputs.tag }}
```

Dispatching this workflow runs `tag-release` with the default `bump: auto` (infers the semver bump from conventional commit prefixes), then publishes the resulting tag.

### Full caller (with operator bump override)

Use this variant if you want to expose a picker in the Actions UI so operators can force a specific bump level.

```yaml
# .github/workflows/release.yml
name: Release
on:
  workflow_dispatch:
    inputs:
      bump:
        type: choice
        options: [auto, patch, minor, major]
        default: auto

permissions:
  contents: write

jobs:
  tag:
    uses: j7an/shared-workflows/.github/workflows/tag-release.yml@v2
    with:
      bump: ${{ inputs.bump }}
    secrets:
      RELEASE_BOT_PRIVATE_KEY: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}
  publish:
    needs: tag
    uses: j7an/shared-workflows/.github/workflows/release.yml@v2
    with:
      tag: ${{ needs.tag.outputs.tag }}
```

### Required downstream setup

1. **Create a `release` GitHub Environment**, restricted to the `main` branch via deployment branch policy (Settings → Environments → New environment → Deployment branches → Selected branches → `main`).
2. **Make `RELEASE_BOT_PRIVATE_KEY` available as `secrets.RELEASE_BOT_PRIVATE_KEY`** in the caller repo. The sample snippets work with a repo-level Actions secret; if you scope release credentials to the `release` environment, keep the same secret name there so the caller can forward it unchanged.
3. **Set `vars.RELEASE_BOT_APP_ID`** as a repo variable pointing at the Release Bot GitHub App's numeric App ID.
4. **Install the Release Bot App on the repo** with `Contents: Read and write` permission (see [Release Bot App setup](#release-bot-app-setup) above for provisioning).

The `environment: release` + `if: github.ref == 'refs/heads/main'` gate inside `tag-release.yml` runs in **your repo's** security context — `shared-workflows` cannot unilaterally enforce it across consumers. If you skip step 1, you lose the environment-side branch policy and secret protection; the in-file `if:` check still blocks non-`main` refs, but the extra GitHub-side gate is gone.

### On the `@v2` pin

`@v2` is the floating major tag for the current `v2.x.y` line. It always points at the latest `v2.x.y` release because `release.yml` force-updates floating majors on every publish. Pinning to `@v2` means you get all non-breaking updates automatically. Pin to `@v2.1` for patch-only updates, or `@v2.1.0` for an immutable freeze — see the [Versioning](#versioning) section above.
