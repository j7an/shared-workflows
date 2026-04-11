# Release Process Overhaul

**Status:** Approved
**Date:** 2026-04-11

## Problem

Two defects in the current release flow:

1. **Empty Releases page.** Semver tags (`v1.0.0` … `v1.2.4`) exist but no
   corresponding GitHub Releases. The repo looks unmaintained, Dependabot /
   Renovate release-note hooks see nothing, humans browsing the repo get no
   changelog.
2. **Release-per-merge is wasteful.** `auto-tag.yml` triggers on every
   merged PR and produces a `v*.*.*` tag. A week of 4 dependabot PRs
   becomes 4 tags, 4 Releases, 4 floating-tag force-pushes, each carrying a
   one-line changelog. The semver contract (a bump is a deliberate statement
   about compatibility) gets diluted into "every merge is a patch."

Both stem from the same underlying issue: **no human cadence controls
when a release happens.** Conventional-commit heuristics guess at bump
severity, and the trigger is every merge regardless of whether a coherent
set of changes has accumulated.

## Goals

1. **Publish GitHub Releases for all existing tags** (one-time backfill).
2. **Publish GitHub Releases automatically whenever a semver tag is pushed**,
   independent of how the tag got there (human, workflow, manual push).
3. **Replace merge-triggered tagging with operator-initiated dispatch.**
   The operator picks `auto | patch | minor | major` from a dropdown in the
   GitHub Actions UI. Multiple merged PRs accumulate on `main` and ship in
   one coherent release when the operator decides.
4. **Preserve the conventional-commit heuristic** — it's useful as a
   *default* (`auto` mode) even if not as the only path.
5. **Fail loudly on empty deltas** — no ghost releases when nothing has
   changed since the last tag.

## Non-goals

- Prerelease / draft releases.
- Custom release-note templates (`--generate-notes` is sufficient).
- Rolling release PRs à la `release-please`.
- GitHub Environments / required-reviewer approval flow (overkill for a
  solo-maintained repo where tag deletion is cheap).
- Dry-run / preview mode (fire-and-forget with a rich step summary is
  recoverable enough).

## Design

### Component boundaries

```
         operator clicks "Run workflow" in Actions UI
                          |
                          v
  +-----------------------------------------+
  | tag-release.yml  (workflow_dispatch)    |   <-- was auto-tag.yml
  |                                         |
  | - read inputs.bump (auto/patch/         |
  |   minor/major)                          |
  | - analyze commits since last tag        |
  | - compute next version                  |
  | - git tag -a + git push origin v*.*.*   |
  +-----------------------------------------+
                          |
                          | (tag push event)
                          v
  +-----------------------------------------+
  | release.yml      (on: push.tags)        |   <-- existing, renamed
  |                                         |       "Publish Release"
  | - update floating v1 / v1.2 tags        |
  | - gh release create --generate-notes    |
  |   (idempotent via gh release view)      |
  +-----------------------------------------+
```

- **`tag-release.yml`** (renamed from `auto-tag.yml`) — sole responsibility:
  operator-initiated tag creation. Does not publish Releases, does not update
  floating tags.
- **`release.yml`** (renamed display name: *Publish Release*) — sole
  responsibility: react to `v*.*.*` tag pushes by (1) updating floating
  `v1` / `v1.2` pointers and (2) publishing a GitHub Release with
  auto-generated notes. Does not know or care who pushed the tag.
- **PR merges** — no side effects on release state. Commits land on `main`,
  nothing else happens until an operator dispatches.

This separation means: if someone ever `git push origin v2.0.0` manually
(bypassing `tag-release.yml`), `release.yml` still fires and publishes the
Release. And if someone disables `release.yml`, `tag-release.yml` still
creates the tag — no cascading failures.

### `tag-release.yml` — full behavior

**Trigger:** `workflow_dispatch` only. Input:

```yaml
bump:
  type: choice
  required: true
  default: auto
  options: [auto, patch, minor, major]
```

**Safety gates:**
- `if: github.ref == 'refs/heads/main'` at job level — refuses to run from
  non-main branches (workflow_dispatch lets the operator pick any branch
  in the UI, so we gate explicitly).
- `concurrency.group: tag-release` with `cancel-in-progress: false` —
  serializes parallel dispatches instead of killing in-flight ones.
  (`cancel-in-progress: true` would leave half-finished tag state.)
- `permissions: contents: write` — minimum scope for tag push.

**Compute step logic (pseudocode):**

```
LATEST = git tag -l 'v*.*.*' --sort=-version:refname | head -1
if empty: LATEST = v0.0.0 (first-release bootstrap)

RANGE = LATEST..HEAD (or HEAD if first release)
SUBJECTS = git log --format='%s' $RANGE
FULL     = git log --format='%s%n%b' $RANGE   # for BREAKING CHANGE detection

if commit count == 0:
  write step summary: "Release blocked: no commits since $LATEST"
  error exit

# Analyze
ANALYSIS = patch
if FULL matches '^[a-z]+(\(.+\))?!:'  -> ANALYSIS = major (breaking, ! suffix)
elif FULL contains 'BREAKING CHANGE'  -> ANALYSIS = major (breaking, body)
elif FULL matches '^feat(\(.+\))?:'   -> ANALYSIS = minor

# Resolve
if CHOICE == auto:
  CHOSEN = ANALYSIS
else:
  CHOSEN = CHOICE
  if CHOSEN != ANALYSIS:
    emit override warning in step summary

# Bump
parse LATEST into MAJOR, MINOR, PATCH
apply CHOSEN
NEXT_TAG = vMAJOR.MINOR.PATCH

# Report
write $GITHUB_STEP_SUMMARY:
  - source, next tag, chosen bump
  - analysis result + reason
  - override warning (if applicable)
  - list of commits since LATEST
```

**Tag-create step:** plain `git tag -a "$NEXT_TAG" -m "Release $NEXT_TAG"`
followed by `git push origin "$NEXT_TAG"`, using the `github-actions[bot]`
identity. No `gh release` calls here — those are `release.yml`'s job.

### `release.yml` — unchanged from prior design

Renamed display name from *Update Floating Version Tags* to *Publish
Release* (file stays `release.yml`). Two steps:

1. **Update floating major and minor tags** (existing) — force-push `v1` and
   `v1.2` to point at the new patch.
2. **Publish GitHub Release** (new in this PR) — idempotent via
   `gh release view` pre-check, then `gh release create --title "$TAG"
   --generate-notes --verify-tag`.

Ordering: floating tags first, Release second. Consumers seeing the
Release and pinning `@v1` get a consistent view.

### Backfill (already executed)

One-shot local `gh` loop run against the live repo during implementation
(not committed anywhere — a backfill workflow file would sit unused after
the one-time run):

```bash
for tag in v1.0.0 v1.1.0 v1.2.0 v1.2.1 v1.2.2 v1.2.3 v1.2.4; do
  gh release view "$tag" >/dev/null 2>&1 && continue
  TAG_DATE=$(git for-each-ref --format='%(creatordate:short)' "refs/tags/$tag")
  gh release create "$tag" \
    --title "$tag ($TAG_DATE)" --generate-notes --verify-tag
  GENERATED=$(gh release view "$tag" --json body -q .body)
  BANNER="> _Originally tagged **$TAG_DATE**. Release entry created retroactively from an existing git tag._"
  gh release edit "$tag" --notes "$(printf '%s\n\n%s' "$BANNER" "$GENERATED")"
done
```

Why the title carries the date: GitHub's API won't accept a retroactive
`published_at`, so backfilled releases stamp "now" at creation. Putting
the original tag date in the title and the notes banner makes the truth
visible to humans even though the API timestamp lies.

Why two-phase create/edit: `gh release create --notes X --generate-notes`
silently drops `--generate-notes` when `--notes` is also supplied. Creating
first with auto-notes, then reading the body and re-writing it with a
banner prepended, gets both.

## Failure modes

| Failure | Behavior |
|---|---|
| No commits since last tag (empty delta) | `tag-release.yml` errors out with "Release blocked: no commits since $LATEST"; no tag created |
| Operator picks bump contradicting analysis (e.g. `patch` when analysis says `major`) | Tag created at operator's pick; step summary shows non-blocking override warning |
| Dispatch from non-main branch | Job is skipped (`if: github.ref == 'refs/heads/main'`); Actions UI shows "skipped" with the condition |
| Two operators dispatch simultaneously | `concurrency.group: tag-release` serializes; second waits for first |
| First-ever release (no prior tag) | `LATEST` bootstraps to `v0.0.0`; auto analysis still runs |
| `gh release create` fails (API timeout, rate limit) | `release.yml` step fails; re-running the workflow is safe (idempotent via `gh release view`) |
| Release already exists for tag (backfill overlap, manual re-run) | `gh release view` short-circuits with exit 0 — idempotent |
| Floating-tag update fails | Default GH Actions step coupling: Publish Release step is skipped. Acceptable — floating-tag failure usually signals permissions problems that should also block Release publication |
| `--generate-notes` finds no previous tag (first-ever release) | GitHub falls back to "since repo creation" |
| Operator dispatches with a typo'd tag (shouldn't happen — workflow computes it) | `--verify-tag` refuses to create a Release for a nonexistent tag |

## Why GitHub won't accept retroactive `published_at`

The REST and GraphQL APIs for creating a Release do not accept a
client-supplied `published_at`. The field is stamped server-side at
creation time, by design — retroactive timestamps would let anyone
rewrite the Releases-page activity feed (backdating security fixes,
vesting claims, etc.). We work around this by putting the real tag date
in (1) the Release title and (2) a notes banner above the auto-generated
changelog.

## Why manual dispatch, not release-please or semantic-release

Both of those tools solve a similar problem (batch merges into coherent
releases, bump from conventional commits) but add significant complexity:
release-please maintains a rolling PR that auto-updates, semantic-release
ships a full plugin ecosystem. For a small shared-workflows repo with a
solo maintainer and ~1 release/week cadence, a 100-line bash workflow
that does one thing (compute next version, push tag) is dramatically
easier to reason about, debug, and evolve than either tool.

The conventional-commit heuristic (reused as the `auto` default)
gives us the 80% convenience of semantic-release without adopting its
entire worldview. If the heuristic ever misfires, the explicit-override
path is right there in the same dropdown.

## Rollout

1. **Backfill done out-of-band** — 7 Releases created against existing tags
   via local `gh` loop during spec execution. Visible at
   `/releases` immediately.
2. **Land this PR** (amended `feat/publish-github-release`) which carries:
   - `release.yml` rename + new Publish step
   - `auto-tag.yml` -> `tag-release.yml` rename + full rewrite
   - This spec doc
3. **Post-merge validation:**
   - Verify `tag-release.yml` appears in Actions -> Run workflow dropdown
   - Dispatch with `bump=auto` (or `minor` explicitly) — should compute
     `v1.3.0` from the merged `feat:` commits on this branch
   - Confirm `release.yml` fires automatically on the new tag push
   - Confirm `v1.3.0` Release appears on the Releases page with auto-generated notes
   - Confirm floating `v1` and `v1.2` tags updated to `v1.3.0`
4. **Rollback plan** (if the new flow misbehaves): `git revert` this PR's
   merge commit on `main`, `git push origin :v1.3.0` to delete the bad tag,
   `gh release delete v1.3.0` to clean up the Release. Everything is
   reversible in under a minute.
