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
  run grep -c 'id: update' "$WF"
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
  # `grep -c 'add-paths: ${{ inputs.manifest_path }}'` -> 0, `grep -cF` -> 1.
  run grep -cF 'add-paths: ${{ inputs.manifest_path }}' "$WF"
  [ "$output" -eq 1 ]
}

@test "the create-pull-request step carries the id the status step reads" {
  run grep -c 'id: cpr' "$WF"
  [ "$output" -eq 1 ]
  run grep -c 'steps.cpr.outputs.pull-request-head-sha' "$WF"
  [ "$output" -ge 1 ]
}

@test "the evidence status uses its own context, not the shared gate" {
  run grep -c 'pnpm-packageManager / evidence' "$WF"
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
  run grep -c 'registry.npmjs.org/pnpm' "$WF"
  [ "$output" -ge 1 ]
  run grep -c 'vnd.npm.install-v1' "$WF"
  [ "$output" -eq 0 ]
}

@test "every action used is SHA-pinned with a version comment" {
  block=$(cat "$WF")
  for target in \
    actions/checkout \
    actions/create-github-app-token \
    peter-evans/create-pull-request
  do
    grep -q "${target}@" "$WF" || continue
    assert_action_pin "$block" "$target"
  done
}
