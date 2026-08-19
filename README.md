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

## Bootstrap a project

From the root of a Git repository with an initial commit:

```bash
curl -fsSL https://raw.githubusercontent.com/aliawilkinson/.github/v1/scripts/bootstrap-project.sh \
  | bash -s -- --configure-github
```

For a local checkout of this repository:

```bash
./scripts/bootstrap-project.sh --directory /path/to/project --configure-github
```

The script infers common Release Please project types, detects the current version where possible, writes the two thin workflow callers and Release Please configuration, and optionally enables the GitHub repository permission required for Actions-created PRs. It refuses to replace differing files unless `--force` is supplied and supports `--dry-run`.

Run `bootstrap-project.sh --help` for overrides such as `--release-type`, `--version`, `--base-branch`, and `--shared-ref`. The script deliberately does not commit, push, or merge. It generates build and deployment jobs only when you explicitly provide repository-owned scripts.

To scaffold artifact publication and deployment too, first add repository-owned scripts and pass their paths explicitly:

```bash
./scripts/bootstrap-project.sh \
  --build-script scripts/build-release.sh \
  --artifact-path 'dist/*' \
  --deploy-script scripts/deploy-release.sh \
  --configure-github
```

The generated jobs receive `RELEASE_TAG`, `RELEASE_VERSION`, and `RELEASE_SHA`. Artifact publication adds checksums and provenance. Deployment uses the protected `production` GitHub environment by default; change it with `--environment`.

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
