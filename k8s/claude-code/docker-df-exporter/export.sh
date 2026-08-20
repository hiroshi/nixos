#!/bin/sh
# Polls dockerd's own Engine API (/system/df) for its disk-usage breakdown
# and pushes it to VictoriaMetrics as plain Prometheus text lines.
#
# This exists because dockerd's storage bookkeeping (images/containers/
# volumes/build cache) isn't visible through kubelet/cAdvisor at all -- it's
# a dockerd-only concept, so the cluster's existing kubeletstats-based OTel
# Collector metrics can't cover it. Polling dockerd's API directly and
# pushing straight to VictoriaMetrics's import endpoint sidesteps that
# entirely, no collector config needed.
#
# The same loop also drives image-gc.sh on a much slower timer: it already
# holds the docker socket, and dockerd has no image GC of its own.
set -eu

DOCKER_SOCK=${DOCKER_SOCK:-/run/docker-sock/docker.sock}
VM_IMPORT_URL=${VM_IMPORT_URL:-http://victoria-metrics-single-server.monitoring.svc.cluster.local:8428/api/v1/import/prometheus}
POLL_INTERVAL_SECONDS=${POLL_INTERVAL_SECONDS:-60}
RETRY_INTERVAL_SECONDS=${RETRY_INTERVAL_SECONDS:-5}
# 0 disables image GC entirely; otherwise it runs once at startup and then on
# this interval, independent of the (much shorter) metrics poll.
IMAGE_GC_INTERVAL_SECONDS=${IMAGE_GC_INTERVAL_SECONDS:-3600}

next_image_gc=0

while true; do
  # dockerd's sock isn't necessarily up yet right after pod start (the
  # dockerd sidecar creates it once its own init finishes, which races
  # against this container's start), and set -e would otherwise turn that
  # transient failure into the whole script exiting -- CrashLoopBackOff-ing
  # this sidecar on every pod (re)create until dockerd wins the race.
  # Retry on a short interval instead of treating it as fatal.
  if ! df="$(curl -sf --unix-socket "$DOCKER_SOCK" 'http://localhost/system/df?verbose=1')"; then
    sleep "$RETRY_INTERVAL_SECONDS"
    continue
  fi

  images_bytes="$(echo "$df" | jq '.LayersSize // 0')"
  containers_bytes="$(echo "$df" | jq '[.Containers[]?.SizeRw // 0] | add // 0')"
  volumes_bytes="$(echo "$df" | jq '[.Volumes[]?.UsageData.Size // 0] | add // 0')"
  # Build cache is reported split by dockerd's own `Shared` flag rather than
  # as one sum, because the two halves behave completely differently:
  #
  #   build_cache        -- records nothing else references. This is exactly
  #                         what `docker system df` prints as Build Cache, and
  #                         the only part `builder.gc.defaultKeepStorage` can
  #                         hold to its cap, so it's the series to compare
  #                         against that limit.
  #   build_cache_shared -- records whose bytes the image store also holds a
  #                         reference to. BuildKit's GC can't release these
  #                         while those images exist; deleting the image is
  #                         what converts them into (collectable) unshared
  #                         cache. Summing both halves into one series makes
  #                         the cap look breached when it isn't -- measured
  #                         2026-08-21: deleting 9 stale image tags moved
  #                         1.24GB straight from shared to unshared, total
  #                         unchanged at 8.67GB, while `docker system df`
  #                         kept reporting the capped number the whole time.
  buildcache_bytes="$(echo "$df" | jq '[.BuildCache[]? | select(.Shared | not) | .Size // 0] | add // 0')"
  buildcache_shared_bytes="$(echo "$df" | jq '[.BuildCache[]? | select(.Shared) | .Size // 0] | add // 0')"
  # "reclaimable" == cache entries not currently backing a running build,
  # same distinction `docker system df`'s own RECLAIMABLE column draws.
  buildcache_reclaimable_bytes="$(echo "$df" | jq '[.BuildCache[]? | select(.InUse == false) | .Size // 0] | add // 0')"

  printf 'docker_disk_usage_bytes{type="images"} %s\ndocker_disk_usage_bytes{type="containers"} %s\ndocker_disk_usage_bytes{type="volumes"} %s\ndocker_disk_usage_bytes{type="build_cache"} %s\ndocker_disk_usage_bytes{type="build_cache_shared"} %s\ndocker_disk_usage_reclaimable_bytes{type="build_cache"} %s\n' \
    "$images_bytes" "$containers_bytes" "$volumes_bytes" "$buildcache_bytes" "$buildcache_shared_bytes" "$buildcache_reclaimable_bytes" \
    | curl -sf --data-binary @- "$VM_IMPORT_URL" || true

  if [ "$IMAGE_GC_INTERVAL_SECONDS" -gt 0 ]; then
    now="$(date +%s)"
    if [ "$now" -ge "$next_image_gc" ]; then
      # Never fatal: a failed GC pass must not take the metrics loop down
      # with it, and the next pass will retry anyway.
      /image-gc.sh || echo "image-gc: pass failed, continuing"
      next_image_gc=$((now + IMAGE_GC_INTERVAL_SECONDS))
    fi
  fi

  sleep "$POLL_INTERVAL_SECONDS"
done
