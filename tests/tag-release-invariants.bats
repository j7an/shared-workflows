#!/usr/bin/env bats

# tag-release-invariants.bats — static checks on the rewritten Git Data API
# blocks in .github/workflows/tag-release.yml.
#
# Spec §2 invariant: the rewritten "Bump version files" and "Create and push
# tag" steps must never depend on a post-checkout local-state read for
# deciding what SHA to use as a commit parent, what SHA to update main to,
# or what SHA to tag. The single load-bearing SHA value is $GITHUB_SHA,
# captured once.

setup() {
  REPO_ROOT="$BATS_TEST_DIRNAME/.."
  WORKFLOW="$REPO_ROOT/.github/workflows/tag-release.yml"
}

# Extract the YAML body of a step by name, up to the next "      - name:" boundary.
extract_step_body() {
  local name="$1"
  awk -v marker="      - name: $name" '
    index($0, marker) == 1 { inside=1; next }
    inside && /^      - name: / { inside=0 }
    inside { print }
  ' "$WORKFLOW"
}

@test "invariant: 'Bump version files' step contains no post-checkout local-state git reads" {
  body=$(extract_step_body "Bump version files")
  [ -n "$body" ]
  # Spec §2 forbids ALL post-checkout local-state git reads — the same set
  # in both the bump step and the tag step. `git log` is included even though
  # the bump step doesn't currently call it, to prevent future regressions
  # (e.g., "look up the parent commit's date" via local git instead of API).
  for forbidden in 'git rev-parse' 'git symbolic-ref' 'git for-each-ref' 'git describe' 'git log'; do
    if printf '%s' "$body" | grep -qF "$forbidden"; then
      printf 'VIOLATION: "%s" appears in Bump version files step (spec §2)\n' "$forbidden"
      printf '%s\n' "$body" | grep -nF "$forbidden"
      false
    fi
  done
}

@test "invariant: 'Create and push tag' step contains no post-checkout local-state git reads" {
  body=$(extract_step_body "Create and push tag")
  [ -n "$body" ]
  for forbidden in 'git rev-parse' 'git symbolic-ref' 'git for-each-ref' 'git describe' 'git log'; do
    if printf '%s' "$body" | grep -qF "$forbidden"; then
      printf 'VIOLATION: "%s" appears in Create and push tag step (spec §2)\n' "$forbidden"
      printf '%s\n' "$body" | grep -nF "$forbidden"
      false
    fi
  done
}

@test "invariant: 'Bump version files' step uses GITHUB_SHA as commit parent" {
  body=$(extract_step_body "Bump version files")
  # After Phase B rewrite, BASE_SHA must be derived from GITHUB_SHA, not from
  # GET /git/ref/heads/main (which would race per spec §2). Skip this check
  # if the step still uses git push (Phase A only — pre-Phase-B baseline).
  if printf '%s' "$body" | grep -qF 'git push origin HEAD:main'; then
    skip "Phase A baseline — bump step still uses git push; check applies after Phase B"
  fi
  # Assert the full load-bearing chain, not merely that GITHUB_SHA appears
  # somewhere — a stray `echo "$GITHUB_SHA"` must NOT satisfy this test:
  #   GITHUB_SHA  ->  BASE_SHA  ->  jq --arg parent  ->  commit payload
  printf '%s' "$body" | grep -qF 'BASE_SHA="${GITHUB_SHA}"' || {
    echo "VIOLATION: bump step does not bind BASE_SHA to GITHUB_SHA (spec §2 / §3.1 step 1)"
    false
  }
  # `--` ends grep option parsing so the leading `--arg` is treated as a
  # pattern, not a flag.
  printf '%s' "$body" | grep -qF -- '--arg parent "$BASE_SHA"' || {
    echo "VIOLATION: commit-create jq call does not wire its parent arg from BASE_SHA"
    false
  }
  printf '%s' "$body" | grep -qF 'parents: [$parent]' || {
    echo "VIOLATION: commit payload does not build parents from the \$parent arg"
    false
  }
}

@test "invariant: 'Bump version files' step never reads a live ref for the tag target" {
  body=$(extract_step_body "Bump version files")
  [ -n "$body" ]
  # Spec §2 / review Finding 1: the no-bump (exit 2) path must tag the
  # semver-analyzed commit (GITHUB_SHA), never a fresh `GET /git/ref/heads/...`
  # read — that races with concurrent pushes and can tag an unanalyzed commit.
  # The discriminator is the singular/plural ref endpoint form: the legitimate
  # fast-forward PATCH uses the PLURAL `git/refs/heads/main`; only the
  # SINGULAR-`ref` GET form (`git/ref/heads/`) is forbidden here.
  if printf '%s' "$body" | grep -qF 'git/ref/heads/'; then
    echo "VIOLATION: Bump step performs a live 'GET .../git/ref/heads/' read (spec §2 / Finding 1)"
    printf '%s' "$body" | grep -nF 'git/ref/heads/'
    false
  fi
}

@test "invariant: bump-commit and tag payloads omit author/committer/tagger fields" {
  # Strip comment-only lines first — the workflow code's own commentary
  # legitimately mentions these field names (e.g., "NO author/committer
  # fields — auto-signs"). The test enforces that the words appear ONLY
  # in comments, never in code positions where they could become real
  # identity overrides via a jq object literal, gh api -f/-F/--field flag,
  # or YAML key.
  body_bump=$(extract_step_body "Bump version files" | grep -v '^[[:space:]]*#')
  body_tag=$(extract_step_body "Create and push tag" | grep -v '^[[:space:]]*#')
  if printf '%s' "$body_bump" | grep -qF 'git push origin HEAD:main'; then
    skip "Phase A baseline — checks apply after Phase B"
  fi
  # Word-boundary match catches every escape hatch: "author", 'author',
  # author: (jq literal), -f author=, -F author=, --field author=.
  # If a real workflow change needs one of these field names in code
  # for a non-identity-override reason, the test must be updated
  # deliberately, with a comment explaining why.
  for field in 'author' 'committer'; do
    if printf '%s' "$body_bump" | grep -qE "\\b${field}\\b"; then
      echo "VIOLATION: '$field' appears in Bump step (non-comment context) — disables auto-signing if used as a payload field name (spec §3.3)"
      printf '%s' "$body_bump" | grep -nE "\\b${field}\\b"
      false
    fi
  done
  if printf '%s' "$body_tag" | grep -qE '\btagger\b'; then
    echo "VIOLATION: 'tagger' appears in Tag step (non-comment context) — disables auto-signing if used as a payload field name (spec §3.3)"
    printf '%s' "$body_tag" | grep -nE '\btagger\b'
    false
  fi
}
