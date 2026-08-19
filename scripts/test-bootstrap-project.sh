#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIRECTORY=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BOOTSTRAP_SCRIPT=${SCRIPT_DIRECTORY}/bootstrap-project.sh
TEST_DIRECTORY=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-project-test.XXXXXX")
trap 'rm -rf "$TEST_DIRECTORY"' EXIT

fail() {
  printf 'test failure: %s\n' "$*" >&2
  exit 1
}

assert_file() {
  [[ -f $1 ]] || fail "missing file: $1"
}

assert_contains() {
  grep -Fq "$2" "$1" || fail "$1 does not contain: $2"
}

initialize_repository() {
  local repository_directory=$1
  mkdir -p "$repository_directory"
  git -C "$repository_directory" init -b main >/dev/null
  git -C "$repository_directory" config user.name 'Bootstrap Test'
  git -C "$repository_directory" config user.email 'bootstrap-test@example.invalid'
  printf '# Fixture\n' > "$repository_directory/README.md"
  git -C "$repository_directory" add README.md
  git -C "$repository_directory" commit -m 'Initial commit' >/dev/null
}

bash -n "$BOOTSTRAP_SCRIPT"

SIMPLE_REPOSITORY=${TEST_DIRECTORY}/simple
initialize_repository "$SIMPLE_REPOSITORY"
"$BOOTSTRAP_SCRIPT" --directory "$SIMPLE_REPOSITORY" >/dev/null

assert_file "$SIMPLE_REPOSITORY/.github/workflows/sync-main-to-development-branches.yml"
assert_file "$SIMPLE_REPOSITORY/.github/workflows/release.yml"
assert_file "$SIMPLE_REPOSITORY/release-please-config.json"
assert_file "$SIMPLE_REPOSITORY/.release-please-manifest.json"
assert_file "$SIMPLE_REPOSITORY/VERSION"
assert_contains "$SIMPLE_REPOSITORY/release-please-config.json" '"release-type": "simple"'
assert_contains "$SIMPLE_REPOSITORY/.release-please-manifest.json" '".": "0.1.0"'
assert_contains "$SIMPLE_REPOSITORY/.github/workflows/sync-main-to-development-branches.yml" 'branch_prefixes: agent/,claude/,codex/,dev/,feature/,fix/'

"$BOOTSTRAP_SCRIPT" --directory "$SIMPLE_REPOSITORY" >/dev/null

printf '# locally customized\n' > "$SIMPLE_REPOSITORY/.github/workflows/release.yml"
if "$BOOTSTRAP_SCRIPT" --directory "$SIMPLE_REPOSITORY" >/dev/null 2>&1; then
  fail 'expected a differing scaffold file to require --force'
fi
"$BOOTSTRAP_SCRIPT" --directory "$SIMPLE_REPOSITORY" --force >/dev/null
assert_contains "$SIMPLE_REPOSITORY/.github/workflows/release.yml" 'semver-release.yml@v1'

NODE_REPOSITORY=${TEST_DIRECTORY}/node
initialize_repository "$NODE_REPOSITORY"
printf '{"name":"fixture","version":"2.3.4"}\n' > "$NODE_REPOSITORY/package.json"
git -C "$NODE_REPOSITORY" add package.json
git -C "$NODE_REPOSITORY" commit -m 'Add package' >/dev/null
"$BOOTSTRAP_SCRIPT" --directory "$NODE_REPOSITORY" >/dev/null

assert_contains "$NODE_REPOSITORY/release-please-config.json" '"release-type": "node"'
assert_contains "$NODE_REPOSITORY/.release-please-manifest.json" '".": "2.3.4"'
[[ ! -f $NODE_REPOSITORY/VERSION ]] || fail 'node scaffold should not create VERSION'

FULL_REPOSITORY=${TEST_DIRECTORY}/full
initialize_repository "$FULL_REPOSITORY"
mkdir -p "$FULL_REPOSITORY/scripts"
printf '#!/usr/bin/env bash\nmkdir -p dist\nprintf artifact > dist/release.txt\n' > "$FULL_REPOSITORY/scripts/build-release.sh"
printf '#!/usr/bin/env bash\nprintf deployed\\n\n' > "$FULL_REPOSITORY/scripts/deploy-release.sh"
git -C "$FULL_REPOSITORY" add scripts
git -C "$FULL_REPOSITORY" commit -m 'Add release scripts' >/dev/null
"$BOOTSTRAP_SCRIPT" \
  --directory "$FULL_REPOSITORY" \
  --build-script scripts/build-release.sh \
  --artifact-path 'dist/*' \
  --deploy-script scripts/deploy-release.sh >/dev/null

assert_contains "$FULL_REPOSITORY/.github/workflows/release.yml" 'publish-release-assets.yml@v1'
assert_contains "$FULL_REPOSITORY/.github/workflows/release.yml" 'run: bash scripts/build-release.sh'
assert_contains "$FULL_REPOSITORY/.github/workflows/release.yml" 'environment: production'
assert_contains "$FULL_REPOSITORY/.github/workflows/release.yml" 'run: bash scripts/deploy-release.sh'

DRY_RUN_REPOSITORY=${TEST_DIRECTORY}/dry-run
initialize_repository "$DRY_RUN_REPOSITORY"
"$BOOTSTRAP_SCRIPT" --directory "$DRY_RUN_REPOSITORY" --dry-run >/dev/null
[[ ! -d $DRY_RUN_REPOSITORY/.github ]] || fail 'dry run wrote workflow files'
[[ ! -f $DRY_RUN_REPOSITORY/release-please-config.json ]] || fail 'dry run wrote release config'

printf 'bootstrap tests passed\n'
