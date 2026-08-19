#!/usr/bin/env bash

set -euo pipefail

TARGET_DIRECTORY=.
BASE_BRANCH=main
BRANCH_PREFIXES=agent/,claude/,codex/,dev/,feature/,fix/
SHARED_REPOSITORY=aliawilkinson/.github
SHARED_REF=v1
RELEASE_TYPE=auto
INITIAL_VERSION=
VERSION_FILE=
CONFIGURE_GITHUB=false
DRY_RUN=false
FORCE=false
BUILD_SCRIPT=
ARTIFACT_PATH=
DEPLOY_SCRIPT=
DEPLOY_ENVIRONMENT=production

usage() {
  cat <<'EOF'
Scaffold trunk, branch-sync, and SemVer release automation in a Git repository.

Usage:
  bootstrap-project.sh [options]

Options:
  --directory DIR            Repository directory (default: current directory)
  --base-branch BRANCH       Trunk branch (default: main)
  --branch-prefixes LIST     Comma-separated active development prefixes
  --release-type TYPE        Release Please type, or auto (default: auto)
  --version VERSION          Existing SemVer version (default: inferred or 0.1.0)
  --version-file FILE        Version file for the simple release type
  --shared-repository REPO   Shared workflow repository (default: aliawilkinson/.github)
  --shared-ref REF           Shared workflow ref (default: v1)
  --build-script FILE        Repository script that builds release assets
  --artifact-path GLOB       Assets produced by --build-script, such as dist/*
  --deploy-script FILE       Repository script that deploys the tagged release
  --environment NAME         GitHub deployment environment (default: production)
  --configure-github         Permit Actions to create PRs in the GitHub repository
  --dry-run                  Report planned writes without changing files or settings
  --force                    Replace scaffold-owned files that differ
  -h, --help                 Show this help

The script writes:
  .github/workflows/sync-main-to-development-branches.yml
  .github/workflows/release.yml
  release-please-config.json
  .release-please-manifest.json
  VERSION (simple projects only, unless another version file is selected)

It does not commit, push, or merge. Build and deployment jobs are generated only
when repository-owned scripts are supplied explicitly.
EOF
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_value() {
  if [[ $# -lt 2 || -z ${2:-} || ${2:-} == --* ]]; then
    fail "$1 requires a value"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --directory)
      require_value "$@"
      TARGET_DIRECTORY=$2
      shift 2
      ;;
    --base-branch)
      require_value "$@"
      BASE_BRANCH=$2
      shift 2
      ;;
    --branch-prefixes)
      require_value "$@"
      BRANCH_PREFIXES=$2
      shift 2
      ;;
    --release-type)
      require_value "$@"
      RELEASE_TYPE=$2
      shift 2
      ;;
    --version)
      require_value "$@"
      INITIAL_VERSION=$2
      shift 2
      ;;
    --version-file)
      require_value "$@"
      VERSION_FILE=$2
      shift 2
      ;;
    --shared-repository)
      require_value "$@"
      SHARED_REPOSITORY=$2
      shift 2
      ;;
    --shared-ref)
      require_value "$@"
      SHARED_REF=$2
      shift 2
      ;;
    --build-script)
      require_value "$@"
      BUILD_SCRIPT=$2
      shift 2
      ;;
    --artifact-path)
      require_value "$@"
      ARTIFACT_PATH=$2
      shift 2
      ;;
    --deploy-script)
      require_value "$@"
      DEPLOY_SCRIPT=$2
      shift 2
      ;;
    --environment)
      require_value "$@"
      DEPLOY_ENVIRONMENT=$2
      shift 2
      ;;
    --configure-github)
      CONFIGURE_GITHUB=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --force)
      FORCE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

[[ $BASE_BRANCH =~ ^[A-Za-z0-9._/-]+$ ]] || fail "invalid base branch: $BASE_BRANCH"
[[ $BRANCH_PREFIXES =~ ^[A-Za-z0-9._/,-]+$ ]] || fail "invalid branch prefix list"
[[ $SHARED_REPOSITORY =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "shared repository must be owner/name"
[[ $SHARED_REF =~ ^[A-Za-z0-9._/-]+$ ]] || fail "invalid shared workflow ref"
[[ $RELEASE_TYPE =~ ^[A-Za-z0-9-]+$ ]] || fail "invalid release type"
[[ $DEPLOY_ENVIRONMENT =~ ^[A-Za-z0-9._-]+$ ]] || fail "invalid deployment environment"

if [[ -n $BUILD_SCRIPT || -n $ARTIFACT_PATH ]]; then
  [[ -n $BUILD_SCRIPT && -n $ARTIFACT_PATH ]] || fail "--build-script and --artifact-path must be supplied together"
fi

for repository_script in "$BUILD_SCRIPT" "$DEPLOY_SCRIPT"; do
  if [[ -n $repository_script ]]; then
    [[ $repository_script =~ ^[A-Za-z0-9._/-]+$ ]] || fail "invalid repository script: $repository_script"
    [[ $repository_script != /* && $repository_script != *'..'* ]] || fail "repository scripts must stay inside the repository"
  fi
done

if [[ -n $ARTIFACT_PATH ]]; then
  [[ $ARTIFACT_PATH =~ ^[A-Za-z0-9._/*-]+$ ]] || fail "artifact path supports only letters, numbers, dots, slashes, hyphens, and *"
  [[ $ARTIFACT_PATH != /* && $ARTIFACT_PATH != *'..'* ]] || fail "artifact path must stay inside the repository"
fi

cd "$TARGET_DIRECTORY"
REPOSITORY_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || fail "not inside a Git repository"
cd "$REPOSITORY_ROOT"
BOOTSTRAP_SHA=$(git rev-parse HEAD 2>/dev/null) || fail "the repository needs an initial commit"

if [[ -n $BUILD_SCRIPT && ! -f $BUILD_SCRIPT ]]; then
  fail "build script does not exist: $BUILD_SCRIPT"
fi
if [[ -n $DEPLOY_SCRIPT && ! -f $DEPLOY_SCRIPT ]]; then
  fail "deploy script does not exist: $DEPLOY_SCRIPT"
fi

infer_release_type() {
  if [[ -f package.json ]]; then
    printf 'node\n'
  elif [[ -f pyproject.toml || -f setup.py || -f setup.cfg ]]; then
    printf 'python\n'
  elif [[ -f Cargo.toml ]]; then
    printf 'rust\n'
  elif [[ -f go.mod ]]; then
    printf 'go\n'
  elif [[ -f pubspec.yaml ]]; then
    printf 'dart\n'
  elif [[ -f mix.exs ]]; then
    printf 'elixir\n'
  elif [[ -f composer.json ]]; then
    printf 'php\n'
  elif [[ -f Gemfile ]] || compgen -G '*.gemspec' >/dev/null; then
    printf 'ruby\n'
  else
    printf 'simple\n'
  fi
}

if [[ $RELEASE_TYPE == auto ]]; then
  RELEASE_TYPE=$(infer_release_type)
fi

infer_version() {
  local candidate=
  local version_source=

  for version_source in VERSION version.txt; do
    if [[ -f $version_source ]]; then
      candidate=$(tr -d '[:space:]' < "$version_source")
      if [[ $candidate =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]; then
        printf '%s\n' "$candidate"
        return
      fi
    fi
  done

  if [[ -f package.json ]]; then
    if command -v jq >/dev/null 2>&1; then
      candidate=$(jq -r '.version // empty' package.json)
    elif command -v node >/dev/null 2>&1; then
      candidate=$(node -p 'require("./package.json").version || ""')
    fi
    if [[ $candidate =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  fi

  candidate=$(git tag --list 'v[0-9]*' --sort=-version:refname | sed -n '1p')
  candidate=${candidate#v}
  if [[ $candidate =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]; then
    printf '%s\n' "$candidate"
    return
  fi

  printf '0.1.0\n'
}

if [[ -z $INITIAL_VERSION ]]; then
  INITIAL_VERSION=$(infer_version)
fi
[[ $INITIAL_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] || fail "version must be SemVer without a v prefix"

if [[ $RELEASE_TYPE == simple ]]; then
  if [[ -z $VERSION_FILE ]]; then
    if [[ -f VERSION ]]; then
      VERSION_FILE=VERSION
    elif [[ -f version.txt ]]; then
      VERSION_FILE=version.txt
    else
      VERSION_FILE=VERSION
    fi
  fi
  [[ $VERSION_FILE =~ ^[A-Za-z0-9._/-]+$ ]] || fail "invalid version file"
  [[ $VERSION_FILE != /* && $VERSION_FILE != *'..'* ]] || fail "version file must stay inside the repository"
elif [[ -n $VERSION_FILE ]]; then
  fail "--version-file is supported only with --release-type simple"
fi

write_generated_file() {
  local destination=$1
  local temporary_file
  temporary_file=$(mktemp "${TMPDIR:-/tmp}/bootstrap-project.XXXXXX")
  cat > "$temporary_file"

  if [[ -f $destination ]] && cmp -s "$temporary_file" "$destination"; then
    rm -f "$temporary_file"
    printf 'unchanged  %s\n' "$destination"
    return
  fi

  if [[ -e $destination && $FORCE != true ]]; then
    rm -f "$temporary_file"
    fail "$destination already exists and differs; inspect it or rerun with --force"
  fi

  if [[ $DRY_RUN == true ]]; then
    rm -f "$temporary_file"
    printf 'would write %s\n' "$destination"
    return
  fi

  mkdir -p "$(dirname "$destination")"
  mv "$temporary_file" "$destination"
  printf 'wrote      %s\n' "$destination"
}

write_generated_file .github/workflows/sync-main-to-development-branches.yml <<EOF
name: Propose ${BASE_BRANCH} updates to development branches

on:
  push:
    branches:
      - ${BASE_BRANCH}
  workflow_dispatch:

permissions:
  contents: write
  pull-requests: write

jobs:
  sync:
    uses: ${SHARED_REPOSITORY}/.github/workflows/sync-development-branches.yml@${SHARED_REF}
    with:
      base_branch: ${BASE_BRANCH}
      branch_prefixes: ${BRANCH_PREFIXES}
    secrets: inherit
EOF

generate_release_workflow() {
  cat <<EOF
name: Release

on:
  push:
    branches:
      - ${BASE_BRANCH}
  workflow_dispatch:

permissions:
  contents: write
  issues: write
  pull-requests: write
EOF

  if [[ -n $BUILD_SCRIPT ]]; then
    cat <<'EOF'
  id-token: write
  attestations: write
EOF
  fi

  cat <<EOF

jobs:
  release:
    uses: ${SHARED_REPOSITORY}/.github/workflows/semver-release.yml@${SHARED_REF}
    with:
      target_branch: ${BASE_BRANCH}
    secrets: inherit
EOF

  if [[ -n $BUILD_SCRIPT ]]; then
    cat <<EOF

  package:
    if: needs.release.outputs.release_created == 'true'
    needs: release
    runs-on: ubuntu-latest
    steps:
      - name: Check out the tagged source
        uses: actions/checkout@v7
        with:
          ref: \${{ needs.release.outputs.sha }}

      - name: Build release assets
        env:
          RELEASE_TAG: \${{ needs.release.outputs.tag_name }}
          RELEASE_VERSION: \${{ needs.release.outputs.version }}
          RELEASE_SHA: \${{ needs.release.outputs.sha }}
        run: bash ${BUILD_SCRIPT}

      - name: Upload release assets
        uses: actions/upload-artifact@v7
        with:
          name: release-assets-\${{ needs.release.outputs.version }}
          path: ${ARTIFACT_PATH}
          if-no-files-found: error
          retention-days: 14

  publish:
    if: needs.release.outputs.release_created == 'true'
    needs:
      - release
      - package
    uses: ${SHARED_REPOSITORY}/.github/workflows/publish-release-assets.yml@${SHARED_REF}
    with:
      artifact_name: release-assets-\${{ needs.release.outputs.version }}
      tag_name: \${{ needs.release.outputs.tag_name }}
      attest: true
    secrets: inherit
EOF
  fi

  if [[ -n $DEPLOY_SCRIPT ]]; then
    cat <<EOF

  deploy:
    if: needs.release.outputs.release_created == 'true'
    needs:
      - release
EOF
    if [[ -n $BUILD_SCRIPT ]]; then
      cat <<'EOF'
      - publish
EOF
    fi
    cat <<EOF
    runs-on: ubuntu-latest
    environment: ${DEPLOY_ENVIRONMENT}
    steps:
      - name: Check out the tagged source
        uses: actions/checkout@v7
        with:
          ref: \${{ needs.release.outputs.sha }}

      - name: Deploy tagged release
        env:
          RELEASE_TAG: \${{ needs.release.outputs.tag_name }}
          RELEASE_VERSION: \${{ needs.release.outputs.version }}
          RELEASE_SHA: \${{ needs.release.outputs.sha }}
        run: bash ${DEPLOY_SCRIPT}
EOF
  fi
}

generate_release_workflow | write_generated_file .github/workflows/release.yml

if [[ $RELEASE_TYPE == simple ]]; then
  PACKAGE_CONFIGURATION=$(printf '{\n      "version-file": "%s"\n    }' "$VERSION_FILE")
else
  PACKAGE_CONFIGURATION='{}'
fi

write_generated_file release-please-config.json <<EOF
{
  "\$schema": "https://raw.githubusercontent.com/googleapis/release-please/main/schemas/config.json",
  "bootstrap-sha": "${BOOTSTRAP_SHA}",
  "release-type": "${RELEASE_TYPE}",
  "include-component-in-tag": false,
  "include-v-in-tag": true,
  "packages": {
    ".": ${PACKAGE_CONFIGURATION}
  }
}
EOF

write_generated_file .release-please-manifest.json <<EOF
{
  ".": "${INITIAL_VERSION}"
}
EOF

if [[ $RELEASE_TYPE == simple ]]; then
  write_generated_file "$VERSION_FILE" <<EOF
${INITIAL_VERSION}
EOF
fi

if [[ $CONFIGURE_GITHUB == true ]]; then
  command -v gh >/dev/null 2>&1 || fail "gh is required by --configure-github"
  REPOSITORY_NAME=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || fail "could not resolve the GitHub repository"

  if [[ $DRY_RUN == true ]]; then
    printf 'would configure GitHub Actions PR permission for %s\n' "$REPOSITORY_NAME"
  else
    gh api --method PUT "repos/${REPOSITORY_NAME}/actions/permissions/workflow" \
      -f default_workflow_permissions=read \
      -F can_approve_pull_request_reviews=true >/dev/null
    printf 'configured GitHub Actions PR permission for %s\n' "$REPOSITORY_NAME"
  fi
fi

printf '\nScaffold complete\n'
printf '  repository:   %s\n' "$REPOSITORY_ROOT"
printf '  trunk:        %s\n' "$BASE_BRANCH"
printf '  release type: %s\n' "$RELEASE_TYPE"
printf '  version:      %s\n' "$INITIAL_VERSION"
printf '  shared ref:   %s@%s\n' "$SHARED_REPOSITORY" "$SHARED_REF"
if [[ -n $BUILD_SCRIPT ]]; then
  printf '  artifacts:    %s via %s\n' "$ARTIFACT_PATH" "$BUILD_SCRIPT"
fi
if [[ -n $DEPLOY_SCRIPT ]]; then
  printf '  deployment:   %s via %s\n' "$DEPLOY_ENVIRONMENT" "$DEPLOY_SCRIPT"
fi
printf '\nNext: inspect the files and commit them on a branch.\n'
