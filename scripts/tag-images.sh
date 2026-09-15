#!/usr/bin/env bash
#
# tag-images.sh
#
# For every container image in this repo (any directory containing a
# Containerfile), work out whether it has changed since its last release,
# compute the next semantic version from the conventional commits that
# touched it, and tag the current commit as "<image-name>/v<version>".
#
# Image name          = directory path of the Containerfile, relative to the
#                       repo root (e.g. "devspaces/base").
# Version tag format  = "<image-name>/v<major>.<minor>.<patch>"
#                       (e.g. "devspaces/base/v1.4.2").
#
# Version bump rules (highest matching wins, over all commits in range):
#   major  -> a commit with "!" after type/scope, or a "BREAKING CHANGE"/
#             "BREAKING-CHANGE" footer.
#   minor  -> a "feat" commit.
#   patch  -> a "fix"/"perf"/"refactor"/"revert"/"build" commit, or any
#             other change when nothing higher matched (an image that
#             changed always gets at least a patch bump).
#
# Usage:
#   scripts/tag-images.sh [options]
#
# Options:
#   -n, --dry-run   Show what would be tagged without creating any tags.
#   -p, --push      Push the created tags to the remote after tagging.
#   -r, --remote R  Remote to push to (default: origin). Implies --push.
#   -h, --help      Show this help and exit.
#
set -euo pipefail

# --------------------------------------------------------------------------
# Options
# --------------------------------------------------------------------------
DRY_RUN=0
PUSH=0
REMOTE="origin"

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//' | sed '$d'
}

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
# Helpers
# --------------------------------------------------------------------------
log()  { printf '%s\n' "$*" >&2; }
info() { printf '\033[36m%s\033[0m\n' "$*" >&2; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }

# Move to the repo root so all paths are relative to it.
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# The commit we will attach tags to.
HEAD_SHA="$(git rev-parse HEAD)"

# Return the latest "<image>/vX.Y.Z" tag for an image, or empty if none.
latest_tag_for() {
  local image="$1"
  { git tag --list "${image}/v*" \
    | sed -n "s#^${image}/v##p" \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -V \
    | tail -n1 ; } || true
}

# Decide the bump level ("major"/"minor"/"patch"/"none") for a commit range
# affecting a specific path. Prints one of those words.
bump_for_range() {
  local range="$1" path="$2"
  local level="none"

  # Iterate over each commit that touched this path, newest first.
  local sha
  while IFS= read -r sha; do
    [[ -z "$sha" ]] && continue

    local body header
    body="$(git show -s --format=%B "$sha")"
    header="$(printf '%s\n' "$body" | head -n1)"

    # Breaking change: "type!:" / "type(scope)!:" header, or a footer.
    if [[ "$header" =~ ^[a-zA-Z]+(\([^\)]*\))?!: ]] \
       || printf '%s\n' "$body" | grep -Eq '^BREAKING[ -]CHANGE:'; then
      echo "major"
      return 0   # major is the ceiling; stop early.
    fi

    # Conventional-commit type from the header.
    local type=""
    if [[ "$header" =~ ^([a-zA-Z]+)(\([^\)]*\))?!?: ]]; then
      type="${BASH_REMATCH[1],,}"
    fi

    case "$type" in
      feat)
        [[ "$level" != "minor" ]] && level="minor"
        ;;
      fix|perf|refactor|revert|build)
        [[ "$level" == "none" ]] && level="patch"
        ;;
      *)
        # Any other change still counts as a patch-worthy change.
        [[ "$level" == "none" ]] && level="patch"
        ;;
    esac
  done < <(git log --format=%H "$range" -- "$path")

  echo "$level"
}

# Apply a bump level to a semver string, print the new version.
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
info "Repo:  $REPO_ROOT"
info "HEAD:  $HEAD_SHA"
[[ "$DRY_RUN" == 1 ]] && warn "Running in dry-run mode; no tags will be created."

# Discover all images: every directory containing a Containerfile.
mapfile -t IMAGES < <(
  git ls-files '**/Containerfile' 'Containerfile' \
    | xargs -r -n1 dirname \
    | sed 's#^\./##' \
    | sort -u
)

if [[ ${#IMAGES[@]} -eq 0 ]]; then
  warn "No Containerfiles found; nothing to do."
  exit 0
fi

CREATED_TAGS=()

for image in "${IMAGES[@]}"; do
  last_ver="$(latest_tag_for "$image")"

  first_release=0
  if [[ -n "$last_ver" ]]; then
    last_tag="${image}/v${last_ver}"
    range="${last_tag}..HEAD"
    base_ver="$last_ver"
  else
    # No tag exists (or none with a valid version): fall back to 0.0.0 and
    # patch-bump, so the first tag for an image is v0.0.1.
    first_release=1
    last_tag=""
    range="HEAD"
    base_ver="0.0.0"
  fi

  # Has anything under this image's directory changed in the range?
  if [[ -z "$(git log --format=%H "$range" -- "$image")" ]]; then
    log "· ${image}: no changes since ${last_tag:-repo start} (currently v${last_ver:-0.0.0})"
    continue
  fi

  if [[ "$first_release" == 1 ]]; then
    level="patch"
  else
    level="$(bump_for_range "$range" "$image")"
    [[ "$level" == "none" ]] && level="patch"
  fi

  new_ver="$(apply_bump "$base_ver" "$level")"
  new_tag="${image}/v${new_ver}"

  # Guard against tagging the same commit twice with the same version.
  if git rev-parse -q --verify "refs/tags/${new_tag}" >/dev/null; then
    warn "✗ ${image}: tag ${new_tag} already exists; skipping"
    continue
  fi

  info "✓ ${image}: v${last_ver:-0.0.0} -> v${new_ver} (${level} bump) -> ${new_tag}"

  if [[ "$DRY_RUN" == 0 ]]; then
    git tag -a "$new_tag" -m "${image} v${new_ver}" "$HEAD_SHA"
    CREATED_TAGS+=("$new_tag")
  fi
done

if [[ "$DRY_RUN" == 0 && "$PUSH" == 1 && ${#CREATED_TAGS[@]} -gt 0 ]]; then
  info "Pushing ${#CREATED_TAGS[@]} tag(s) to ${REMOTE}..."
  git push "$REMOTE" "${CREATED_TAGS[@]}"
fi

if [[ ${#CREATED_TAGS[@]} -eq 0 && "$DRY_RUN" == 0 ]]; then
  log "No new tags created."
fi
