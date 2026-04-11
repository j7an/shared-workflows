# Publish GitHub Release on Tag Push

**Status:** Approved
**Date:** 2026-04-11

## Problem

The repo ships versioned reusable workflows via semver tags (`v1.0.0` through
`v1.2.4`), but has never published corresponding GitHub Releases. Consequences:

- The repo's Releases page is empty, making it look unmaintained.
- Tools keyed off the GitHub Releases API (Dependabot/Renovate release-note
  hooks, changelog aggregators) see nothing despite active shipping.
- Consumers browsing the repo get no changelog for each tag.

The automation pipeline already fires on every semver tag push
(`release.yml`, which currently only updates floating `v1` / `v1.2` tags)
— it just never learned to publish Releases.

## Goals

1. **Backfill:** Create a GitHub Release for each of the 7 existing semver
   tags (`v1.0.0` … `v1.2.4`).
2. **Automate:** Every future tag produced by `auto-tag.yml` results in a
   matching GitHub Release within seconds.
3. **Idempotent:** Re-running either path must not error or duplicate.
4. **Honest timestamps:** GitHub does not permit retroactive `published_at`,
   so backfilled Releases must carry the original tag date in a visible
   place (title + notes banner).

## Non-goals

- Creating a separate `publish-release.yml` workflow file.
- Modifying `auto-tag.yml`.
- Custom release-note content — GitHub's `--generate-notes` auto-changelog
  (PRs merged since the previous tag) is sufficient.
- Prerelease / draft handling.

## Design

### Component boundaries (unchanged)

- **`auto-tag.yml`** — sole responsibility: PR merge → create semver tag.
  Untouched.
- **`release.yml`** — renamed in-file from *Update Floating Version Tags* to
  *Publish Release*. Sole responsibility: semver tag push → (update floating
  tags, publish Release). Filename stays `release.yml` to preserve any
  external references.

### Backfill (one-shot, local)

Executed from an operator's shell with `gh` authenticated against the repo:

```bash
for tag in v1.0.0 v1.1.0 v1.2.0 v1.2.1 v1.2.2 v1.2.3 v1.2.4; do
  gh release view "$tag" >/dev/null 2>&1 && continue
  TAG_DATE=$(git for-each-ref --format='%(creatordate:short)' "refs/tags/$tag")
  gh release create "$tag" \
    --title "$tag ($TAG_DATE)" \
    --generate-notes \
    --verify-tag
  GENERATED=$(gh release view "$tag" --json body -q .body)
  BANNER="> _Originally tagged **$TAG_DATE**. Release entry created retroactively from an existing git tag._"
  gh release edit "$tag" --notes "$(printf '%s\n\n%s' "$BANNER" "$GENERATED")"
done
```

Key decisions:

- **Two-phase create/edit** because `gh release create` silently ignores
  `--generate-notes` when `--notes` is also supplied. Creating first with
  auto-notes, then reading the body and editing it back with a prepended
  banner, gives us both without a curl/jq dance.
- **`%(creatordate:short)`** picks the tag object's creation date for
  annotated tags (these are all annotated — created by the `auto-tag.yml`
  bot) and falls back to the commit date for lightweight tags.
- **Title carries the date** (`v1.0.0 (2026-04-03)`) so readers see it in
  the Releases sidebar without opening the release.
- **`--verify-tag`** refuses to create a Release if the tag doesn't exist on
  the remote, preventing typos from silently creating phantom tags.

### Ongoing automation (workflow change)

One new step appended to the existing `publish-release` job in `release.yml`,
placed **after** the floating-tag update:

```yaml
- name: Publish GitHub Release
  env:
    GH_TOKEN: ${{ github.token }}
    TAG: ${{ github.ref_name }}
  run: |
    if gh release view "$TAG" >/dev/null 2>&1; then
      echo "Release $TAG already exists, skipping"
      exit 0
    fi
    gh release create "$TAG" \
      --title "$TAG" \
      --generate-notes \
      --verify-tag
    echo "Published release $TAG"
```

Key decisions:

- **Order:** floating-tag update first, Release publication second. By the
  time the Release surfaces in the Releases page, the `v1` / `v1.2` pointers
  already reflect the new patch — a consumer seeing the Release and
  immediately pinning `@v1` gets a consistent view.
- **Default step coupling** (no `if: always()`): if floating-tag update
  fails, the Publish step is skipped. Floating-tag failure signals something
  wrong (usually permissions) that should also block Release publication so
  a human notices.
- **No date-in-title for automated releases** — timestamps will be accurate
  (tag push → Release within seconds).
- **Permissions:** `contents: write` is already present on the job — same
  scope `gh release create` needs.
- **Trigger:** unchanged `on.push.tags: ['v*.*.*']`. Floating tags use
  non-semver patterns (`v1`, `v1.2`) and are force-pushed, so no re-trigger
  risk.

## Failure modes

| Failure | Behavior |
|---|---|
| Release already exists (re-run, backfill overlap) | `gh release view` short-circuits with exit 0 — idempotent |
| Tag doesn't exist on remote | `--verify-tag` makes creation fail loudly instead of creating a phantom tag |
| `--generate-notes` finds no previous tag (first-ever release) | GitHub falls back to "since repo creation" — acceptable |
| Floating-tag step fails | Publish Release step is skipped (default GH Actions step coupling); acceptable by design |
| GitHub API timeout / rate limit | Step fails; re-running the workflow is safe (idempotent via pre-check) |

## Why GitHub won't let us set a retroactive publish timestamp

The REST and GraphQL APIs for creating a Release do not accept a
client-supplied `published_at`. The field is stamped server-side at
creation time, by design — retroactive timestamps would let anyone rewrite
the Releases-page activity feed (backdating security fixes, vesting claims,
etc.). We work around this by putting the real tag date in (1) the Release
title and (2) a notes banner above the auto-generated changelog, so humans
see the truth even though the API timestamp says "now".

## Rollout

1. Run the backfill loop locally against `origin/main` — creates 7 Releases.
2. Land this spec + the `release.yml` edit via a PR against `main`,
   using a `feat:` commit so `auto-tag.yml` produces a minor bump (`v1.3.0`).
3. On merge, the freshly-merged `release.yml` publishes a matching GitHub
   Release for `v1.3.0`, proving the end-to-end automation works against
   the very change that introduced it.
