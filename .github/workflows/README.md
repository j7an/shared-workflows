# Reusable Workflows

This directory hosts reusable workflows under `j7an/shared-workflows`. Consumers reference them via `uses: j7an/shared-workflows/.github/workflows/<file>@v2`.

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
    uses: j7an/shared-workflows/.github/workflows/tag-release.yml@v2
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
    uses: j7an/shared-workflows/.github/workflows/tag-release.yml@v2
    with:
      bump: ${{ inputs.bump }}
      tag-prefix: "tools/v"   # produces tools/v0.1.0
    secrets:
      RELEASE_BOT_PRIVATE_KEY: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}
```

The two streams compute next-version independently — `tools/v` callers see only `tools/v*.*.*` tags when looking up the previous version, never `v*.*.*`.

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
    uses: j7an/shared-workflows/.github/workflows/publish-pypi.yml@v2
    with:
      tag: ${{ github.ref_name }}
      package-dir: tools
      testpypi-package: epiphany-tools
```

### Per-package onboarding checklist

For each new PyPI package that uses this workflow, complete **once**:

- [ ] Claim the package name on [PyPI](https://pypi.org/) and [TestPyPI](https://test.pypi.org/).
- [ ] On PyPI, configure trusted publisher: workflow `j7an/shared-workflows/.github/workflows/publish-pypi.yml`, ref `v2`, environment `pypi`.
- [ ] On TestPyPI, configure the same trusted publisher with environment `testpypi`.
- [ ] Confirm GitHub Environments `testpypi` and `pypi` exist in `j7an/shared-workflows` repo settings.

### Recovery from a failed publish

PyPI never lets you re-publish the same version, even after deletion. If a publish fails:

- **TestPyPI fail, PyPI not yet attempted:** the workflow halts; recover by tagging a new prerelease (`tools/v0.1.0-rc2`) once the underlying issue is fixed.
- **PyPI fail after TestPyPI success:** rare; usually a transient GitHub→PyPI handshake problem. Re-run the failed job from the Actions UI. If it persists, tag a new patch.
- **GitHub release fail after PyPI success:** the package is live on PyPI; manually create the release with `gh release create` against the same tag, or re-run the `github-release` job (note: `gh release create` is not idempotent — if a release already exists for the tag, the re-run will fail with "release already exists" and you'll need to use `gh release edit` to update it).
