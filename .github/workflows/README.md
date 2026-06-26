# Reusable Workflows

This directory hosts reusable workflows under `j7an/shared-workflows`. Consumers reference them via `uses: j7an/shared-workflows/.github/workflows/<file>@v4`.

> **Note:** `@v3` and `@v2` continue to work at their last-released revisions, but receive no further updates. See the root README's "v3 → v4 migration" section.

## `security-scan.yml`

Runs the shared security scanning baseline for sibling repos: CodeQL,
TruffleHog, Zizmor, Trivy, and OSV. The workflow is `workflow_call`-only; each
consumer keeps its own local `push`, `pull_request`, `schedule`, and optional
`merge_group` triggers in a thin caller.

### Caller permission ceiling

The caller job must grant the permission ceiling. The reusable workflow narrows
permissions per scanner job, but a called workflow cannot grant itself
permissions the caller withheld.

```yaml
permissions: {}

jobs:
  security:
    permissions:
      actions: read
      contents: read
      security-events: write
    uses: j7an/shared-workflows/.github/workflows/security-scan.yml@v4
```

### Full caller

This is the full scanner bundle without merge queue support.

```yaml
name: Security Scanning

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  schedule:
    - cron: "0 6 * * 1"

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

permissions: {}

jobs:
  security:
    permissions:
      actions: read
      contents: read
      security-events: write
    uses: j7an/shared-workflows/.github/workflows/security-scan.yml@v4
```

Repos with a protected merge queue add the caller trigger and opt in to
`merge_group` scanning:

```yaml
on:
  merge_group:
    branches: [main]

jobs:
  security:
    with:
      support_merge_group: true
```

Repos that want CodeQL's quality query set can also pass:

```yaml
jobs:
  security:
    with:
      codeql_queries: +security-and-quality
```

### Minimal caller

Use this shape for repos that want CodeQL, TruffleHog, Zizmor, and Trivy but do
not want OSV scans.

```yaml
name: Security

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  schedule:
    - cron: "0 6 * * 1"

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

permissions: {}

jobs:
  security:
    permissions:
      actions: read
      contents: read
      security-events: write
    uses: j7an/shared-workflows/.github/workflows/security-scan.yml@v4
    with:
      run_osv_full: false
      run_osv_pr: false
```

### Node repos

For npm, pnpm, yarn, or bun repos, keep lockfiles committed and change only the
CodeQL language when CodeQL is enabled. Do not pass package-manager inputs to
this reusable workflow, because OSV and Trivy read committed manifests and lockfiles
directly:

```yaml
jobs:
  security:
    permissions:
      actions: read
      contents: read
      security-events: write
    uses: j7an/shared-workflows/.github/workflows/security-scan.yml@v4
    with:
      codeql_language: javascript-typescript
```

`npx` is an invocation style, not dependency metadata. OSV and Trivy scan
committed manifests and lockfiles such as `package-lock.json`,
`pnpm-lock.yaml`, `yarn.lock`, and text `bun.lock`. Older binary `bun.lockb`
is not part of the supported lockfile set.

### CodeQL default setup

Set `run_codeql: false` if the consumer repo uses GitHub CodeQL default setup
or another CodeQL workflow. GitHub rejects advanced-configuration CodeQL
analyses when default setup owns CodeQL processing for the repo.

### Required checks

Only require checks that actually run on the protected event. If a repo marks a
scanner job as required but disables that scanner, or requires OSV PR on an
event where OSV PR is intentionally skipped, GitHub can wait forever for an
expected check that will never report.

### Fork pull requests

Use `pull_request`, not `pull_request_target`, for this scanner workflow. Fork
PRs should not run untrusted code under a privileged token. GitHub may restrict
`security-events: write` on fork PRs, so SARIF upload from CodeQL, Trivy, and
OSV can be limited on those runs.

## `dependency-safety-non-bot-gate.yml`

Posts the required `dependency-safety / gate` commit status for pull requests
whose author is not `dependabot[bot]`. This is a status-only companion for
repos whose real `dependency-safety.yml` scanner caller is gated to
Dependabot-only.

The reusable workflow is `workflow_call`-only. The consumer keeps the trusted
`pull_request_target` trigger in a tiny local wrapper:

```yaml
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

Pair it with a scanner caller that uses the complementary condition:

```yaml
jobs:
  safety:
    if: github.event.pull_request.user.login == 'dependabot[bot]'
    uses: j7an/shared-workflows/.github/workflows/dependency-safety.yml@v4
    secrets: inherit
```

The wrapper must not check out code, pass `secrets: inherit`, install
dependencies, or run PR-authored files. The wrapper grants `statuses: write`;
the reusable workflow requests `statuses: write`; the status is posted to
`github.event.pull_request.head.sha` with context `dependency-safety / gate`.

## `tag-release.yml`

Computes the next semver tag from Conventional Commits since the last tag, optionally bumps version files, and pushes the new tag (which typically triggers a downstream release workflow).

### Inputs

| Input | Type | Required | Default | Description |
|---|---|---|---|---|
| `bump` | string | no | `auto` | Semver bump (`auto` / `patch` / `minor` / `major`). `auto` infers from Conventional Commits. |
| `tag-prefix` | string | no | `"v"` | Tag prefix. Use `"v"` for `v1.2.3`, `"tools/v"` for `tools/v1.2.3`, etc. Allowed chars: `[A-Za-z0-9._/-]`. |

### Secrets

| Secret | Required | Purpose |
|---|---|---|
| `RELEASE_BOT_PRIVATE_KEY` | yes | GitHub App private key. App ID is read from `vars.RELEASE_BOT_APP_ID`. |

### Monorepo example (two release streams)

```yaml
# .github/workflows/release-plugin.yml — plugin stream (v*.*.*)
on:
  workflow_dispatch:
    inputs:
      bump: { type: choice, options: [auto, patch, minor, major], default: auto }

jobs:
  tag:
    uses: j7an/shared-workflows/.github/workflows/tag-release.yml@v4
    with:
      bump: ${{ inputs.bump }}
      # tag-prefix omitted → defaults to "v" → produces v1.2.3
    secrets:
      RELEASE_BOT_PRIVATE_KEY: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}
```

```yaml
# .github/workflows/release-tools.yml — tools stream (tools/v*.*.*)
on:
  workflow_dispatch:
    inputs:
      bump: { type: choice, options: [auto, patch, minor, major], default: auto }

jobs:
  tag:
    uses: j7an/shared-workflows/.github/workflows/tag-release.yml@v4
    with:
      bump: ${{ inputs.bump }}
      tag-prefix: "tools/v"   # produces tools/v0.1.0
    secrets:
      RELEASE_BOT_PRIVATE_KEY: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}
```

The two streams compute next-version independently — `tools/v` callers see only `tools/v*.*.*` tags when looking up the previous version, never `v*.*.*`.

### Version file bumping (`.version-bump.json`)

Optional. If a file named `.version-bump.json` exists at the repo root, the workflow updates the listed JSON files with the new version *before* creating the tag. The bumped files are committed and pushed to `main` as a separate `chore(release): bump version files to <version>` commit. The new tag points at that commit.

If `.version-bump.json` is absent, the bumper step is a no-op.

#### Schema

```json
{
  "files": [
    { "path": "<relative-path>", "field": "<top-level-key>" },
    { "path": "<relative-path>", "path_expr": "<jq-path>" }
  ]
}
```

Each entry must contain exactly one of `field` or `path_expr` (mutually exclusive).

| Key | Purpose |
|---|---|
| `path` | Path relative to repo root. Must end in `.json`. Absolute paths and `..` traversal rejected. |
| `field` | Top-level key to update. Shorthand for `path_expr: ".<field>"`. Any string value safe (passed to jq as a literal). |
| `path_expr` | jq-style path expression. Validated against a strict allowlist before use — see "Allowed path_expr syntax" below. |

#### Examples

**Top-level field (legacy form):**

```json
{ "files": [ { "path": "package.json", "field": "version" } ] }
```

**Nested path — same file, multiple locations:**

```json
{
  "files": [
    { "path": "server.json", "path_expr": ".version" },
    { "path": "server.json", "path_expr": ".packages[0].version" }
  ]
}
```

**Scoped or hyphenated dependency keys** (npm, Composer, Helm):

```json
{
  "files": [
    { "path": "package.json", "path_expr": ".dependencies[\"@scope/pkg\"].version" }
  ]
}
```

**Update every element of an array** (jq's `[]` iterator):

```json
{
  "files": [
    { "path": "server.json", "path_expr": ".packages[].version" }
  ]
}
```

#### Allowed `path_expr` syntax

- `.identifier` — top-level key (`.version`, `._private`)
- `.identifier.identifier` — nested key (`.metadata.semver`)
- `.identifier[N]` — non-negative integer index (`.packages[0]`)
- `.identifier["string-key"]` — bracket-quoted string key (`.dependencies["@scope/pkg"]`). Content allowlist: letters, digits, `.`, `_`, `@`, `/`, `-`. Covers npm scoped packages, Composer `vendor/package`, Helm kebab-case values.
- `.identifier[]` — jq iterator; updates every element of an array (`.packages[].version` sets `.version` on every package entry)
- Combinations (`.packages[0].version`, `.foo.bar[2].baz`, `.dependencies["lodash.debounce"].version`, `.packages[].version`)

The first segment must be `.identifier`. Identifiers follow `[A-Za-z_][A-Za-z0-9_]*`. Bracket-quoted string keys and the `[]` iterator can appear anywhere after the first segment.

#### Rejected syntax (security boundary)

The validator rejects pipes (`|`), JSONPath-style wildcards (`[*]`), slices (`[2:5]`), negative indices (`[-1]`), recursive descent (`..`), variable references (`$ENV`), format strings (`@sh`), parens, arithmetic, dot-quoted keys (`."weird-key"`), leading-bracket keys at the root (`.["key"]`), and single-quoted keys (`['key']`). Empty or whitespace-containing quoted keys (`[""]`, `["a b"]`) are also rejected. Path expressions originate from repo-committed config but are still validated as a defense-in-depth measure.

**Note on `[*]` vs. `[]`:** jq's iterate-all operator is `[]`, not `[*]` (the latter is JSONPath, not jq). Use `.packages[].version` to update every element's `.version` (or `.foo[]` in general).

#### Step summary

The workflow run summary includes a per-entry table:

| File | Path | Version | Status |
|---|---|---|---|
| `server.json` | `.version` | `0.8.1` -> `0.10.0` | updated |
| `server.json` | `.packages[0].version` | `0.8.1` -> `0.10.0` | updated |
| `package.json` | `.version` | `0.10.0` | already up to date |

## `publish-pypi.yml`

Builds a Python package with `uv build`, stages on TestPyPI with install verification, promotes to production PyPI via OIDC trusted publishing, and creates a GitHub Release.

### Inputs

| Input | Type | Required | Default | Description |
|---|---|---|---|---|
| `tag` | string | yes | — | Semver tag to publish (e.g. `tools/v0.1.0`). |
| `package-dir` | string | no | `.` | Directory containing `pyproject.toml` (relative to repo root). |
| `testpypi-package` | string | yes | — | Distribution name on TestPyPI for install verification. |
| `draft-release` | boolean | no | `false` | Create the GitHub release as a draft. |
| `attach-assets` | boolean | no | `true` | Attach wheel + sdist to the GitHub release. |

### Secrets

None. OIDC handles publishing; `GITHUB_TOKEN` handles the release.

### Pipeline

1. **build** — `uv build` produces wheel + sdist; uploaded as `pypi-dist` artifact. Includes a tag-on-main guard.
2. **publish-testpypi** (`environment: testpypi`) — publishes to TestPyPI; verifies install in a clean venv with exponential backoff (5 attempts at 30/60/90/120/150s).
3. **publish-pypi** (`environment: pypi`) — publishes to production PyPI.
4. **github-release** — creates a GitHub release with auto-generated notes; attaches artifacts; auto-detects prerelease from `-` in tag.

### Caller example

```yaml
# .github/workflows/release-tools.yml — tag-driven publish
on:
  push:
    tags:
      - 'tools/v*.*.*'

jobs:
  publish:
    uses: j7an/shared-workflows/.github/workflows/publish-pypi.yml@v4
    with:
      tag: ${{ github.ref_name }}
      package-dir: tools
      testpypi-package: epiphany-tools
```

### Per-package onboarding checklist

For each new PyPI package that uses this workflow, complete **once**:

- [ ] Claim the package name on [PyPI](https://pypi.org/) and [TestPyPI](https://test.pypi.org/).
- [ ] On PyPI, configure trusted publisher: workflow `j7an/shared-workflows/.github/workflows/publish-pypi.yml`, ref `v4`, environment `pypi`.
- [ ] On TestPyPI, configure the same trusted publisher with environment `testpypi`.
- [ ] Confirm GitHub Environments `testpypi` and `pypi` exist in `j7an/shared-workflows` repo settings.

### Recovery from a failed publish

PyPI never lets you re-publish the same version, even after deletion. If a publish fails:

- **TestPyPI fail, PyPI not yet attempted:** the workflow halts; recover by tagging a new prerelease (`tools/v0.1.0-rc2`) once the underlying issue is fixed.
- **PyPI fail after TestPyPI success:** rare; usually a transient GitHub→PyPI handshake problem. Re-run the failed job from the Actions UI. If it persists, tag a new patch.
- **GitHub release fail after PyPI success:** the package is live on PyPI; manually create the release with `gh release create` against the same tag, or re-run the `github-release` job (note: `gh release create` is not idempotent — if a release already exists for the tag, the re-run will fail with "release already exists" and you'll need to use `gh release edit` to update it).
