#!/usr/bin/env bats

. "$BATS_TEST_DIRNAME/helpers/action-pin-assertions.bash"

WF=".github/workflows/pnpm-packagemanager-update.yml"

@test "workflow is workflow_call only" {
  run grep -cE '^on:|^  workflow_call:' "$WF"
  [ "$output" -eq 2 ]
  run grep -cE '^  (push|pull_request|schedule|workflow_dispatch):' "$WF"
  [ "$output" -eq 0 ]
}

@test "workflow declares empty top-level permissions" {
  run grep -c '^permissions: {}' "$WF"
  [ "$output" -eq 1 ]
}

@test "both inline pairs are registered" {
  run grep -c "pnpm-packagemanager-update.yml:scripts/packagemanager-bump.sh" scripts/check-inline-sync.sh
  [ "$output" -eq 1 ]
  run grep -c "pnpm-packagemanager-update.yml:scripts/packagemanager-integrity.sh" scripts/check-inline-sync.sh
  [ "$output" -eq 1 ]
}

@test "both inline sentinel blocks are present" {
  for s in packagemanager-bump packagemanager-integrity; do
    run grep -c "# --- BEGIN inline:scripts/${s}.sh ---" "$WF"
    [ "$output" -eq 1 ]
    run grep -c "# --- END inline:scripts/${s}.sh ---" "$WF"
    [ "$output" -eq 1 ]
  done
}

@test "the main step carries the id every downstream reference reads" {
  # Tasks 10 and 12 read steps.update.outputs.*; without `id: update` each of
  # those resolves to empty, the skip guard never fires, and the PR step runs
  # on a no-op. Same defect class as the `id: cpr` omission.
  # Anchored at end-of-line: an unanchored 'id: update' also matches a
  # prefix-sharing rename like `id: update2`, which would leave
  # `steps.update.outputs.*` resolving to empty at runtime without reddening
  # this test.
  run grep -c 'id: update$' "$WF"
  [ "$output" -eq 1 ]
}

@test "App auth is gated on the preflight output, not the secrets context" {
  # `secrets` is not available in a step-level `if:`, so gating on it does not
  # gate. pre-commit-autoupdate.yml:169 establishes the working pattern.
  run grep -c "auth_mode == 'app'" "$WF"
  [ "$output" -ge 1 ]
  run grep -cE "^ *if: .*secrets\." "$WF"
  [ "$output" -eq 0 ]
}

@test "the PR is restricted to the manifest path" {
  # -F is REQUIRED, not stylistic: `{{ ... }}` is a regex brace expression, so
  # the plain `grep -c` this test originally used returns 0 against a file that
  # DOES contain the line, and the test could never pass. Verified 2026-08-07:
  # `grep -c 'add-paths: ${{ ... }}'` -> 0, `grep -cF` -> 1.
  run grep -cF 'add-paths: ${{ steps.update.outputs.manifest_path }}' "$WF"
  [ "$output" -eq 1 ]
}

@test "add-paths and the verify comparison read the same normalized path" {
  # `./package.json` passes validation but `gh api .../pulls/{n}/files` reports
  # the normalized `package.json`, so reading inputs.manifest_path in either
  # place fails the verify step AFTER the pull request already exists. The
  # normalized output from the update step is the single source for both.
  run grep -cF 'MANIFEST: ${{ steps.update.outputs.manifest_path }}' "$WF"
  [ "$output" -eq 1 ]
  run grep -cF '${{ inputs.manifest_path }}' "$WF"
  [ "$output" -eq 1 ]
  # ...and that one remaining use is the update step's own input.
  run grep -cF 'INPUT_MANIFEST_PATH: ${{ inputs.manifest_path }}' "$WF"
  [ "$output" -eq 1 ]
}

@test "the evidence status is gated on the pull request, not on the head SHA" {
  # Gating on pull-request-head-sha let a run that created a PR but reported no
  # head SHA skip the status and go green: a pull request with no evidence.
  run grep -cF "if: steps.update.outputs.skip != 'true' && steps.cpr.outputs.pull-request-number != ''" "$WF"
  [ "$output" -eq 1 ]
  run grep -cE "^ *if: .*pull-request-head-sha != ''" "$WF"
  [ "$output" -eq 0 ]
}

@test "the create-pull-request step carries the id the status step reads" {
  # Anchored at end-of-line for the same reason as the `id: update` test
  # above: an unanchored 'id: cpr' also matches a prefix-sharing rename like
  # `id: cprX`.
  run grep -c 'id: cpr$' "$WF"
  [ "$output" -eq 1 ]
  run grep -c 'steps.cpr.outputs.pull-request-head-sha' "$WF"
  [ "$output" -ge 1 ]
}

@test "the evidence status uses its own context, not the shared gate" {
  # Bound to the `-f context=` argument rather than to the string appearing
  # anywhere in the file: the missing-head-SHA error message names the context
  # too, so a mention count broke on prose edits instead of contract edits.
  # -e is REQUIRED: the pattern starts with `-f`, which grep would otherwise
  # consume as its own "patterns from file" flag.
  run grep -cF -e '-f context="pnpm-packageManager / evidence"' "$WF"
  [ "$output" -eq 1 ]
  # dependency-safety-non-bot-gate.yml also writes that context on this PR;
  # sharing it is a write race that can erase the evidence.
  run grep -c 'dependency-safety / gate' "$WF"
  [ "$output" -eq 0 ]
}

@test "the status description length is asserted, not assumed" {
  run grep -c 'gt 140' "$WF"
  [ "$output" -ge 1 ]
}

@test "registry-controlled prose never reaches GITHUB_OUTPUT as a heredoc" {
  # A deprecation message containing a bare EOF line would escape the block.
  run grep -c 'deprecation_message<<' "$WF"
  [ "$output" -eq 0 ]
}

@test "manifest_path is validated before use" {
  run grep -c '\*\.\.\*' "$WF"
  [ "$output" -ge 1 ]
}

@test "the gate status uses GHA env vars, not template expressions, for the URL" {
  # -F required for the same reason as the add-paths test above: `${...}` braces
  # are regex syntax. Verified 2026-08-07: plain `grep -c` -> 0, `grep -cF` -> 1.
  run grep -cF 'target_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"' "$WF"
  [ "$output" -eq 1 ]
}

@test "the registry endpoint is the full packument, not the abbreviated form" {
  # Anchored on the exact endpoint AND its trailing argument. The unanchored
  # `grep -c 'registry.npmjs.org/pnpm'` with `-ge 1` this test used to run also
  # matches `registry.npmjs.org/pnpm-EVIL`, so it bound nothing it claimed to.
  run grep -cE 'curl .* https://registry\.npmjs\.org/pnpm -o ' "$WF"
  [ "$output" -eq 1 ]
  # No other path under the registry name is fetched anywhere in the file.
  run grep -cE 'https://registry\.npmjs\.org/' "$WF"
  [ "$output" -eq 1 ]
  run grep -c 'vnd.npm.install-v1' "$WF"
  [ "$output" -eq 0 ]
}

@test "the tarball host is constrained before the tarball is fetched" {
  # dist.tarball and dist.integrity come from the same packument, so a hostile
  # one controls both sides and the integrity check proves nothing about origin.
  run grep -cF 'if [ "$TARBALL_HOST" != "registry.npmjs.org" ]; then' "$WF"
  [ "$output" -eq 1 ]
}

@test "an absent dist.integrity is announced as a workflow annotation" {
  # The inline script's plain-stderr warning never reaches the checks UI.
  run grep -cE '::warning::the npm registry published no dist.integrity' "$WF"
  [ "$output" -eq 1 ]
}

@test "manifest_path rejects newlines and carriage returns" {
  # Mirrors pre-commit-autoupdate.yml:129-131. The value flows into the
  # newline-separated `add-paths:`, so a newline widens the path restriction.
  run grep -cF "*\$'\\n'*|*\$'\\r'*)" "$WF"
  [ "$output" -eq 1 ]
}

@test "registry deprecation prose is stripped of HTML before it reaches the body" {
  # Blockquoting stops Markdown but not HTML: `> > <img src=x>` renders and
  # leaks a viewer's IP and User-Agent. Escaping `<` disarms every tag.
  run grep -cF "sed -e 's/</\\&lt;/g' -e 's/^/> > /'" "$WF"
  [ "$output" -eq 1 ]
}

@test "the runner is hardened before any network fetch" {
  # This workflow makes two outbound fetches (packument, tarball); 9 of the
  # repo's 10 workflows harden, and the two that do not are a caller and a
  # workflow with no network I/O.
  run grep -c 'step-security/harden-runner@' "$WF"
  [ "$output" -eq 1 ]
  run grep -c 'egress-policy: audit' "$WF"
  [ "$output" -eq 1 ]
}

@test "every action used is SHA-pinned with a version comment" {
  block=$(cat "$WF")
  for target in \
    actions/checkout \
    actions/create-github-app-token \
    peter-evans/create-pull-request \
    step-security/harden-runner
  do
    grep -q "${target}@" "$WF" || continue
    assert_action_pin "$block" "$target"
  done
}
