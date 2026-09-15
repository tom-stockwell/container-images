#!/usr/bin/env bash
#
# tag-images.sh
#
# For every container image in this repo (any directory containing a
# Containerfile), work out whether it has changed since its last release,
# compute the next semantic version from the conventional commits that
# touched it, and tag the current commit as "<image-name>/v<version>".
#
#   Image name         directory of the Containerfile, relative to the repo
#                      root (e.g. "devspaces/base").
#   Version tag        "<image-name>/v<major>.<minor>.<patch>"
#                      (e.g. "devspaces/base/v1.4.2").
#
# Version bump rules (highest matching level wins, over all commits in range):
#   major   a commit with "!" after the type/scope, or a "BREAKING CHANGE"/
#           "BREAKING-CHANGE" footer.
#   minor   a "feat" commit.
#   patch   any other change (an image that changed always gets at least a
#           patch bump). The first tag for an image is always v0.0.1.
#
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/tag-images.sh [options]

Tag the current commit with the next semantic version for every container
image (directory containing a Containerfile) that has changed since its last
release tag.

Options:
  -n, --dry-run     Show what would be tagged without creating any tags.
  -p, --push        Push the created tags to the remote after tagging.
  -r, --remote R    Remote to push to (default: origin). Implies --push.
  -h, --help        Show this help and exit.
EOF
}

# --------------------------------------------------------------------------
# Options
# --------------------------------------------------------------------------
DRY_RUN=0
PUSH=0
REMOTE="origin"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=1 ;;
    -p|--push)    PUSH=1 ;;
    -r|--remote)  REMOTE="${2:?--remote needs an argument}"; PUSH=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# --------------------------------------------------------------------------
# Output helpers (colour only when stderr is a terminal)
# --------------------------------------------------------------------------
if [[ -t 2 ]]; then
  CYAN=$'\033[36m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
else
  CYAN=''; YELLOW=''; RESET=''
fi

log()  { printf '%s\n' "$*" >&2; }
info() { printf '%s%s%s\n' "$CYAN" "$*" "$RESET" >&2; }
warn() { printf '%s%s%s\n' "$YELLOW" "$*" "$RESET" >&2; }

# --------------------------------------------------------------------------
# Git helpers
# --------------------------------------------------------------------------
# Latest "<image>/vX.Y.Z" version for an image (bare "X.Y.Z"), or empty if none.
latest_version_for() {
  local image="$1"
  { git tag --list "${image}/v*" \
      | sed -n "s#^${image}/v##p" \
      | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
      | sort -V \
      | tail -n1 ; } || true
}

# Highest bump level ("major"/"minor"/"patch"/"none") implied by the commits in
# <range> that touched <path>.
bump_for_range() {
  local range="$1" path="$2"
  local level="none" sha body header

  while IFS= read -r sha; do
    body="$(git show -s --format=%B "$sha")"
    header="${body%%$'\n'*}"

    # Breaking change is the ceiling, so we can stop as soon as we see one.
    if [[ "$header" =~ ^[a-zA-Z]+(\([^\)]*\))?!: ]] \
       || printf '%s\n' "$body" | grep -Eq '^BREAKING[ -]CHANGE:'; then
      echo "major"
      return 0
    fi

    if [[ "$header" =~ ^feat(\([^\)]*\))?: ]]; then
      level="minor"
    elif [[ "$level" == "none" ]]; then
      level="patch"
    fi
  done < <(git log --format=%H "$range" -- "$path")

  echo "$level"
}

# Print <version> with <level> (major/minor/patch) applied.
apply_bump() {
  local version="$1" level="$2"
  local major minor patch
  IFS='.' read -r major minor patch <<<"$version"
  case "$level" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
  esac
  echo "${major}.${minor}.${patch}"
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"
HEAD_SHA="$(git rev-parse HEAD)"

info "Repo:  $REPO_ROOT"
info "HEAD:  $HEAD_SHA"
[[ "$DRY_RUN" == 1 ]] && warn "Running in dry-run mode; no tags will be created."

# Discover images: every directory containing a Containerfile.
mapfile -t IMAGES < <(
  git ls-files '**/Containerfile' 'Containerfile' \
    | xargs -r -n1 dirname \
    | sort -u
)

if [[ ${#IMAGES[@]} -eq 0 ]]; then
  warn "No Containerfiles found; nothing to do."
  exit 0
fi

CREATED_TAGS=()

for image in "${IMAGES[@]}"; do
  last_ver="$(latest_version_for "$image")"

  if [[ -n "$last_ver" ]]; then
    # Compare against everything since the last release tag.
    range="${image}/v${last_ver}..HEAD"
    since="${image}/v${last_ver}"
    level="$(bump_for_range "$range" "$image")"
    [[ "$level" == "none" ]] && level="patch"
  else
    # No release yet: start at 0.0.0 and patch-bump to v0.0.1.
    last_ver="0.0.0"
    range="HEAD"
    since="repo start"
    level="patch"
  fi

  # Skip images with no commits touching them in the range.
  if [[ -z "$(git log --format=%H "$range" -- "$image")" ]]; then
    log "· ${image}: no changes since ${since} (currently v${last_ver})"
    continue
  fi

  new_ver="$(apply_bump "$last_ver" "$level")"
  new_tag="${image}/v${new_ver}"

  # Guard against tagging the same version twice.
  if git rev-parse -q --verify "refs/tags/${new_tag}" >/dev/null; then
    warn "✗ ${image}: tag ${new_tag} already exists; skipping"
    continue
  fi

  info "✓ ${image}: v${last_ver} -> v${new_ver} (${level} bump) -> ${new_tag}"

  if [[ "$DRY_RUN" == 0 ]]; then
    git tag -a "$new_tag" -m "${image} v${new_ver}" "$HEAD_SHA"
    CREATED_TAGS+=("$new_tag")
  fi
done

if [[ "$DRY_RUN" == 1 ]]; then
  exit 0
fi

if [[ ${#CREATED_TAGS[@]} -eq 0 ]]; then
  log "No new tags created."
  exit 0
fi

if [[ "$PUSH" == 1 ]]; then
  info "Pushing ${#CREATED_TAGS[@]} tag(s) to ${REMOTE}..."
  git push "$REMOTE" "${CREATED_TAGS[@]}"
fi
