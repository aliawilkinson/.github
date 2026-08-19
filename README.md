# Shared GitHub workflows

This repository contains reusable GitHub Actions workflows and repository defaults for `aliawilkinson` projects.

## Operating model

- `main` is the trunk and remains deployable.
- Development work uses short-lived branches and draft pull requests into `main`.
- When `main` moves, the branch-sync workflow proposes those changes to every active development branch through a pull request. It never writes directly to a development branch.
- Release Please maintains a reviewable SemVer release pull request from Conventional Commits.
- Merging a release pull request creates an immutable `vX.Y.Z` tag and GitHub Release.
- Artifact jobs build from the tagged commit, add SHA-256 checksums and provenance, and attach the exact outputs to the GitHub Release.
- Deployment stays project-specific and consumes the release job's immutable tag or SHA.

## Reusable workflows

### `sync-development-branches.yml`

Call this workflow after pushes to `main`. It considers a branch active when it is in the same repository, matches a configured prefix, and has an open pull request into `main`.

```yaml
name: Propose main updates to development branches

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: write
  pull-requests: write

jobs:
  sync:
    uses: aliawilkinson/.github/.github/workflows/sync-development-branches.yml@v1
    with:
      base_branch: main
      branch_prefixes: agent/,claude/,codex/,dev/,feature/,fix/
    secrets: inherit
```

### `semver-release.yml`

Call this workflow after pushes to `main`. Each caller keeps its own `release-please-config.json` and `.release-please-manifest.json` because language-specific version files belong to the project.

```yaml
permissions:
  contents: write
  issues: write
  pull-requests: write

jobs:
  release:
    uses: aliawilkinson/.github/.github/workflows/semver-release.yml@v1
    with:
      target_branch: main
    secrets: inherit
```

The workflow exposes `release_created`, `tag_name`, `version`, `major`, `sha`, and `release_url`. A caller can build and deploy only when `release_created == 'true'`.

### `publish-release-assets.yml`

Build jobs upload their outputs as an Actions artifact. This workflow downloads that artifact, generates `SHA256SUMS`, optionally creates GitHub artifact attestations, and uploads the files to an existing GitHub Release.

The caller must grant `contents: write`, `id-token: write`, and `attestations: write` when provenance is enabled.

## Versioning contract

Use Conventional Commit prefixes in commits or squash-merge PR titles:

- `fix:` creates a patch candidate.
- `feat:` creates a minor candidate.
- `feat!:` or a `BREAKING CHANGE:` footer creates a major candidate.
- `chore:`, `docs:`, and similar maintenance types do not create a release by themselves.

Projects reference the stable major tag (`@v1`). Changes to reusable workflows are reviewed through pull requests. Compatible releases automatically advance the `v1` tag to the newly reviewed release commit; breaking workflow interfaces receive a new major tag.

## Token behavior

The workflows use the caller repository's `GITHUB_TOKEN` by default. Each caller must enable **Allow GitHub Actions to create and approve pull requests**. An optional `RELEASE_PLEASE_TOKEN` or `SYNC_BRANCH_TOKEN` repository secret may hold a fine-grained personal access token when PRs and tags created by automation must trigger additional workflows.
