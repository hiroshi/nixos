#!/bin/sh
# Deletes stale local images, keeping the newest N tags per repository.
#
# dockerd has no image GC of its own -- unlike kubelet/containerd, nothing
# ever reclaims images it isn't currently running, so a pod that builds
# images grows /var/lib/docker without bound until the LV fills up.
#
# The policy is deliberately "newest N tags per repository" rather than
# dockerd's own `POST /images/prune?filters={"until":...}`: that filter keys
# off the image's *creation* timestamp, not last use, and reproducible base
# images bake in a fixed (usually epoch) creation date -- `nixos/nix:latest`
# reports 1970-01-01 and `docker:27-dind` 2025-02-02, so any `until` window
# short enough to catch last week's build tags also deletes the base images
# every build depends on, forcing a re-pull each time. Ranking within a
# repository sidesteps dates entirely: repositories that only ever hold one
# or two tags (the base images) are never touched, while the churn of
# per-commit build tags is capped.
set -eu

DOCKER_SOCK=${DOCKER_SOCK:-/run/docker-sock/docker.sock}
IMAGE_GC_KEEP_PER_REPO=${IMAGE_GC_KEEP_PER_REPO:-2}

api() { curl -sf --unix-socket "$DOCKER_SOCK" "$@"; }

images="$(api 'http://localhost/images/json')" || exit 0

refs="$(printf '%s' "$images" | jq -r --argjson keep "$IMAGE_GC_KEEP_PER_REPO" '
  [ .[]
    | . as $img
    | (.RepoTags // [])[]
    | select(startswith("<none>") | not)
    # "ghcr.io/hiroshi/claude-code:abc123" -> repo "ghcr.io/hiroshi/claude-code".
    # Only the final ":tag" is stripped, so a registry:port host survives.
    | { ref: ., repo: sub(":[^:/]+$"; ""), created: $img.Created }
  ]
  | group_by(.repo)
  | map(sort_by(.created) | reverse | .[$keep:])
  | flatten
  | .[].ref
')"

# Rebuilding an existing tag leaves the previous image ID untagged, and the
# rank-per-repository pass above can't see those at all -- they have no
# RepoTags to rank. dockerd's stock dangling-only prune is exactly the right
# tool for that half, and unlike the age-based filter it can't touch a tagged
# base image.
api -X POST 'http://localhost/images/prune?filters=%7B%22dangling%22%3A%5B%22true%22%5D%7D' \
  | jq -r '"image-gc: pruned \(.ImagesDeleted | length // 0) dangling image(s), \(.SpaceReclaimed // 0) bytes"' \
  || echo "image-gc: dangling prune failed, continuing"

[ -n "$refs" ] || exit 0

printf '%s\n' "$refs" | while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  # Untagging, not force-deleting: an image still backing a container must not
  # be yanked out from under it. dockerd refuses those, and skipping is the
  # right outcome -- the tag gets collected on a later pass once it's idle.
  if api -X DELETE "http://localhost/images/$ref" >/dev/null; then
    echo "image-gc: removed $ref"
  else
    echo "image-gc: skipped $ref (in use, or already gone)"
  fi
done
