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
set -eu

DOCKER_SOCK=${DOCKER_SOCK:-/run/docker-sock/docker.sock}
VM_IMPORT_URL=${VM_IMPORT_URL:-http://victoria-metrics-single-server.monitoring.svc.cluster.local:8428/api/v1/import/prometheus}
POLL_INTERVAL_SECONDS=${POLL_INTERVAL_SECONDS:-60}

while true; do
  df="$(curl -sf --unix-socket "$DOCKER_SOCK" 'http://localhost/system/df?verbose=1')"

  images_bytes="$(echo "$df" | jq '.LayersSize // 0')"
  containers_bytes="$(echo "$df" | jq '[.Containers[]?.SizeRw // 0] | add // 0')"
  volumes_bytes="$(echo "$df" | jq '[.Volumes[]?.UsageData.Size // 0] | add // 0')"
  buildcache_bytes="$(echo "$df" | jq '[.BuildCache[]?.Size // 0] | add // 0')"
  # "reclaimable" == cache entries not currently backing a running build,
  # same distinction `docker system df`'s own RECLAIMABLE column draws.
  buildcache_reclaimable_bytes="$(echo "$df" | jq '[.BuildCache[]? | select(.InUse == false) | .Size // 0] | add // 0')"

  printf 'docker_disk_usage_bytes{type="images"} %s\ndocker_disk_usage_bytes{type="containers"} %s\ndocker_disk_usage_bytes{type="volumes"} %s\ndocker_disk_usage_bytes{type="build_cache"} %s\ndocker_disk_usage_reclaimable_bytes{type="build_cache"} %s\n' \
    "$images_bytes" "$containers_bytes" "$volumes_bytes" "$buildcache_bytes" "$buildcache_reclaimable_bytes" \
    | curl -sf --data-binary @- "$VM_IMPORT_URL"

  sleep "$POLL_INTERVAL_SECONDS"
done
