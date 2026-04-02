# ADR-2: Auto-merge MRs on Pipeline Success

- **Status**: Accepted
- **Date**: 2026-04-02

## Decision

Enable auto-merge with zero required approvals for the `harvester-golden-images`
GitLab project. MRs merge automatically when the pipeline passes.

## Context

This is an infrastructure/image-build repo with a single primary contributor.
The MR pipeline now validates the full build chain:

1. **validate** — `terraform init`, `validate`, `fmt -check` for cis/ and rke2/
2. **dev-build** — builds a real golden image with `dev-` prefix naming
3. **cleanup** — deletes dev images from Harvester (runs regardless of outcome)

The dev pipeline provides sufficient automated validation to replace manual
approval for this project. The cleanup stage ensures no orphaned resources.

## GitLab Settings Applied

| Setting | Value | Previous |
|---------|-------|----------|
| `only_allow_merge_if_pipeline_succeeds` | `true` | `false` |
| `approvals_before_merge` | `0` | `0` |
| `merge_method` | `merge` | `merge` |

These settings are **project-scoped** — they do not affect any other project
in the `infra_and_platform_services` group.

## Flow

```
MR created
  -> MR pipeline: validate -> dev-build -> cleanup
    -> Pipeline passes -> auto-merge to main
      -> Main pipeline: detect -> build (production) -> tag -> sync-to-github
```

## Consequences

- Faster feedback loop: push branch, create MR, pipeline validates, auto-merges
- No manual approval gate — acceptable for infra repo with automated validation
- If the dev build fails, the MR blocks and requires investigation
- Dev images are always cleaned up, preventing Harvester resource leaks
- This pattern should NOT be applied to application repos (forge, identity-webui)
  where peer review of business logic is expected

## Alternatives Considered

- **Require 1 approval**: Adds friction for a single-contributor infra repo
  with comprehensive automated validation. Rejected.
- **Auto-merge only on main push (no MR)**: Loses the dev-build validation
  stage. Rejected — the whole point is to test before promoting.
