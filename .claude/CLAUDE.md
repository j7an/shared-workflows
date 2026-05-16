# CLAUDE.md

This file provides repository guidance for AI coding agents working in this repository.

## What this repo is

`j7an/shared-workflows` publishes **reusable GitHub Actions workflows** that other repos consume via `uses: j7an/shared-workflows/.github/workflows/<file>@v2`. There is no application code — the deliverables are the workflow YAMLs in `.github/workflows/` and the bash logic in `scripts/`.

## Commands

```bash
bats tests/                                  # run the full test suite
bats tests/extract-deps.bats                 # run one test file
bats tests/extract-deps.bats --filter "name" # run tests whose name matches a substring
./scripts/check-inline-sync.sh               # verify embedded inline bash == scripts/*.sh
./scripts/lint-workflow-call.sh              # verify workflow_call files use no caller-context refs
```

All three checks above run in `ci-scripts.yml` on every PR touching `scripts/`, `tests/`, or `.github/workflows/`. Tests are [bats](https://github.com/bats-core/bats-core); fixtures live under `tests/fixtures/<script-name>/`.

## The inline-sync invariant (most important architectural constraint)

A reusable workflow cannot reliably check out *its own* repo's scripts: in a `workflow_call` context, `github.sha` / `github.ref` / `github.workflow_sha` all resolve to the **caller's** repo, not this one. So each `scripts/*.sh` is **embedded verbatim** inside the workflow YAML that uses it, between sentinel markers:

```
# --- BEGIN inline:scripts/extract-deps.sh ---
...embedded copy...
# --- END inline:scripts/extract-deps.sh ---
```

`scripts/*.sh` is the source of truth; the inline copy is a derived artifact. **Editing a script means updating its inline copy too**, or `check-inline-sync.sh` fails CI. The sync is byte-for-byte after known normalizations (10-space YAML indent strip, shebang strip, function-wrapper strip). The pairs are listed in `check-inline-sync.sh` (`INLINE_PAIRS`):

- `dependency-cooldown.yml` embeds `extract-deps.sh`, `check-release-age.sh`, `diff-touches-lockfile.sh`, `pr-body-to-deps.sh`
- `tag-release.yml` embeds `bump-version-files.sh`

`lint-workflow-call.sh` is the partner guard: it fails CI if any `workflow_call` file reintroduces a caller-scoped ref as a checkout `ref:`.

## Workflows and their roles

**Consumer-facing reusable workflows:**

- `dependency-cooldown.yml` — scans Dependabot PRs. Pipeline: parse diff → `extract-deps.sh` (with `pr-body-to-deps.sh` as fallback when the diff yields zero rows, and `diff-touches-lockfile.sh` as a fail-loud guard so a clean-but-wrong extraction can't produce a false-green gate) → `check-release-age.sh` for the cooldown gate → GHSA/OSV advisory scan → single update-or-create comment + label reconciliation.
- `cooldown-rescan.yml` — scheduled re-scan of PRs stuck in the `pending` cooldown state.
- `tag-release.yml` — computes the next semver tag from Conventional Commits, optionally runs `bump-version-files.sh` against `.version-bump.json`, creates the tag via the GitHub Git Data API (so commits/tags auto-sign under the App identity). Requires a GitHub App key (`RELEASE_BOT_PRIVATE_KEY` secret, `RELEASE_BOT_APP_ID` var).
- `publish-pypi.yml` — `uv build` → TestPyPI (with install verification) → PyPI via OIDC trusted publishing → GitHub Release.

**Release machinery for this repo itself:** `release-self.yml` (manual `workflow_dispatch`) → calls `tag-release.yml` → calls `release.yml`. `release.yml` is `workflow_call`-only (no `push: tags` trigger) and floats the major/minor tags (`v2` → `v2.3` → `v2.3.1`). Merging to `main` does **not** auto-release; a release is always a deliberate `release-self.yml` dispatch.

**CI:** `ci-scripts.yml` (bats + inline-sync + workflow-call lint), `ci-cooldown.yml` (dogfoods `dependency-cooldown.yml` on this repo's own Dependabot PRs), `security.yml` (zizmor workflow analysis).

## Conventions

- **Bash 3.2 compatible** — scripts run on macOS system bash; no associative arrays, no `mapfile`/`readarray`.
- **Actions are SHA-pinned** with a trailing `# vX.Y.Z` comment. When bumping, dereference the tag to the *commit* SHA, not the tag-object SHA.
- **Conventional Commits drive release bumps** — `tag-release.yml`'s `auto` mode infers patch/minor/major from commit subjects since the last tag. A stray `feat:` in an otherwise-`fix:` PR flips a patch release to minor.
- `scripts/*.sh` read stdin and write TSV/line-oriented stdout; exit `2` signals malformed input, exit `0` covers the zero-rows case. See each script's header comment for its exact schema.
- Specs and plans under `docs/superpowers/` are working notes — untracked, never committed. `.worktrees/` (gitignored) holds isolated checkouts for parallel feature work.
