#!/usr/bin/env bash
#
# tag-images.sh
#
# For every container image in this repo (any directory containing a
# Containerfile), work out whether it has changed since its last release and,
# if so, tag the current commit with the next semantic version as
# "<image-name>/v<version>".
#
# Conventional-commit parsing and semver math are delegated to `svu`
# (https://github.com/caarlos0/svu). svu is run once per image, scoped to that
# image's directory and its own "<image-name>/v" tag prefix, so each image is
# versioned independently:
#
#   svu next --always \
#     --tag.prefix "devspaces/base/v" \
#     --tag.pattern "devspaces/base/v[0-9]*" \
#     --log.directory "devspaces/base"
#
# This script only decides *whether* an image changed (via git) and leaves the
# version number itself to svu. --always guarantees at least a patch bump for a
# changed image even when its commits aren't conventional, and yields v0.0.1 as
# the first tag for a brand-new image.
#
set -euo pipefail

SVU_URL="https://github.com/caarlos0/svu"

usage() {
  cat <<'EOF'
Usage: scripts/tag-images.sh [options]

Tag the current commit with the next semantic version (computed by svu) for
every container image (directory containing a Containerfile) that has changed
since its last release tag.

Options:
  -n, --dry-run     Show what would be tagged without creating any tags.
  -p, --push        Push the created tags to the remote after tagging.
  -r, --remote R    Remote to push to (default: origin). Implies --push.
  -h, --help        Show this help and exit.

Requires svu (semantic version utility): https://github.com/caarlos0/svu
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
# Prerequisites
# --------------------------------------------------------------------------
if ! command -v svu >/dev/null 2>&1; then
  warn "This script requires 'svu' (semantic version utility), which is not on your PATH."
  warn "Install it, then re-run: ${SVU_URL}"
  exit 127
fi

# Latest existing "<image>/vX.Y.Z" tag for an image, or empty if none.
latest_tag_for() {
  local image="$1"
  { git tag --list "${image}/v*" \
      | grep -E "^${image}/v[0-9]+\.[0-9]+\.[0-9]+$" \
      | sort -V \
      | tail -n1 ; } || true
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
  last_tag="$(latest_tag_for "$image")"

  if [[ -n "$last_tag" ]]; then
    range="${last_tag}..HEAD"
    since="$last_tag"
  else
    range="HEAD"
    since="repo start"
  fi

  # Skip images with no commits touching them since the last release.
  if [[ -z "$(git log --format=%H "$range" -- "$image")" ]]; then
    log "· ${image}: no changes since ${since}"
    continue
  fi

  # Let svu parse the conventional commits and compute the next version,
  # scoped to this image's tags and directory. --always is safe here because
  # we've already confirmed the directory changed.
  if ! new_tag="$(svu next \
        --always \
        --tag.prefix "${image}/v" \
        --tag.pattern "${image}/v[0-9]*" \
        --log.directory "$image" 2>/dev/null)"; then
    warn "✗ ${image}: svu could not compute a version; skipping"
    continue
  fi

  # Guard against tagging a version that somehow already exists.
  if git rev-parse -q --verify "refs/tags/${new_tag}" >/dev/null; then
    warn "✗ ${image}: computed tag ${new_tag} already exists; skipping"
    continue
  fi

  info "✓ ${image}: ${since} -> ${new_tag}"

  if [[ "$DRY_RUN" == 0 ]]; then
    git tag -a "$new_tag" -m "$new_tag" "$HEAD_SHA"
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
