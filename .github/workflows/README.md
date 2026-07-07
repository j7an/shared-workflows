# Reusable Workflows

This directory hosts reusable workflows under `j7an/shared-workflows`. Consumers reference them via `uses: j7an/shared-workflows/.github/workflows/<file>@v4`.

> **Note:** `@v3` and `@v2` continue to work at their last-released revisions, but receive no further updates. See the root README's "v3 → v4 migration" section.

## `pre-commit-autoupdate.yml`

Runs `pre-commit autoupdate` for consumer repos, detects changes to the
configured pre-commit config file, and opens a dependency-update pull request.
The workflow is `workflow_call`-only: each caller keeps its own schedule,
manual dispatch trigger, branch filters, and optional concurrency.

The runner path is language-neutral but uv-runner scoped. The consumer repo
needs a pre-commit config file (defaults to `.pre-commit-config.yaml` via
`config_path`); it does not need to be a Python or uv project because the
reusable workflow installs uv and runs `uvx`.

### Recommended App-token caller

Use this shape for repos with required checks or branch protection. The caller
repository must define `vars.RELEASE_BOT_APP_ID` and the
`RELEASE_BOT_PRIVATE_KEY` secret.

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

Pass the private key explicitly rather than using `secrets: inherit`. The App
token is minted inside the reusable workflow with contents and pull-request
write scopes, while the caller's automatic `GITHUB_TOKEN` remains read-only.

### Minimal GITHUB_TOKEN fallback caller

Use this shape only for repos that accept the trigger caveat or have no
required checks on the generated PRs.

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
      contents: write
      pull-requests: write
    uses: j7an/shared-workflows/.github/workflows/pre-commit-autoupdate.yml@v4
```

No App var and no private-key secret are passed. If PR creation fails with a
403 in this mode, grant `contents: write` and `pull-requests: write` on the
caller job.

GITHUB_TOKEN-authored PRs may not trigger required CI automatically due to
GitHub's recursion guard. If checks do not start, close and reopen the PR or
push an empty commit. Prefer the App-token caller for repos with required
checks.

### Inputs

| Input | Type | Required | Default | Description |
|---|---|---|---|---|
| `config_path` | string | no | `.pre-commit-config.yaml` | File to check for changes and, when `restrict_paths` is true, the only path committed. |
| `branch` | string | no | `deps/pre-commit-autoupdate` | Pull request branch. |
| `title` | string | no | `deps: update pre-commit hooks` | Pull request title. |
| `commit_message` | string | no | `deps: update pre-commit hooks` | Commit message for hook updates. |
| `labels` | string | no | `dependencies` | Labels passed to `create-pull-request`. |
| `sign_commits` | boolean | no | `true` | Whether `create-pull-request` signs commits. |
| `restrict_paths` | boolean | no | `true` | When true, passes `add-paths: config_path` so only the pre-commit config is committed. |
| `pre_commit_version` | string | no | `""` | Optional pre-commit runner version. Empty uses latest; set it as a regression circuit-breaker. |

`delete-branch: true` is standardized by the reusable workflow, so recurring
automation branches are cleaned up after merge.

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

### Inputs

| Input | Type | Required | Default | Description |
|---|---|---|---|---|
| `run_codeql` | boolean | no | `true` | Run CodeQL analysis. Set to `false` for repos using CodeQL default setup or another CodeQL workflow. |
| `run_trufflehog` | boolean | no | `true` | Run TruffleHog verified-secret scanning. |
| `run_zizmor` | boolean | no | `true` | Run Zizmor workflow analysis as a blocking console gate. |
| `run_trivy` | boolean | no | `true` | Run Trivy filesystem vulnerability scanning. |
| `run_osv_full` | boolean | no | `true` | Run OSV full scans on `push` and `schedule`. |
| `run_osv_pr` | boolean | no | `true` | Run OSV PR diff scans on `pull_request`. Never runs on `merge_group`. |
| `codeql_language` | string | no | `"python"` | Single CodeQL language token. Use `javascript-typescript` for Node callers. |
| `codeql_queries` | string | no | `"security-extended"` | CodeQL query suite. Use `+security-and-quality` to include quality queries. |
| `zizmor_online_audits` | boolean | no | `true` | Enable Zizmor online audits, including vulnerable-action checks. |
| `support_merge_group` | boolean | no | `false` | Allow general scanners on `merge_group`; unsupported `merge_group` callers fail closed. |

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
`merge_group` scanning. If a caller triggers on `merge_group` without
`support_merge_group: true`, the reusable workflow fails closed instead of
silently reporting a green no-op run. OSV full remains limited to `push` and
`schedule`; OSV PR remains limited to `pull_request`, so do not require OSV
checks on `merge_group`.

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

### Node callers

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

## `publish-npm.yml`

Builds one npm tarball with `npm pack --json`, publishes that verified tarball
to npm through npm trusted publishing, verifies registry visibility, optionally
runs a caller-owned install check, and creates or updates a GitHub Release with
the same `*.tgz` attached.

### Trusted Publishing status

This reusable workflow is intentionally supported for npm trusted publishing
under npm's current GitHub Actions semantics.

This differs from the PyPI guidance below. PyPI currently does not authorize a
cross-repo reusable workflow as the Trusted Publisher workflow, so new PyPI
package repos should use the caller-owned template. npm validates the caller workflow filename for `workflow_call` releases, not the reusable workflow
that contains the `npm publish` command. That means each package repo configures
npm trusted publishing against its own caller workflow, while the shared publish
logic can live in `j7an/shared-workflows`.

If npm changes this validation model to require the workflow containing
`npm publish`, revisit this workflow and move npm publishing to a caller-owned
template.

### Inputs

| Input | Type | Required | Default | Description |
|---|---|---|---|---|
| `tag` | string | yes | - | Semver tag to publish, such as `v1.2.3`. |
| `package-name` | string | yes | - | npm package name used for registry verification. |
| `test-command` | string | no | `""` | Optional pre-pack command run in the caller checkout. |
| `pack-contents-script` | string | no | `""` | Optional script run as `sh <script> pack.json` after `npm pack --json`. |
| `verify-command` | string | no | `""` | Optional post-registry verification command run with `PACKAGE` and `VERSION` in the environment. |

If `npm pack` depends on installed dependencies, generated files, or lifecycle
scripts such as `prepare` or `prepack`, include the required setup in
`test-command`, for example `npm ci && npm test && npm run build`. The reusable
workflow does not run `npm ci` by default because not every npm package uses a
lockfile or a build step.

### Caller setup

The caller workflow must grant:

```yaml
permissions:
  contents: write
  id-token: write
```

Configure the npm trusted publisher in the package settings, not in this repo:

- Repository: the package repo, for example `j7an/superpowers-wrapper`
- Workflow filename: the workflow filename in the package repo, for example
  `release.yml`
- Environment: `npm`
- Allowed actions: `npm publish` only, not `npm stage publish`

npm trusted publishing requires npm CLI `>= 11.5.1`; the reusable workflow
enforces that floor before publishing. Do not pass `--provenance` or set
`NPM_CONFIG_PROVENANCE`. npm generates provenance automatically for a public package
published from a public repository through trusted publishing.

### Example caller

```yaml
name: Publish npm

on:
  push:
    tags:
      - "v*.*.*"

permissions:
  contents: write
  id-token: write

jobs:
  publish:
    uses: j7an/shared-workflows/.github/workflows/publish-npm.yml@v4
    with:
      tag: ${{ github.ref_name }}
      package-name: superpowers-wrapper
      test-command: sh tests/run.sh
      pack-contents-script: tests/assert_pack_contents.sh
      verify-command: |
        OUT=$(npx --yes "${PACKAGE}@${VERSION}" --version)
        test "$OUT" = "$VERSION"
```

For packages without a CLI or install smoke test, omit `verify-command`. The
workflow still verifies that `npm view <package>@<version> version` returns
success before creating the GitHub Release.

## `publish-pypi.yml`

Builds a Python package with `uv build`, stages on TestPyPI with install
verification, promotes to production PyPI via OIDC trusted publishing, and
creates a GitHub Release.

> **Trusted Publishing status:** this reusable workflow is not supported for
> PyPI/TestPyPI Trusted Publishing from package repos. Current PyPI behavior
> does not authorize cross-repo reusable workflows as Trusted Publisher
> workflows: the caller repo owns the OIDC repository claim, while the called
> workflow path points at `j7an/shared-workflows`.

Long-lived API-token publishing is intentionally out of scope for this repo's
recommended PyPI release path. Keep package publish jobs in the package repo and
use the caller-owned template below for Trusted Publishing.

The workflow file remains in this repo for compatibility with the published
`@v4` surface. Do not use it as the trusted-publisher workflow for new package
releases.

### Inputs

| Input | Type | Required | Default | Description |
|---|---|---|---|---|
| `tag` | string | yes | - | Semver tag to publish, such as `tools/v0.1.0` or `v1.2.3`. |
| `package-dir` | string | no | `.` | Directory containing `pyproject.toml` relative to repo root. |
| `testpypi-package` | string | yes | - | Distribution name on TestPyPI for install verification. |
| `draft-release` | boolean | no | `false` | Create the GitHub release as a draft. |
| `attach-assets` | boolean | no | `true` | Attach wheel and sdist to the GitHub release. |

### Compatibility note

If PyPI later supports cross-repo reusable workflows as Trusted Publisher
workflows, reassess whether this reusable workflow should become the recommended
path again. Until then, prefer the caller-owned template.

## Caller-owned PyPI Trusted Publishing template

Use this pattern in each package repo that publishes to TestPyPI and PyPI with
Trusted Publishing. The caller repo owns the workflow identity, GitHub
Environments, PyPI Trusted Publisher records, and any package-specific jobs.

### One-time package setup

- Claim the package name on [PyPI](https://pypi.org/) and
  [TestPyPI](https://test.pypi.org/).
- Create GitHub Environments `testpypi` and `pypi` in the package repo.
- Configure PyPI Trusted Publisher for the package repo, the workflow path of
  the caller-owned release workflow, and environment `pypi`.
- Configure TestPyPI Trusted Publisher for the package repo, the same workflow
  path, and environment `testpypi`.
- Copy `scripts/derive-published-version.sh` and
  `scripts/classify-prerelease.sh` into the package repo, or embed their bodies
  directly in the local workflow steps.

Use normalized tag tails such as `v1.2.3`, `tools/v1.2.3`, `v1.2.3rc1`, or
`tools/v1.2.3rc1`. Do not tag prereleases as `v1.2.3-rc1`; the build guard
requires the tag tail to exactly equal the normalized version emitted by the
wheel.

The standard trigger shown below matches only plain tags (`v*.*.*`). If your
tag stream is path-prefixed (for example `tools/v`), add the matching trigger
pattern (for example `tools/v*.*.*`) so pushes to `tools/v1.2.3` trigger this
release workflow.

### Standard release workflow

```yaml
name: Release Python Package

on:
  push:
    tags:
      - 'v*.*.*'   # for plain tags like `v1.2.3`

permissions:
  contents: read

concurrency:
  group: pypi-release-${{ github.ref_name }}
  cancel-in-progress: false

env:
  PACKAGE_NAME: example-pkg
  PACKAGE_DIR: .
  VERIFY_COMMAND: example-pkg --version
  DRAFT_RELEASE: "true"
  ATTACH_ASSETS: "true"

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Harden runner
        uses: step-security/harden-runner@9af89fc71515a100421586dfdb3dc9c984fbf411 # v2.19.4
        with:
          egress-policy: audit

      - name: Checkout at tag
        uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0
        with:
          ref: ${{ github.ref_name }}
          fetch-depth: 0

      - name: Verify tag is ancestor of main
        env:
          TAG: ${{ github.ref_name }}
        run: |
          TAG_SHA=$(git rev-list -n1 "$TAG")
          git fetch origin main
          if ! git merge-base --is-ancestor "$TAG_SHA" origin/main; then
            echo "::error::Tag ${TAG} (${TAG_SHA}) is not an ancestor of origin/main"
            exit 1
          fi

      - name: Set up uv
        uses: astral-sh/setup-uv@fac544c07dec837d0ccb6301d7b5580bf5edae39 # v8.2.0

      - name: Build wheel and sdist
        working-directory: ${{ env.PACKAGE_DIR }}
        run: uv build

      - name: Verify built version matches tag
        env:
          TAG: ${{ github.ref_name }}
        run: bash scripts/derive-published-version.sh "${PACKAGE_DIR}/dist" "$TAG"

      - name: Upload dist artifact
        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1
        with:
          name: pypi-dist
          path: ${{ env.PACKAGE_DIR }}/dist/
          if-no-files-found: error
          retention-days: 7

  publish-testpypi:
    needs: build
    runs-on: ubuntu-latest
    environment:
      name: testpypi
      url: https://test.pypi.org/p/example-pkg
    permissions:
      id-token: write
      attestations: write
    steps:
      - name: Harden runner
        uses: step-security/harden-runner@9af89fc71515a100421586dfdb3dc9c984fbf411 # v2.19.4
        with:
          egress-policy: audit

      - name: Download dist artifact
        uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1
        with:
          name: pypi-dist
          path: dist/

      - name: Publish to TestPyPI
        uses: pypa/gh-action-pypi-publish@cef221092ed1bacb1cc03d23a2d87d1d172e277b # v1.14.0
        with:
          repository-url: https://test.pypi.org/legacy/
          packages-dir: dist/
          skip-existing: false

  verify-testpypi:
    needs: publish-testpypi
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - name: Harden runner
        uses: step-security/harden-runner@9af89fc71515a100421586dfdb3dc9c984fbf411 # v2.19.4
        with:
          egress-policy: audit

      - name: Set up uv
        uses: astral-sh/setup-uv@fac544c07dec837d0ccb6301d7b5580bf5edae39 # v8.2.0

      - name: Verify install from TestPyPI
        env:
          PACKAGE_NAME: ${{ env.PACKAGE_NAME }}
          VERIFY_COMMAND: ${{ env.VERIFY_COMMAND }}
          VERSION_TAG: ${{ github.ref_name }}
        run: |
          VERSION="${VERSION_TAG##*/}"
          VERSION="${VERSION#v}"
          echo "Verifying TestPyPI install of ${PACKAGE_NAME}==${VERSION}"

          INSTALLED=false
          ATTEMPT=0
          for SLEEP_SECONDS in 30 60 90 120 150; do
            ATTEMPT=$((ATTEMPT + 1))
            echo "Attempt ${ATTEMPT}/5: sleeping ${SLEEP_SECONDS}s before install..."
            sleep "$SLEEP_SECONDS"
            rm -rf .verify
            uv venv .verify
            . .verify/bin/activate
            if uv pip install \
              --index-url https://test.pypi.org/simple/ \
              --extra-index-url https://pypi.org/simple/ \
              "${PACKAGE_NAME}==${VERSION}"; then
              INSTALLED=true
              break
            fi
            echo "Attempt ${ATTEMPT} failed; retrying."
          done

          if [ "$INSTALLED" != "true" ]; then
            echo "::error::TestPyPI install verification failed after 5 attempts"
            exit 1
          fi

          if [ -n "${VERIFY_COMMAND:-}" ]; then
            if ! VERIFY_OUTPUT=$(bash -euo pipefail -c "$VERIFY_COMMAND" 2>&1); then
              printf '%s\n' "$VERIFY_OUTPUT"
              echo "::error::Verification command failed"
              exit 1
            fi
            printf '%s\n' "$VERIFY_OUTPUT"
            case "$VERIFY_OUTPUT" in
              *"$VERSION"*) ;;
              *)
                echo "::error::Verification command output did not contain version '${VERSION}'"
                exit 1
                ;;
            esac
          fi

  publish-pypi:
    needs: verify-testpypi
    runs-on: ubuntu-latest
    environment:
      name: pypi
      url: https://pypi.org/p/example-pkg
    permissions:
      id-token: write
      attestations: write
    steps:
      - name: Harden runner
        uses: step-security/harden-runner@9af89fc71515a100421586dfdb3dc9c984fbf411 # v2.19.4
        with:
          egress-policy: audit

      - name: Download dist artifact
        uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1
        with:
          name: pypi-dist
          path: dist/

      - name: Publish to PyPI
        uses: pypa/gh-action-pypi-publish@cef221092ed1bacb1cc03d23a2d87d1d172e277b # v1.14.0
        with:
          packages-dir: dist/

  github-release:
    needs: publish-pypi
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - name: Harden runner
        uses: step-security/harden-runner@9af89fc71515a100421586dfdb3dc9c984fbf411 # v2.19.4
        with:
          egress-policy: audit

      - name: Checkout at tag
        uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0
        with:
          ref: ${{ github.ref_name }}

      - name: Download dist artifact
        if: env.ATTACH_ASSETS == 'true'
        uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1
        with:
          name: pypi-dist
          path: dist/

      - name: Create GitHub Release
        env:
          GH_TOKEN: ${{ github.token }}
          TAG: ${{ github.ref_name }}
          VERSION_TAG: ${{ github.ref_name }}
        run: |
          VERSION="${VERSION_TAG##*/}"
          VERSION="${VERSION#v}"
          IS_PRERELEASE=$(bash scripts/classify-prerelease.sh "$VERSION")

          ARGS=( "$TAG" --generate-notes --title "$TAG" )
          if [ "$IS_PRERELEASE" = "true" ]; then
            ARGS+=( --prerelease )
          fi
          if [ "$DRAFT_RELEASE" = "true" ]; then
            ARGS+=( --draft )
          fi
          if [ "$ATTACH_ASSETS" = "true" ]; then
            ARGS+=( dist/*.whl dist/*.tar.gz )
          fi

          gh release create "${ARGS[@]}"
```

Set TestPyPI `skip-existing: true` only when rerun ergonomics are worth the
freshness tradeoff: enabling it can let verification install an old same-version
artifact already present on TestPyPI. Do not set `skip-existing` on the
production PyPI publish step.

The verification command is caller-controlled shell text. Pass it through
`env:` and execute it intentionally with `bash -euo pipefail -c
"$VERIFY_COMMAND"`; it must never be interpolated directly into `run:`.

### Add a pre-publish CI gate

For packages that run tests before publishing, add a local `test` job and make
`build` depend on it:

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - name: Harden runner
        uses: step-security/harden-runner@9af89fc71515a100421586dfdb3dc9c984fbf411 # v2.19.4
        with:
          egress-policy: audit
      - uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0
      - uses: astral-sh/setup-uv@fac544c07dec837d0ccb6301d7b5580bf5edae39 # v8.2.0
      - run: uv run ruff check .
      - run: uv run mypy .
      - run: uv run pytest

  build:
    needs: test
```

### Migration parity table

| To reproduce this behavior | Template setting |
|---|---|
| Release stays a draft for human publish | Set `DRAFT_RELEASE: "true"` so `gh release create` receives `--draft`. |
| Post-install runs console script and asserts version | Set `VERIFY_COMMAND`, for example `example-pkg --version`. |
| TestPyPI re-upload is skipped for reruns | Set TestPyPI `skip-existing: true`, acknowledging the freshness tradeoff. |
| Install verification targets the package name | Set `PACKAGE_NAME` to the PyPI/TestPyPI distribution name. |
| Deployment UI links are preserved | Set caller-local `environment.url` values on `publish-testpypi` and `publish-pypi`. |
| MCP Registry publish runs after package release | Keep a caller-local MCP job gated on `github-release` success. |

MCP Registry publishing remains caller-local. A package such as `nexus-mcp`
should keep its MCP job in the package repo with its own `id-token: write`
permission and gate it on the local release workflow result.

### Recovery from a failed publish

PyPI never lets you re-publish the same version, even after deletion. If a
publish fails:

- **TestPyPI fail, PyPI not yet attempted:** fix the issue, then tag a new
  prerelease or intentionally rerun with TestPyPI `skip-existing: true` when
  the existing TestPyPI artifact is the artifact you meant to verify.
- **PyPI fail after TestPyPI success:** re-run the failed job from the Actions
  UI if the failure was transient. If the version was rejected as already
  existing, tag a new patch or prerelease.
- **GitHub release fail after PyPI success:** the package is live on PyPI.
  Create or repair the release with the first-party `gh` CLI. `gh release
  create` fails loudly when the release already exists.
