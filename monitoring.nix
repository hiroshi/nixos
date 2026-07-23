# Minimal, short-retention diagnostic monitoring stack: exists solely to
# observe the `dockerd` sidecar container's memory usage over time (see
# k8s/claude-code/deployment.yaml) to inform tuning its memory limits --
# there's a history of dockerd OOMKilled incidents on this cluster (PR #16,
# #18, #19), already addressed once via a headroom bump, and this stack is
# meant to give real data for the next tuning pass instead of guessing again.
#
# A single OpenTelemetry Collector DaemonSet handles both metrics (scraping
# this node's kubelet /metrics/cadvisor via a `prometheus` receiver, chosen
# over the `kubeletstats` receiver because cadvisor exposes
# `container_memory_working_set_bytes{container="dockerd"}` verbatim instead
# of going through an extra OTel-semantic-convention rename) and logs (via
# the `filelog` receiver, reading /var/log/pods), exporting both natively as
# OTLP into VictoriaMetrics and VictoriaLogs respectively -- one agent
# process instead of a separate vmagent + Fluent Bit pair, since both would
# need the same node-local DaemonSet access anyway and this is a
# single-node cluster with no isolation benefit from splitting them.
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
# ClusterRole/ClusterRoleBinding templates (only one extra rule is added via
# values, for the OTel Collector's cadvisor scrape) rather than hand-written
# manifests, since this cluster's restrictive default RBAC has already
# produced several subtle permission surprises this project.
{ config, lib, pkgs, ... }:

{
  services.k3s.autoDeployCharts = {

    victoria-metrics-single = {
      repo = "https://victoriametrics.github.io/helm-charts";
      name = "victoria-metrics-single";
      version = "0.39.0";
      hash = lib.fakeHash; # placeholder -- no working `nix` binary in this
                           # dev container to precompute a real hash. Fill
                           # in the real value from the `hash mismatch ...
                           # got: sha256-...` error the first time
                           # `nixos-rebuild` actually runs on the real host
                           # (same workflow topolvm.nix's hash went through).
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
      hash = lib.fakeHash; # placeholder, see note above
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
      hash = lib.fakeHash; # placeholder, see note above
      targetNamespace = "monitoring";
      createNamespace = true;
      values = {
        mode = "daemonset"; # both the prometheus (kubelet/cadvisor) and
                             # filelog (/var/log/pods) receivers need
                             # node-local access.

        presets = {
          logsCollection.enabled = true;       # wires up the filelog
                                                # receiver + hostPath mounts
          kubernetesAttributes.enabled = true; # k8sattributes processor:
                                                # pod/namespace/node
                                                # enrichment for both
                                                # metrics and logs
          # kubeletMetrics preset deliberately NOT used here -- the
          # prometheus receiver scraping /metrics/cadvisor directly
          # preserves cadvisor's exact metric/label names, whereas
          # kubeletstats derives from the kubelet Summary API and
          # re-emits under renamed OTel semantic-convention names, an
          # extra translation hop not worth it for this narrow goal.
        };

        # Needed so the prometheus receiver can address its own node's
        # kubelet.
        extraEnvs = [
          {
            name = "K8S_NODE_IP";
            valueFrom.fieldRef.fieldPath = "status.hostIP";
          }
        ];

        clusterRole = {
          create = true;
          rules = [
            # kubelet authorizes a direct (non-apiserver-proxied)
            # /metrics/cadvisor scrape against this subresource.
            {
              apiGroups = [ "" ];
              resources = [ "nodes/metrics" ];
              verbs = [ "get" ];
            }
          ];
        };

        resources = {
          requests.memory = "256Mi";
          limits.memory = "256Mi";
        };

        config = {
          receivers = {
            prometheus.config.scrape_configs = [
              {
                job_name = "kubelet-cadvisor";
                scheme = "https";
                tls_config.insecure_skip_verify = true;
                authorization = {
                  type = "Bearer";
                  credentials_file = "/var/run/secrets/kubernetes.io/serviceaccount/token";
                };
                metrics_path = "/metrics/cadvisor";
                static_configs = [ { targets = [ "\${env:K8S_NODE_IP}:10250" ]; } ];
              }
            ];
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
            metrics = {
              receivers = [ "prometheus" ];
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
