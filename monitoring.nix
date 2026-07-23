# Minimal, short-retention diagnostic monitoring stack: exists solely to
# observe the `dockerd` sidecar container's memory usage over time (see
# k8s/claude-code/deployment.yaml) to inform tuning its memory limits --
# there's a history of dockerd OOMKilled incidents on this cluster (PR #16,
# #18, #19), already addressed once via a headroom bump, and this stack is
# meant to give real data for the next tuning pass instead of guessing again.
#
# A single OpenTelemetry Collector DaemonSet handles both metrics (via the
# `kubeletstats` receiver, polling this node's kubelet Summary API) and logs
# (via the `filelog` receiver, reading /var/log/pods), exporting both
# natively as OTLP into VictoriaMetrics and VictoriaLogs respectively -- one
# agent process instead of a separate vmagent + Fluent Bit pair, since both
# would need the same node-local DaemonSet access anyway and this is a
# single-node cluster with no isolation benefit from splitting them.
#
# kubeletstats (Summary API), not a `prometheus` receiver scraping
# /metrics/cadvisor directly: the dockerd sidecar's pod runs under
# `runtimeClassName: kata` (see k8s/claude-code/deployment.yaml), and
# Kata's per-container cgroups live inside the guest VM -- the host's
# cadvisor only ever exposes a synthetic `kata_overhead` entry for the
# whole sandbox, never a `container="dockerd"` series (confirmed
# empirically: grepping a full /metrics/cadvisor dump for it comes up
# empty). `kubectl top pod --containers` goes through the same Summary API
# this receiver uses and correctly reports the dockerd container's memory,
# so it's the only one of the two that actually works for this cluster.
#
# VictoriaMetrics/VictoriaLogs (not Prometheus/Loki) chosen for lower memory
# footprint on a 16GB node with an OOM history -- both are single lean
# binaries with no Operator/CRD or distributor/ingester/compactor layers.
# Dashboarding is via vmsingle's bundled vmui (zero extra cost) rather than
# Grafana, since the immediate need is one narrow PromQL query over a few
# days, not ongoing dashboarding -- Grafana remains an easy Phase 2 add-on
# if that changes later.
#
# All RBAC is left to each Helm chart's own bundled ServiceAccount/
# ClusterRole/ClusterRoleBinding templates rather than hand-written
# manifests, since this cluster's restrictive default RBAC has already
# produced several subtle permission surprises this project.
{ config, lib, pkgs, ... }:

{
  services.k3s.autoDeployCharts = {

    victoria-metrics-single = {
      repo = "https://victoriametrics.github.io/helm-charts";
      name = "victoria-metrics-single";
      version = "0.39.0";
      hash = "sha256-oZ9XYchH2lE9RavPHa2Ourk9kOrt40k0tuPrRHA0vZU=";
      targetNamespace = "monitoring";
      createNamespace = true;
      values = {
        server = {
          retentionPeriod = "7d";
          persistentVolume = {
            enabled = true;
            storageClassName = "topolvm-provisioner";
            size = "3Gi";
          };
          resources = {
            requests.memory = "512Mi";
            limits.memory = "512Mi";
          };
        };
      };
    };

    victoria-logs-single = {
      repo = "https://victoriametrics.github.io/helm-charts";
      name = "victoria-logs-single";
      version = "0.13.9";
      hash = "sha256-WTs/jg0m65JaDj1ZhI0XoKvJRZeALcJrqOCSVYQXaoY=";
      targetNamespace = "monitoring";
      createNamespace = true;
      values = {
        server = {
          retentionPeriod = "3d";
          extraArgs = {
            "retention.maxDiskSpaceUsageBytes" = "1750MB";
          };
          persistentVolume = {
            enabled = true;
            storageClassName = "topolvm-provisioner";
            size = "2Gi";
          };
          resources = {
            requests.memory = "256Mi";
            limits.memory = "256Mi";
          };
        };
      };
    };

    opentelemetry-collector = {
      repo = "https://open-telemetry.github.io/opentelemetry-helm-charts";
      name = "opentelemetry-collector";
      version = "0.165.0";
      hash = "sha256-tZLqBk2bkGkwysLSK4jusbyC8S1e0H/SB5LeLAUco8U=";
      targetNamespace = "monitoring";
      createNamespace = true;
      values = {
        mode = "daemonset"; # both the kubeletstats and filelog
                             # (/var/log/pods) receivers need node-local
                             # access.

        # This chart version hard-requires image.repository to be set
        # explicitly (no more empty-string-falls-back-to-contrib default);
        # contrib is required here since filelog/prometheus/k8sattributes
        # all live in the contrib distribution, not core.
        image.repository = "otel/opentelemetry-collector-contrib";

        presets = {
          logsCollection.enabled = true;       # wires up the filelog
                                                # receiver + hostPath mounts
          kubernetesAttributes.enabled = true; # k8sattributes processor:
                                                # pod/namespace/node
                                                # enrichment for both
                                                # metrics and logs
          kubeletMetrics.enabled = true; # wires up the kubeletstats
                                          # receiver + its ClusterRole
                                          # rule (nodes/stats) -- see the
                                          # file header for why this is
                                          # used over a prometheus/cadvisor
                                          # receiver here.
        };

        # K8S_NODE_IP is not declared via extraEnvs here: the chart's
        # _pod.tpl already injects it automatically whenever
        # presets.kubernetesAttributes.enabled is true and mode is
        # "daemonset" (both true above), so an explicit extraEnvs entry
        # for the same key collides with it (duplicate env "K8S_NODE_IP").
        # It's the same env var the kubeletMetrics preset points its
        # kubeletstats receiver's endpoint at, below.

        resources = {
          requests.memory = "256Mi";
          limits.memory = "256Mi";
        };

        config = {
          receivers = {
            # kubelet's serving cert isn't signed by a CA the collector
            # trusts by default -- same reason the old prometheus
            # receiver's tls_config.insecure_skip_verify was needed to
            # actually connect. Merges with (rather than replaces) the
            # kubeletMetrics preset's own receivers.kubeletstats config
            # (collection_interval, auth_type, endpoint) above.
            kubeletstats.insecure_skip_verify = true;
          };

          processors = {
            memory_limiter = {
              check_interval = "5s";
              limit_mib = 200;      # tuned to the 256Mi pod memory limit,
              spike_limit_mib = 50; # leaving headroom for Go runtime overhead
            };
          };

          exporters = {
            "otlphttp/vm".metrics_endpoint =
              "http://victoria-metrics-single-server.monitoring.svc.cluster.local:8428/opentelemetry/v1/metrics";
            "otlphttp/vl".logs_endpoint =
              "http://victoria-logs-single-server.monitoring.svc.cluster.local:9428/insert/opentelemetry/v1/logs";
          };

          service.pipelines = {
            # filelog and k8sattributes come from the presets above, but
            # providing an explicit `service.pipelines` block overrides
            # rather than appends, so they're still named explicitly here.
            # kubeletstats isn't listed in `receivers` below: the
            # kubeletMetrics preset appends it into this same list
            # automatically (see chart's _config.tpl), so listing it here
            # too would just be a redundant duplicate.
            metrics = {
              receivers = [ ];
              processors = [ "k8sattributes" "memory_limiter" "batch" ];
              exporters = [ "otlphttp/vm" ];
            };
            logs = {
              receivers = [ "filelog" ];
              processors = [ "k8sattributes" "memory_limiter" "batch" ];
              exporters = [ "otlphttp/vl" ];
            };
          };
        };
      };
    };
  };
}
