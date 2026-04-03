# shared-workflows

Reusable GitHub Actions workflows for dependency management and security scanning.

## Features

- **Business day cooling period** — counts only Mon-Fri (not calendar days) before allowing merge
- **Emergency bypass** — apply a label to skip cooldown for zero-day fixes, with audit trail
- **Continuous monitoring** — scan comments updated every 6h, not just once
- **Change detection** — notification reply when new advisories are published during cooldown
- **Security database links** — GHSA, OSV, OpenSSF Scorecard in auto-created tracking issues
- **OpenSSF Scorecard badge** — embedded in tracking issues for scored projects
- **Auto tracking issues** — created on PR open with cooldown timeline and security links
- **Grouped PR support** — handles both single-package and grouped Dependabot PRs

## Prerequisites

- **Dependabot** configured for your repo (GitHub Actions and/or pip/uv ecosystems)
- **Labels** must exist in your repo: `dependencies`, `github_actions` (underscore, not hyphen), `python`
- **No Renovate** — these workflows only support `dependabot[bot]` as the PR actor
- **Python 3** available on runner (used for business day calculation)

## Quick Start

Add these two workflow files to your repo's `.github/workflows/` directory:

### Gate Workflow

Triggers on every Dependabot PR. Sets a pending commit status and creates a tracking issue.

```yaml
# .github/workflows/dependency-cooldown-gate.yml
name: Dependency Cool-Down Gate

on:
  pull_request:
    types: [opened, synchronize]

permissions:
  statuses: write
  issues: write
  pull-requests: write

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  gate:
    uses: j7an/shared-workflows/.github/workflows/dependency-cooldown-gate.yml@v1
    secrets: inherit
    with:
      cooling_business_days: 5
```

### Scan Workflow

Runs on a schedule. Checks mature PRs for known advisories and posts/updates scan comments.

```yaml
# .github/workflows/dependency-cooldown-scan.yml
name: Dependency Cool-Down Scan

on:
  schedule:
    - cron: "0 */6 * * *"
  workflow_dispatch:

permissions:
  contents: read
  pull-requests: write
  statuses: write

concurrency:
  group: ${{ github.workflow }}
  cancel-in-progress: false

jobs:
  scan:
    uses: j7an/shared-workflows/.github/workflows/dependency-cooldown-scan.yml@v1
    secrets: inherit
    with:
      cooling_business_days: 5
```

## Gate Inputs

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `cooling_business_days` | number | `5` | Business days (Mon-Fri) before a bot PR passes the gate |
| `bypass_label` | string | `security-bypass-cooling` | Label that skips the cooling period |
| `create_tracking_issue` | boolean | `true` | Auto-create tracking issues for bot PRs |
| `default_assignee` | string | `""` | Issue assignee (empty = repo owner) |

## Scan Inputs

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `cooling_business_days` | number | `5` | Business days before a bot PR is eligible for scanning |
| `bypass_label` | string | `security-bypass-cooling` | Label that skips the cooling period |
| `enable_scorecard` | boolean | `true` | Include OpenSSF Scorecard in scan results |

## Supported Ecosystems

| Ecosystem | Branch pattern | Security sources | Scorecard |
|-----------|---------------|-----------------|-----------|
| GitHub Actions | `dependabot/github_actions/*` | GHSA, OSV, Scorecard, GitHub Releases | Badge + link |
| Python (pip) | `dependabot/pip/*` | GHSA, OSV, PyPI | No |
| Python (uv) | `dependabot/uv/*` | GHSA, OSV, PyPI | No |

Grouped Dependabot PRs (multiple packages in one PR) are supported — security links are generated for each package individually.

## How It Works

```
Dependabot opens PR
    │
    ▼
Gate workflow fires
    ├── Sets commit status to "pending"
    ├── Creates tracking issue with security links + Scorecard badge
    └── Prepends "Fixes #N" to PR body
    │
    ... 5 business days pass ...
    │
    ▼
Scan workflow fires (every 6h)
    ├── Checks if PR has matured (business days >= threshold)
    ├── Queries GHSA + OSV for advisories (Tier 1 — blocks on findings)
    ├── Queries OpenSSF Scorecard (Tier 2 — informational only)
    ├── Posts or updates scan comment with results
    ├── Posts change notification if advisories changed since last scan
    └── Sets commit status to "success"
    │
    ▼
Human reviews and merges → tracking issue auto-closes
```

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

## Emergency Bypass

For zero-day fixes that can't wait for the cooldown:

1. Apply the `security-bypass-cooling` label to the PR
2. The gate/scan workflows detect the label and immediately set status to `success`
3. The bypass is recorded in the commit status description (audit trail)

## Versioning

| Pin | Gets updates | Use when |
|-----|-------------|----------|
| `@v1` | All non-breaking changes | Default — most convenient |
| `@v1.2` | Patch fixes only | Want patches but not new features |
| `@v1.2.3` | Nothing (frozen) | Need exact reproducibility or rollback |

Tags are managed automatically — merging a PR to this repo creates a semver tag based on conventional commit prefixes and updates the floating tags.
