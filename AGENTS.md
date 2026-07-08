# Project Instructions

This file provides repository guidance for AI coding agents working in this repository.

## What this repo is

`j7an/shared-workflows` publishes **reusable GitHub Actions workflows** that other repos consume via `uses: j7an/shared-workflows/.github/workflows/<file>@v4`. There is no application code — the deliverables are the workflow YAMLs in `.github/workflows/` and the bash logic in `scripts/`.

## Commands

```bash
bats tests/                                  # run the full test suite
bats tests/extract-deps.bats                 # run one test file
bats tests/extract-deps.bats --filter "name" # run tests whose name matches a substring
./scripts/check-inline-sync.sh               # verify embedded inline bash == scripts/*.sh
./scripts/lint-workflow-call.sh              # verify workflow_call files use no caller-context refs
./scripts/lint-workflows.sh                  # actionlint structural lint (non-hanging mode)
```

The bats, inline-sync, and workflow-call checks run in `ci-scripts.yml` on every PR touching `scripts/`, `tests/`, or `.github/workflows/`. `lint-workflows.sh` is **local-only**: plain `actionlint` hangs on `dependency-safety.yml` (its large inlined `Scan and report` block × actionlint's ShellCheck orchestration), so the wrapper runs `actionlint -shellcheck= -pyflakes=`. Its bats contract test runs in CI, but actionlint itself is not installed there. ShellCheck is a **separate, optional** signal (`shellcheck scripts/*.sh`) with known info-level findings — not part of this gate. Tests are [bats](https://github.com/bats-core/bats-core); fixtures live under `tests/fixtures/<script-name>/`.

## The inline-sync invariant (most important architectural constraint)

A reusable workflow cannot reliably check out *its own* repo's scripts: in a `workflow_call` context, `github.sha` / `github.ref` / `github.workflow_sha` all resolve to the **caller's** repo, not this one. So each `scripts/*.sh` is **embedded verbatim** inside the workflow YAML that uses it, between sentinel markers:

```
# --- BEGIN inline:scripts/extract-deps.sh ---
...embedded copy...
# --- END inline:scripts/extract-deps.sh ---
```

`scripts/*.sh` is the source of truth; the inline copy is a derived artifact. **Editing a script means updating its inline copy too**, or `check-inline-sync.sh` fails CI. The sync is byte-for-byte after known normalizations (10-space YAML indent strip, shebang strip, function-wrapper strip). The pairs are listed in `check-inline-sync.sh` (`INLINE_PAIRS`):

- `dependency-safety.yml` embeds `extract-deps.sh`, `check-release-age.sh`, `diff-touches-lockfile.sh`, `pr-body-to-deps.sh`, `classify-touched-paths.sh`, `pyproject-bump-extract.sh`, and `safety-verdict.sh`
- `tag-release.yml` embeds `bump-version-files.sh`

`lint-workflow-call.sh` is the partner guard: it fails CI if any `workflow_call` file reintroduces a caller-scoped ref as a checkout `ref:`.

## Workflows and their roles

**Consumer-facing reusable workflows:**

- `dependency-safety.yml` — scans each Dependabot PR for advisories; post-PR release-age verification is opt-in via `release_age_policy` (default `"off"`; `advisory` labels + suppresses auto-merge, `blocking` fails the gate), and `auto_merge` defaults to `true`. Pipeline: extract → fallback → guard → age check (policy-gated) → GHSA/OSV scan → scorecard → comment → labels; the verdict layer is deterministic: `failure` on age violation only under `blocking`, `error` on extraction/scan failure, `success` otherwise. Verdict translation lives in `safety-verdict.sh`. No rescan companion — verifier is single-shot per PR event.
- `tag-release.yml` — computes the next semver tag from Conventional Commits, optionally runs `bump-version-files.sh` against `.version-bump.json`, creates any bump commit through the GitHub Git Data API, verifies that workflow-created bump commit before advancing `main`, then creates the release tag as a lightweight ref to the target commit. Requires a GitHub App key (`RELEASE_BOT_PRIVATE_KEY` secret, `RELEASE_BOT_APP_ID` var). Do not assume GitHub auto-signs annotated tag objects.
- `publish-pypi.yml` — `uv build` → TestPyPI (with install verification) → PyPI via OIDC trusted publishing → GitHub Release.

**Release machinery for this repo itself:** `release-self.yml` (manual `workflow_dispatch`) → calls `tag-release.yml` → calls `release.yml`. `release.yml` is `workflow_call`-only (no `push: tags` trigger) and floats the major/minor tags (`v2` → `v2.3` → `v2.3.1`) as lightweight refs to the release target commit.

### Release provenance guardrails

- GitHub App-created release bump commits can verify when created through the Git Data API without custom author/committer fields; keep that verification as a hard gate before `main` advances.
- Release tags and floating major/minor tags should be lightweight refs to the target commit. Do not assume GitHub auto-signs annotated tag objects.
- Distinguish tag refs, tag objects, and peeled target commits when reviewing release changes.
- Target commit verification is reported for provenance, but it is not a hard gate when the target is the caller/analyzed commit; consumer repos may legitimately have unverified commits.
- Do not rely on runner default Python in release verification jobs. Make the interpreter explicit.
- For TestPyPI plus PyPI verification with uv, use an ephemeral project with a TestPyPI source pin for the package under test. Do not use `uv pip install --index-url TestPyPI --extra-index-url PyPI` for this check.
- Require downstream canary evidence before declaring release workflow changes fixed.

**CI:** `ci-scripts.yml` (bats + inline-sync + workflow-call lint), `ci-safety.yml` (dogfoods `dependency-safety.yml` on this repo's own Dependabot PRs), `security.yml` (zizmor workflow analysis).

## Conventions

- **Bash 3.2 compatible** — scripts run on macOS system bash; no associative arrays, no `mapfile`/`readarray`.
- **Actions are SHA-pinned** with a trailing `# vX.Y.Z` comment. When bumping, dereference the tag to the *commit* SHA, not the tag-object SHA.
- Workflow contract tests for action pins should assert semantic policy: expected action target, full-length commit SHA, and trailing `# vX.Y.Z` comment. Do not snapshot the current SHA/version literally unless exact equality is the behavior being protected; when exact equality is intentional, say why in the test name or nearby comment and keep Dependabot grouping aligned.
- **Conventional Commits drive release bumps** — `tag-release.yml`'s `auto` mode infers patch/minor/major from commit subjects since the last tag. A stray `feat:` in an otherwise-`fix:` PR flips a patch release to minor.
- `scripts/*.sh` read stdin and write TSV/line-oriented stdout; exit `2` signals malformed input, exit `0` covers the zero-rows case. See each script's header comment for its exact schema.
- Specs and plans under `docs/superpowers/` are working notes — untracked, never committed. `.worktrees/` (gitignored) holds isolated checkouts for parallel feature work.
