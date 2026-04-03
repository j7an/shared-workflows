# shared-workflows

Reusable GitHub Actions workflows for dependency management and security scanning.

## Available Workflows

### Dependency Cool-Down Gate

Enforces a cooling period on bot dependency PRs before they can be merged.

```yaml
jobs:
  gate:
    uses: j7an/shared-workflows/.github/workflows/dependency-cooldown-gate.yml@v1
    secrets: inherit
    with:
      cooling_business_days: 5
```

**Inputs:**

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `cooling_business_days` | number | `5` | Business days before a bot PR passes the gate |
| `bypass_label` | string | `security-bypass-cooling` | Label that skips the cooling period |
| `create_tracking_issue` | boolean | `true` | Auto-create tracking issues for bot PRs |
| `default_assignee` | string | `""` | Issue assignee (empty = repo owner) |

### Dependency Cool-Down Scan

Scheduled scanner that checks mature bot PRs for known advisories.

```yaml
jobs:
  scan:
    uses: j7an/shared-workflows/.github/workflows/dependency-cooldown-scan.yml@v1
    secrets: inherit
    with:
      cooling_business_days: 5
```

**Inputs:**

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `cooling_business_days` | number | `5` | Business days before a bot PR is eligible |
| `bypass_label` | string | `security-bypass-cooling` | Label that skips the cooling period |
| `enable_scorecard` | boolean | `true` | Include OpenSSF Scorecard in results |

## Versioning

Pin to major tag (`@v1`) for auto-updates or exact tag (`@v1.0.0`) for stability.
