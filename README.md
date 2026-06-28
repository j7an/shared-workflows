# shared-workflows

Reusable GitHub Actions workflows for dependency safety verification and release management.

## Features

- **Opt-in release-age verification** — Dependabot's native `cooldown.default-days` owns the wait before PR creation; `release_age_policy` (default `"off"`) can additionally label (`advisory`) or fail the gate (`blocking`) on target versions younger than `minimum_release_age_days`
- **Version-aware advisory filtering** — advisories already patched at or below the PR's target version are collapsed into a non-blocking "historical" section
- **GHSA + OSV dual-source scan** — every package is queried against both GitHub Advisory and OSV.dev; mismatches surface both
- **OpenSSF Scorecard integration** — Scorecard results for each GitHub Action appear in the scan comment
- **Update-or-create scan comments** — a single stable comment per PR; change detection posts a top-level PR comment only when advisory IDs actually change
- **Auto-merge by default** — clean scans enable `gh pr merge --auto` (set `auto_merge: false` to opt out); dirty scans apply labels (`security-review-needed`, `dependency-age-violation`, or `dependency-safety-error`) instead
- **Grouped PR support** — handles both single-package and grouped Dependabot PRs
- **Reusable pre-commit autoupdate PRs** — shared `pre-commit-autoupdate.yml` runs `uvx pre-commit autoupdate`, opens a dependency PR only when the configured pre-commit config changes, recommends Release Bot App auth for required checks, and keeps a documented `GITHUB_TOKEN` fallback

## Prerequisites

- **Dependabot** configured for your repo (GitHub Actions and/or pip/uv ecosystems)
- **Native cool-down** configured in `.github/dependabot.yml` (see Quick Start)
- **No Renovate** — this workflow only scans `dependabot[bot]` PRs; other actors are passed through with a success status (except external fork PRs, whose read-only token can't post the status — see [Fork PRs and the required gate](#fork-prs-and-the-required-gate))

> **Scope: version-update PRs.** Dependabot's native `cooldown:` setting applies
> only to *version updates*, not [security updates][gh-cooldown-scope]. With the
> default `release_age_policy: "off"` this distinction has no effect — the
> workflow performs no post-PR age checks. If you opt into `advisory` or
> `blocking`, young security-fix PRs will be flagged (or blocked) even though
> native cooldown never held them — prefer `advisory` if that trade-off is not
> acceptable for your repo.
>
> [gh-cooldown-scope]: https://docs.github.com/en/code-security/dependabot/working-with-dependabot/dependabot-options-reference#cooldown--

## Quick Start

### 1. Configure Dependabot cool-down

The waiting period is owned by Dependabot itself — by default the workflow does not re-verify it (opt in with `release_age_policy`). Add `cooldown:` to `.github/dependabot.yml`:

```yaml
# .github/dependabot.yml
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
    cooldown:
      default-days: 5
```

See [Dependabot cool-down docs](https://docs.github.com/en/code-security/dependabot/working-with-dependabot/dependabot-options-reference#cooldown--) for per-severity and per-ecosystem overrides.

### 2. Add the caller workflow

One workflow file invokes the reusable verifier on every Dependabot PR:

```yaml
# .github/workflows/dependency-safety.yml
name: Dependency Safety

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
  group: safety-${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  safety:
    uses: j7an/shared-workflows/.github/workflows/dependency-safety.yml@v4
    secrets: inherit
```

`auto_merge` defaults to `true` and requires `contents: write`. If you grant only `contents: read`, set `auto_merge: false`.

> **Note:** `@v4` is the current floating major. `@v3` (release-age enforcement
> on by default, auto-merge opt-in) and `@v2` (last cooldown-bearing line)
> continue to work but receive no further updates. Releases in this repo are
> dispatched manually — see [Versioning](#versioning).

> **External fork PRs:** by default GitHub gives `GITHUB_TOKEN` a **read-only**
> token on PRs from forks even when you declare `statuses: write` — unless a
> repo admin has enabled **Send write tokens to workflows from pull requests**
> ([docs](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#changing-the-permissions-in-a-forked-repository)).
> With a read-only token the reusable workflow cannot post the
> `dependency-safety / gate` status from the fork run — it logs a notice and the
> job stays green rather than failing. If you make that status **required**, see
> [Fork PRs and the required gate](#fork-prs-and-the-required-gate).

## Pre-commit Autoupdate

`pre-commit-autoupdate.yml` is a `workflow_call`-only reusable workflow for
repos that keep a pre-commit config file (default path `.pre-commit-config.yaml`
via `config_path`). Callers keep their own `schedule`,
`workflow_dispatch`, and optional `concurrency`; the shared workflow installs
uv and runs `uvx`, so the caller repo does not need to be a uv-managed Python
project.

Prefer the App-token caller for repos with required checks:

```yaml
name: Pre-commit Autoupdate

on:
  schedule:
    - cron: "0 8 * * 1"
  workflow_dispatch:

permissions: {}

concurrency:
  group: pre-commit-autoupdate
  cancel-in-progress: true

jobs:
  autoupdate:
    permissions:
      contents: read
    uses: j7an/shared-workflows/.github/workflows/pre-commit-autoupdate.yml@v4
    secrets:
      RELEASE_BOT_PRIVATE_KEY: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}
```

The caller repo must define `vars.RELEASE_BOT_APP_ID`. Without that var, the
workflow falls back to `GITHUB_TOKEN`; fallback callers must grant
`contents: write` and `pull-requests: write`, and their generated PRs may need
a close/reopen or empty commit to start required CI because of GitHub's
recursion guard.

## Inputs

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `enable_scorecard` | boolean | `true` | Include OpenSSF Scorecard results for GitHub Actions in the scan comment |
| `auto_merge` | boolean | `true` | On clean scans, enable `gh pr merge --auto` (requires `contents: write`); on dirty scans, apply the appropriate label. Set `false` for manual merges |
| `release_age_policy` | string | `"off"` | Post-PR release-age verification: `off` (no age lookup), `advisory` (label + comment on young targets, gate stays green, auto-merge suppressed), `blocking` (gate fails). Quote `"off"` in YAML |
| `minimum_release_age_days` | number | `5` | Threshold used when `release_age_policy` is `advisory` or `blocking`; ignored when `off`. Should match `cooldown.default-days` in `dependabot.yml` |

## Supported Ecosystems

| Ecosystem | Diff markers parsed | Security sources | Scorecard |
|-----------|--------------------|-----------------|-----------|
| GitHub Actions | `uses: owner/repo@vX.Y.Z` lines | GHSA (ecosystem `ACTIONS`), OSV (`GitHub Actions`) | Yes |
| Python (pip / uv) | `pkg==X.Y.Z`, `pkg>=X.Y.Z`, etc. | GHSA (ecosystem `PIP`), OSV (`PyPI`) | No |

Grouped Dependabot PRs (multiple packages in one PR) are supported — each package is scanned independently and results are merged into one comment. Target versions come from inline `# vX.Y.Z` comments; when those are missing, the workflow falls back to parsing the Dependabot PR body (`Bumps [pkg] from A to B`).

## How It Works

```
Dependabot's native cooldown holds an update for `cooldown.default-days`
    │
    ▼
Dependabot opens the PR (target version is now ≥ cooldown days old)
    │
    ▼
dependency-safety.yml fires on pull_request
    ├── Non-dependabot PR? → status "success" (no-op; external forks can't post — see "Fork PRs and the required gate")
    ├── Status → "pending" ("Scanning dependencies for safety...")
    ├── Parses diff to extract package names + target versions
    │     ├── Falls back to PR body text when inline versions are absent
    │     └── Supports github-actions, pip, and uv ecosystems
    ├── Verifies release age (only when release_age_policy is advisory or blocking; blocking fails the gate, advisory labels + suppresses auto-merge)
    ├── For each package:
    │     ├── GHSA GraphQL query (by ecosystem)
    │     ├── OSV.dev POST query (with version if known)
    │     └── OpenSSF Scorecard (github-actions only, if enabled)
    ├── Version-aware filter:
    │     ├── Advisories with firstPatchedVersion ≤ target → historical bucket
    │     └── Advisories affecting target version → blocking bucket
    ├── Computes deterministic verdict (safety-verdict.sh)
    ├── Reconciles labels (security-review-needed, dependency-age-violation, dependency-safety-error)
    ├── Update-or-create single scan comment
    ├── If advisory IDs changed since last scan → post change-notification top-level PR comment
    ├── If clean and auto_merge=true (default) → gh pr merge --auto
    └── Sets final gate status (success / failure / error)
```

### Version-aware filtering

PR #23 added filtering so that advisories Dependabot has already fixed don't block the PR:

- If GHSA reports `firstPatchedVersion` and the target version is ≥ that value, the advisory is moved into a collapsed `<details>` block labeled "historical advisory/ies (patched at or before target version — not blocking)".
- Only advisories affecting the *target* version count toward the blocking total.
- When the target version can't be determined (no inline comment and no match in the PR body), the workflow falls back to reporting all advisories for the package — safer default.

## Gate states and labels

The `dependency-safety / gate` commit status uses three states:

| State | When |
|-------|------|
| `success` | Clean scan, OR advisories present (label `security-review-needed`), OR age violation under `release_age_policy: advisory` (label `dependency-age-violation`) |
| `failure` | Age violation under `release_age_policy: blocking` |
| `error` | Dependency extraction failed, or GHSA/OSV/age-lookup APIs errored — the verdict is unreliable; manual review required |

Labels:

| Label | Color | Applied when | Removed when |
|-------|-------|--------------|--------------|
| `security-review-needed` | red (`B60205`) | Advisory scan finds vulnerabilities affecting target versions | Re-scan finds zero applicable advisories AND no `error` state |
| `dependency-age-violation` | amber (`FBCA04`) | Any target version is younger than `minimum_release_age_days` (only under `release_age_policy: advisory` or `blocking`) | All versions pass age check AND no `error` state |
| `dependency-safety-error` | grey (`6E7781`) | Scan extraction failed or API errors occurred | Clean scan completes without errors |

Reconciliation is authoritative when the scan succeeds. On the `error` path, labels are preserved (not removed) since the verdict is unreliable.

## Fork PRs and the required gate

`dependency-safety.yml` is a **Dependabot-automation** gate. Repos that make
`dependency-safety / gate` required need exactly one trusted writer for every
pull request head SHA. The correct companion depends on how your scanner caller
is gated.

**Recommended matched pair: Dependabot-gated scanner plus non-bot gate.** This
is the cleanest shape for repos that require `dependency-safety / gate` on all
PRs: Dependabot PRs run the real scanner, and every other PR gets a
status-only gate.

```yaml
# .github/workflows/dependency-safety.yml
name: Dependency Safety

on:
  pull_request:
    types: [opened, synchronize, reopened]

permissions:
  contents: write
  pull-requests: write
  statuses: write
  issues: write

concurrency:
  group: dependency-safety-${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  safety:
    # Real scan for Dependabot only; non-Dependabot PRs are handled by
    # dependency-safety-non-bot-gate.yml. Keep this field paired with the
    # non-bot gate's complementary condition.
    if: github.event.pull_request.user.login == 'dependabot[bot]'
    uses: j7an/shared-workflows/.github/workflows/dependency-safety.yml@v4
    secrets: inherit
```

```yaml
# .github/workflows/dependency-safety-non-bot-gate.yml
name: Dependency Safety Non-Bot Gate

on:
  pull_request_target: # zizmor: ignore[dangerous-triggers] status-only path; never checks out or runs PR code
    types: [opened, synchronize, reopened]
    branches: [main]  # include every branch where dependency-safety / gate is required

permissions: {}

concurrency:
  group: dep-safety-gate-${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  gate:
    permissions:
      statuses: write
    uses: j7an/shared-workflows/.github/workflows/dependency-safety-non-bot-gate.yml@v4
```

This non-bot gate is the companion to a Dependabot-gated scanner caller. If
your scanner caller runs ungated, use the fork-only pattern below instead. Do
not mix a Dependabot-gated scanner with a fork-only gate: same-repo human PRs
would have no writer for the required status. The non-bot wrapper's `branches:`
filter must cover every branch where a ruleset or branch protection rule
requires `dependency-safety / gate`.

**Why the wrapper is safe:** `pull_request_target` runs in your repo's context
with a write token, which is exactly what is needed to post the status, and it
is safe here only because the wrapper delegates to a status-only reusable
workflow. The reusable workflow performs no checkout, uses no third-party
actions, runs no dependency install/build/test, executes no PR-authored files,
requests only `statuses: write`, uses only the automatic `github.token`, and
passes PR-derived values into shell through `env:`. Do not add
`secrets: inherit` to the non-bot gate wrapper.

**Alternative: ungated scanner plus fork-only gate.** If your scanner caller
runs on every `pull_request`, same-repo non-bot PRs are handled by the scanner's
own pass-through branch. In that architecture, add only a fork companion:

```yaml
# .github/workflows/fork-pr-gate.yml
name: Fork PR dependency-safety gate
on:
  pull_request_target:
    types: [opened, synchronize, reopened]
permissions:
  statuses: write
jobs:
  gate:
    # cross-repo fork PRs only; same-repo PRs are handled by the scanner workflow
    if: github.event.pull_request.head.repo.id != github.event.pull_request.base.repo.id
    runs-on: ubuntu-latest
    steps:
      - name: Post neutral gate status
        env:
          GH_TOKEN: ${{ github.token }}
          GH_REPO: ${{ github.repository }}
          HEAD_SHA: ${{ github.event.pull_request.head.sha }}
          RUN_URL: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
        run: |
          gh api "repos/${GH_REPO}/statuses/${HEAD_SHA}" \
            -f state="success" \
            -f context="dependency-safety / gate" \
            -f description="Fork PR: dependency-safety scan not run; human review required" \
            -f target_url="${RUN_URL}"
```

External fork PRs get a read-only `GITHUB_TOKEN` under `pull_request` by
default, even when the caller declares `statuses: write`, unless a repo admin
enables **Send write tokens to workflows from pull requests** ([docs][fork-perms]).
The trusted `pull_request_target` wrapper closes that required-status gap
without running untrusted PR code.

If you run [Zizmor](#security-analysis-zizmor), it will flag the wrapper's
`pull_request_target` trigger. That finding is expected for this constrained,
status-only pattern; verify the no-checkout, no-PR-code, `statuses: write`-only
envelope instead of suppressing the architectural review.

[fork-perms]: https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#changing-the-permissions-in-a-forked-repository

## v2 → v3 migration

`v3.0.0` removed the deprecated `dependency-cooldown.yml` and
`cooldown-rescan.yml` workflows. If your repo still references them via
`@v2`, the pin continues to work against the frozen v2 line; to move to
`v3`, follow these steps:

1. **Add native cooldown** to `.github/dependabot.yml` (`cooldown.default-days: 5` or higher).

2. **Replace the caller `uses:` line:**
   ```diff
   - uses: j7an/shared-workflows/.github/workflows/dependency-cooldown.yml@v2
   + uses: j7an/shared-workflows/.github/workflows/dependency-safety.yml@v3
   ```

3. **Rename the input** `cooldown_days` → `minimum_release_age_days`.

4. **Drop `fail_on_cooldown`** — replaced by `fail_on_age_violation` with
   different semantics (failure-on-violation, not pending-on-violation).

5. **Remove any caller workflow** that uses `cooldown-rescan.yml`. No rescan
   companion under `dependency-safety.yml` — the verifier is single-shot per
   PR event.

6. **Update branch protection / rulesets.** The commit-status context changes
   from `dependency-cooldown / gate` to `dependency-safety / gate`. Required-
   status-check rules on the old context will wait forever once you cut over.

7. **Clean up stale labels.** Any `cooldown-pending` label managed by the
   legacy workflow lingers until manually removed; `dependency-safety.yml`
   does not touch it.

8. **Optional:** add `rebase-strategy: disabled` to your `dependabot.yml`
   ecosystem block — avoids `@dependabot rebase` pulling in newer versions
   that have not yet aged through native cooldown.

## v3 → v4 migration

`v4.0.0` makes post-PR release-age verification opt-in and enables auto-merge
by default. Dependabot native `cooldown.default-days` remains the recommended
mechanism for delaying version-update PRs; the workflow no longer re-verifies
release age unless asked to.

1. **Map `fail_on_age_violation` to `release_age_policy`.** The old input is
   removed — passing it to `@v4` fails at startup with "Invalid input":

   | v3 | v4 |
   |----|----|
   | `fail_on_age_violation: true` (or unset) | `release_age_policy: blocking` |
   | `fail_on_age_violation: false` | `release_age_policy: advisory` |
   | — (new default: no post-PR age checks) | omit the input (defaults to `"off"`) |

2. **Auto-merge now defaults to on.** Set `auto_merge: false` to keep manual
   merges. With auto-merge on, the calling job must grant `contents: write`.

3. **Keep (or add) native cooldown** in `.github/dependabot.yml` — under the
   default `release_age_policy: "off"` the workflow no longer verifies the
   age invariant, so `cooldown.default-days` is the only waiting period.

4. **Quote the policy value if you restate it.** `release_age_policy: "off"`
   — unquoted `off` is a YAML boolean literal and may not survive parsing as
   a string. `minimum_release_age_days` only takes effect with `advisory` or
   `blocking`.

5. **Stale labels self-heal.** A leftover `dependency-age-violation` label
   from v3 is removed on the first error-free v4 scan of that PR.

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

Releases are cut manually via the `release-self.yml` workflow dispatch. Merging a PR to `main` does **not** create a tag on its own. When a maintainer dispatches `release-self.yml` (with `bump: auto`), it scans Conventional Commits since the last tag, computes the next semver tag, and updates the floating `vX` / `vX.Y` tags to point at the new commit.

## Known caller-side constraints

The reusable workflows in this repo are **self-contained at runtime**: they must not fetch `j7an/shared-workflows` source at runtime, and they must not reference caller-scoped context variables as if they were reusable-workflow-scoped.

The following are forbidden inside any `workflow_call` file:

| Pattern | Why it's wrong |
|---------|---------------|
| `ref: ${{ github.workflow_sha }}` | Resolves to the **caller's** event SHA, not this workflow's commit |
| `ref: ${{ github.sha }}` | Same problem — resolves to caller context |
| `ref: ${{ github.ref }}` | Same problem — resolves to caller's branch/tag ref |

This policy exists because violating it caused [#29](https://github.com/j7an/shared-workflows/issues/29): v2.0.2 shipped with a broken `actions/checkout` step that failed deterministically on every cross-repo consumer PR. The CI gate that should have caught it was structurally incapable of doing so, because `ci-cooldown.yml` self-consumed via local path (`uses: ./...`), which makes the caller repo the same as the checkout target and masks caller-context bugs by coincidence.

If a future reusable workflow needs to execute a script that's under version control in this repo, **inline the script into the workflow YAML**. The bats test suite under `tests/` provides unit-test coverage against the standalone `scripts/*.sh` files, and `scripts/check-inline-sync.sh` verifies the inline copies stay in sync — so test feedback is preserved without introducing a runtime source-fetch dependency.

### For authors adding a new reusable workflow

Before opening a PR that adds or modifies a `workflow_call` file:

1. **Review the constraints above** — no runtime source fetching, no caller-context refs
2. **The lint rule enforces this in CI** — `scripts/lint-workflow-call.sh` runs as the `lint-workflow-call` job in `ci-scripts.yml` and will fail your PR if it detects a forbidden pattern
3. **Cross-repo smoke testing is planned** ([#30](https://github.com/j7an/shared-workflows/issues/30)) — a companion repo will exercise reusable workflows from a genuinely external caller context to catch bugs that the self-consumption harness cannot detect

## Validating workflow changes

Run these locally before opening a PR that touches `.github/workflows/` or `scripts/`:

```bash
./scripts/lint-workflows.sh          # workflow/YAML structure (actionlint, non-hanging mode)
bats tests/                          # script / runtime behavior
./scripts/check-inline-sync.sh       # inline copies match scripts/*.sh
./scripts/lint-workflow-call.sh      # no caller-context refs in workflow_call files
```

Optional, advisory shell analysis:

```bash
shellcheck scripts/*.sh              # completes, but has known info-level findings; not a gate
```

**Why `lint-workflows.sh` instead of plain `actionlint`?** Default `actionlint`
(with its ShellCheck integration enabled) **hangs** on
`.github/workflows/dependency-safety.yml`: that file carries a large inlined
`Scan and report` Bash block (required by the [inline-sync architecture](#known-caller-side-constraints)),
which interacts badly with actionlint's ShellCheck orchestration. The hang is a
tool limitation, **not** a workflow syntax error, and it is pre-existing on
`main`. The wrapper disables that integration (`actionlint -shellcheck=
-pyflakes=`) so structural linting completes deterministically. ShellCheck still
runs as a **separate, optional** signal against the source scripts.

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
    uses: j7an/shared-workflows/.github/workflows/tag-release.yml@v4
    secrets:
      RELEASE_BOT_PRIVATE_KEY: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}
  publish:
    needs: tag
    uses: j7an/shared-workflows/.github/workflows/release.yml@v4
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
    uses: j7an/shared-workflows/.github/workflows/tag-release.yml@v4
    with:
      bump: ${{ inputs.bump }}
    secrets:
      RELEASE_BOT_PRIVATE_KEY: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}
  publish:
    needs: tag
    uses: j7an/shared-workflows/.github/workflows/release.yml@v4
    with:
      tag: ${{ needs.tag.outputs.tag }}
```

### Auto-bumping version files at release time

If your repo has version strings in committed JSON files (e.g. `server.json`, `package.json`), `tag-release.yml` can rewrite them as part of the release commit. Add a `.version-bump.json` at repo root listing the files and locations to update. See [`.github/workflows/README.md` › Version file bumping](.github/workflows/README.md#version-file-bumping-version-bumpjson) for the schema, examples, and security model.

### Required downstream setup

1. **Create a `release` GitHub Environment**, restricted to the `main` branch via deployment branch policy (Settings → Environments → New environment → Deployment branches → Selected branches → `main`).
2. **Make `RELEASE_BOT_PRIVATE_KEY` available as `secrets.RELEASE_BOT_PRIVATE_KEY`** in the caller repo. The sample snippets work with a repo-level Actions secret; if you scope release credentials to the `release` environment, keep the same secret name there so the caller can forward it unchanged.
3. **Set `vars.RELEASE_BOT_APP_ID`** as a repo variable pointing at the Release Bot GitHub App's numeric App ID.
4. **Install the Release Bot App on the repo** with `Contents: Read and write` permission (see [Release Bot App setup](#release-bot-app-setup) above for provisioning).

The `environment: release` + `if: github.ref == 'refs/heads/main'` gate inside `tag-release.yml` runs in **your repo's** security context — `shared-workflows` cannot unilaterally enforce it across consumers. If you skip step 1, you lose the environment-side branch policy and secret protection; the in-file `if:` check still blocks non-`main` refs, but the extra GitHub-side gate is gone.

### On the `@v4` pin

`@v4` is the floating major tag for the current `v4.x.y` line. It always
points at the latest `v4.x.y` release because `release.yml` force-updates
floating majors on every publish. Pinning to `@v4` means you get all
non-breaking updates within v4 automatically. Pin to `@v4.0` for patch-only
updates, or `@v4.0.0` for an immutable freeze — see the [Versioning](#versioning)
section above.

`@v3` is the previous line, frozen at the last release where post-PR
release-age verification was on by default and auto-merge was opt-in. `@v2`
is the frozen historical cooldown-bearing line. Both continue to work but
receive no further updates — see [v3 → v4 migration](#v3--v4-migration).
