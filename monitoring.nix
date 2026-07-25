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
#
# Phase 2 (this update): the need moved from "one narrow PromQL query over a
# few days" to ongoing dashboarding, and from "reachable via kubectl
# port-forward over the tailnet" to "reachable directly, no port-forward" --
# so Perses was added (see the `perses` chart below), fed by VictoriaMetrics
# as a plain Prometheus-API datasource and VictoriaLogs via its official
# `VictoriaLogsDatasource` plugin (chosen over Grafana specifically because
# Grafana's VictoriaLogs plugin is an unsigned community plugin needing
# `allow_loading_unsigned_plugins`, whereas Perses's is first-class/official
# -- and Perses's default `enable_auth: false` needs no admin-password Secret
# to manage, relying entirely on the Tailscale network boundary below
# instead). vmui is still there underneath (unauthenticated on its ClusterIP
# Service) for zero-cost ad-hoc queries.
#
# External access is via the Tailscale Kubernetes operator (`tailscale-operator`
# chart below) rather than the cloudflared quick-tunnel pattern used by
# `myapp` -- that pattern hands out a random, unauthenticated *.trycloudflare.com
# hostname to anyone who finds it, which is fine for a toy Rails app but not
# for a dashboard with cluster-internal data. The operator gives each Ingress
# its own tailnet-only MagicDNS name (`<name>.<tailnet>.ts.net`), reachable
# from any device already joined to the tailnet -- the same trust boundary
# already used to lock down kube-apiserver access in configuration.nix -- with
# no separate auth layer to manage and no public exposure.
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
            kubeletstats = {
              insecure_skip_verify = true;
              # The preset's default metric_groups is [container, pod,
              # node] -- "volume" is opt-in and needed to get PVC
              # capacity/usage (k8s.volume.capacity/available/inodes*)
              # for the topolvm-provisioner PVCs used by this stack.
              metric_groups = [ "container" "pod" "node" "volume" ];
            };
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

    # Tailscale Kubernetes operator: reconciles `Ingress` objects with
    # `ingressClassName: tailscale` into per-Ingress tailnet nodes, each
    # reachable at its own MagicDNS name with no separate auth layer and no
    # public exposure. Runs in its own `tailscale` namespace (cluster-scoped
    # CRDs + RBAC, kept separate from the `monitoring` workloads it exposes).
    #
    # Prerequisite (can't be done from this repo/pod -- needs the Tailscale
    # admin console): create an OAuth client under
    # https://login.tailscale.com/admin/settings/oauth scoped to write
    # "Devices Core", tag it `tag:k8s-operator`, and grant that tag (plus
    # `tag:k8s`, used for the proxy Pods the operator creates per-Ingress)
    # tag-owner permissions in the tailnet's ACL policy -- see
    # https://tailscale.com/kb/1236/kubernetes-operator for the exact ACL
    # stanza. Then, before this chart installs, precreate the credentials
    # Secret it expects (same imperative-secret pattern as `myapp-secrets` in
    # k8s/myapp -- never commit OAuth credentials to this repo):
    #   kubectl create secret generic operator-oauth -n tailscale \
    #     --from-literal=client_id=<...> --from-literal=client_secret=<...>
    # `oauth.clientId`/`oauth.clientSecret` are deliberately left unset below
    # so the chart falls back to that precreated Secret instead.
    tailscale-operator = {
      repo = "https://pkgs.tailscale.com/helmcharts";
      name = "tailscale-operator";
      version = "1.98.9";
      hash = "sha256-Px/6M2IKhrpX0HQjTX3GvR95/5JyjykXauUhyXGUMco=";
      targetNamespace = "tailscale";
      createNamespace = true;
      values = {
        operatorConfig.resources = {
          requests.memory = "64Mi";
          limits.memory = "128Mi";
        };
        # Note: each exposed Ingress also gets its own tailscale proxy Pod
        # (StatefulSet, ~30-50Mi each) that the operator creates on demand --
        # not covered by this resources block, and not yet pinned via a
        # ProxyClass. One Ingress (perses, below) for now.
      };
    };

    # Perses: a CNCF Sandbox dashboard tool, chosen over Grafana specifically
    # for this stack -- see the file header for the full reasoning (native
    # VictoriaLogs plugin instead of an unsigned community one, no
    # admin-password Secret to manage since `enable_auth` defaults to false
    # and the Tailscale boundary above is the real access control, lighter
    # footprint).
    perses = {
      repo = "https://perses.github.io/helm-charts";
      # The plain `perses` chart, not `perses-operator` (which adds
      # cluster-scoped CRDs) -- matches this file's existing preference for
      # avoiding Operator/CRD layers where a plain Deployment will do.
      name = "perses";
      version = "0.22.0";
      hash = "sha256-R88/8Et5Z1XiWL4u/uGwP9BOWHW8uzxOZiOFz88vSfw=";
      targetNamespace = "monitoring";
      createNamespace = true;
      values = {
        # No PVC: datasources are provisioned as code below, nothing in
        # Perses's own state worth persisting, and the ~4Gi remaining in the
        # 9Gi usable TopoLVM pool (see PR #22) is better spent elsewhere.
        persistence.enabled = false;

        resources = {
          requests.memory = "128Mi";
          limits.memory = "256Mi";
        };

        # The chart's default `securityContext.readOnlyRootFilesystem = true`
        # otherwise breaks plugin loading entirely: per Perses's Dockerfile,
        # `/etc/perses/plugins` is baked into the image as an *empty*
        # directory, and the bundled plugin archives under
        # `/etc/perses/plugins-archive` are only extracted into it at
        # container *startup* (see
        # https://perses.dev/perses/docs/configuration/load-plugin/) -- with
        # no writable volume mounted there, that extraction silently fails
        # and `/api/v1/plugins` comes back `[]` (confirmed live: no explore
        # plugin available for any datasource, not just VictoriaLogs).
        volumes = [
          { name = "plugins"; emptyDir = { }; }
        ];
        volumeMounts = [
          { name = "plugins"; mountPath = "/etc/perses/plugins"; }
        ];

        # `config.security.authentication.enable_auth` is left at its chart
        # default (false, no login) -- the Tailscale Ingress below is this
        # dashboard's only access control, deliberately, rather than also
        # managing a Perses admin-password Secret for a single-user cluster.

        # Datasources are provisioned via the `sidecar` mechanism (a
        # k8s-sidecar container watching labelled ConfigMaps), not the
        # chart's own `datasources:` values field -- that field is marked
        # `DEPRECATED: will be removed in the future release` in this
        # chart's values.yaml, so a new deployment shouldn't start on it.
        sidecar = {
          enabled = true;
          # The datasource ConfigMaps below live in this same `monitoring`
          # namespace as Perses itself, so a namespace-scoped Role is enough
          # -- no need for the ClusterRole that `allNamespaces = true` would
          # require (this cluster's restrictive default RBAC has already
          # produced several subtle permission surprises, so scope tightly).
          allNamespaces = false;
          resources = {
            requests.memory = "64Mi";
            limits.memory = "128Mi";
          };
        };

        # Exposed via the Tailscale Ingress in extraObjects below instead --
        # the tailscale-operator's expected shape (defaultBackend + tls.hosts
        # for the MagicDNS name) doesn't match what this chart's own
        # `ingress:` block generates (host-based `rules`), same reasoning as
        # the datasource ConfigMaps below being hand-written too.
        ingress.enabled = false;

        extraObjects = [
          {
            apiVersion = "networking.k8s.io/v1";
            kind = "Ingress";
            metadata = {
              name = "perses";
              namespace = "monitoring";
            };
            spec = {
              ingressClassName = "tailscale";
              defaultBackend.service = {
                name = "perses"; # chart's fullname helper collapses to just
                                 # the release name ("perses") since the
                                 # release name already contains the chart
                                 # name -- see helpers/_identity.tpl.
                port.number = 8080;
              };
              # Sets the MagicDNS name: https://perses.<tailnet>.ts.net
              tls = [ { hosts = [ "perses" ]; } ];
            };
          }

          # VictoriaMetrics implements the Prometheus HTTP API natively, so
          # the built-in `PrometheusDatasource` plugin works directly -- no
          # VictoriaMetrics-specific plugin needed. Server-side `proxy`
          # (not `directUrl`) is required: the VM Service is only reachable
          # from inside the cluster, not from a tailnet browser.
          {
            apiVersion = "v1";
            kind = "ConfigMap";
            metadata = {
              name = "perses-datasource-victoriametrics";
              namespace = "monitoring";
              labels."perses.dev/resource" = "true";
            };
            # `allowedEndpoints` below is the standard Prometheus API surface
            # per https://perses.dev/plugins/docs/prometheus/model/ -- not
            # yet verified against every panel type this cluster might use;
            # if a query fails with an endpoint-not-allowed error after
            # rollout, add the missing pattern here.
            #
            # The sidecar names the file it writes into
            # /etc/perses/provisioning after this data key, not after the
            # ConfigMap's own name -- it must be unique across both
            # ConfigMaps below, or the second write silently clobbers the
            # first and only one datasource ever actually loads (confirmed
            # live: both were writing to a shared "datasource.yaml").
            data."victoriametrics-datasource.yaml" = builtins.toJSON {
              kind = "GlobalDatasource";
              metadata.name = "VictoriaMetrics";
              spec = {
                default = true;
                plugin = {
                  kind = "PrometheusDatasource";
                  spec.proxy = {
                    kind = "HTTPProxy";
                    spec = {
                      url = "http://victoria-metrics-single-server.monitoring.svc.cluster.local:8428";
                      allowedEndpoints = [
                        { endpointPattern = "/api/v1/labels"; method = "POST"; }
                        { endpointPattern = "/api/v1/series"; method = "POST"; }
                        { endpointPattern = "/api/v1/metadata"; method = "GET"; }
                        { endpointPattern = "/api/v1/query"; method = "POST"; }
                        { endpointPattern = "/api/v1/query_range"; method = "POST"; }
                        { endpointPattern = "/api/v1/label/([a-zA-Z0-9_-]+)/values"; method = "GET"; }
                      ];
                    };
                  };
                };
              };
            };
          }

          # VictoriaLogs isn't Loki-API-compatible for querying, so it needs
          # its own official plugin (this is the thing Grafana doesn't have
          # a first-class equivalent of -- see file header). Same
          # server-side `proxy` reasoning as VictoriaMetrics above.
          {
            apiVersion = "v1";
            kind = "ConfigMap";
            metadata = {
              name = "perses-datasource-victorialogs";
              namespace = "monitoring";
              labels."perses.dev/resource" = "true";
            };
            # `allowedEndpoints` below is the LogsQL query surface per
            # https://perses.dev/plugins/docs/victorialogs/model/. Both GET
            # and POST are allowed for each path -- confirmed live that the
            # Log Query plugin actually calls /select/logsql/query via POST
            # (GET-only, per the docs example, was rejected with "forbidden
            # access: ... not allowed to use this endpoint ... with the HTTP
            # method POST"); the other two paths aren't yet confirmed to need
            # POST too, but allowed defensively rather than debugging them
            # one at a time.
            data."victorialogs-datasource.yaml" = builtins.toJSON {
              kind = "GlobalDatasource";
              metadata.name = "VictoriaLogs";
              spec = {
                default = false;
                plugin = {
                  kind = "VictoriaLogsDatasource";
                  spec.proxy = {
                    kind = "HTTPProxy";
                    spec = {
                      url = "http://victoria-logs-single-server.monitoring.svc.cluster.local:9428";
                      allowedEndpoints = [
                        { endpointPattern = "/select/logsql/query"; method = "GET"; }
                        { endpointPattern = "/select/logsql/query"; method = "POST"; }
                        { endpointPattern = "/select/logsql/field_names"; method = "GET"; }
                        { endpointPattern = "/select/logsql/field_names"; method = "POST"; }
                        { endpointPattern = "/select/logsql/field_values"; method = "GET"; }
                        { endpointPattern = "/select/logsql/field_values"; method = "POST"; }
                      ];
                    };
                  };
                };
              };
            };
          }

          # Dashboards are provisioned as code the same way as the
          # datasources above, rather than relying on the UI's own "Save"
          # (which needs a Project to exist first, and this is more in
          # keeping with the rest of this file anyway). Per
          # https://perses.dev/helm-charts/docs/managing-resources-with-configmaps/,
          # a Dashboard's Project must exist before the Dashboard itself is
          # provisioned, and each ConfigMap should hold exactly one resource
          # (1MB ConfigMap data limit) -- hence two separate ConfigMaps here,
          # not one.
          #
          # Project name "k3s" matches the one already created by hand via
          # the Perses UI before this was provisioned as code, rather than
          # introducing a second, redundant project.
          {
            apiVersion = "v1";
            kind = "ConfigMap";
            metadata = {
              name = "perses-project-k3s";
              namespace = "monitoring";
              labels."perses.dev/resource" = "true";
            };
            data."project.json" = builtins.toJSON {
              kind = "Project";
              metadata.name = "k3s";
              spec.display.name = "k3s";
            };
          }

          {
            apiVersion = "v1";
            kind = "ConfigMap";
            metadata = {
              name = "perses-dashboard-logs";
              namespace = "monitoring";
              labels."perses.dev/resource" = "true";
            };
            # This is a direct transcription of a dashboard actually built
            # and JSON-exported from the Perses UI (three panels: raw logs,
            # PVC usage %, PVC usage bytes), not a hand-guessed one -- the
            # only change from the export is `legend.mode`: the UI's own
            # export had it as `null` on both TimeSeriesChart panels, which
            # the chart's bundled TimeSeriesChart plugin (0.12.1) rejects
            # outright ("conflicting values null and \"list\""/"\"table\""),
            # confirmed live via the UI's own Save erroring on exactly this
            # field even with "List" apparently selected on screen -- set to
            # "list" explicitly here instead.
            #
            # PVC-only filter (k8s.volume.name is unique to real PVCs here --
            # "home"/"storage"/"server-volume" -- unlike the many noise
            # volumes, see the volume-name survey in project memory);
            # server-volume is shared by both VictoriaMetrics and
            # VictoriaLogs pods, hence the pod name in seriesNameFormat to
            # tell them apart.
            data."dashboard.json" = builtins.toJSON {
              kind = "Dashboard";
              metadata = {
                name = "logs";
                project = "k3s";
                version = 0;
                tags = [ ];
              };
              spec = {
                display.name = "logs";
                panels = {
                  "e8155cd770c6422ebc6a1eeaf38e7fc6" = {
                    kind = "Panel";
                    spec = {
                      display.name = "";
                      plugin = {
                        kind = "LogsTable";
                        spec = {
                          showTime = true;
                          allowWrap = true;
                          enableDetails = true;
                        };
                      };
                      queries = [
                        {
                          kind = "LogQuery";
                          spec.plugin = {
                            kind = "VictoriaLogsLogQuery";
                            spec = {
                              query = "*";
                              datasource = {
                                kind = "VictoriaLogsDatasource";
                                name = "victorialogs";
                              };
                            };
                          };
                        }
                      ];
                    };
                  };

                  "bbaa26b433aa401891e689b5e6007f67" = {
                    kind = "Panel";
                    spec = {
                      display.name = "PVC %";
                      plugin = {
                        kind = "TimeSeriesChart";
                        spec = {
                          yAxis = {
                            show = true;
                            label = "";
                            format.unit = "percent";
                          };
                          legend = {
                            position = "bottom";
                            mode = "list";
                          };
                        };
                      };
                      queries = [
                        {
                          kind = "TimeSeriesQuery";
                          spec.plugin = {
                            kind = "PrometheusTimeSeriesQuery";
                            spec = {
                              query = ''
                                100 * (1 - (
                                  {__name__="k8s.volume.available", k8s.volume.name=~"home|storage|server-volume"}
                                  /
                                  {__name__="k8s.volume.capacity", k8s.volume.name=~"home|storage|server-volume"}
                                ))'';
                              seriesNameFormat = "{{k8s.pod.name}}: {{k8s.volume.name}}";
                            };
                          };
                        }
                      ];
                    };
                  };

                  "d1850588f54947dea396d8089348a780" = {
                    kind = "Panel";
                    spec = {
                      display.name = "PVC usage";
                      plugin = {
                        kind = "TimeSeriesChart";
                        spec = {
                          yAxis = {
                            show = true;
                            label = "usage";
                            format.unit = "decbytes";
                          };
                          legend = {
                            position = "bottom";
                            mode = "list";
                          };
                        };
                      };
                      queries = [
                        {
                          kind = "TimeSeriesQuery";
                          spec.plugin = {
                            kind = "PrometheusTimeSeriesQuery";
                            spec = {
                              query = ''
                                {__name__="k8s.volume.capacity", k8s.volume.name=~"home|storage|server-volume"}
                                - {__name__="k8s.volume.available", k8s.volume.name=~"home|storage|server-volume"}'';
                              seriesNameFormat = "{{k8s.pod.name}}: {{k8s.volume.name}}";
                            };
                          };
                        }
                      ];
                    };
                  };
                };

                layouts = [
                  {
                    kind = "Grid";
                    spec = {
                      display = {
                        title = "Log";
                        collapse.open = true;
                      };
                      items = [
                        {
                          x = 0;
                          y = 0;
                          width = 24;
                          height = 6;
                          content."$ref" = "#/spec/panels/e8155cd770c6422ebc6a1eeaf38e7fc6";
                        }
                      ];
                      repeatVariable = "";
                    };
                  }
                  {
                    kind = "Grid";
                    spec = {
                      display = {
                        title = "PVC";
                        collapse.open = true;
                      };
                      items = [
                        {
                          x = 0;
                          y = 0;
                          width = 12;
                          height = 6;
                          content."$ref" = "#/spec/panels/bbaa26b433aa401891e689b5e6007f67";
                        }
                        {
                          x = 12;
                          y = 0;
                          width = 12;
                          height = 6;
                          content."$ref" = "#/spec/panels/d1850588f54947dea396d8089348a780";
                        }
                      ];
                      repeatVariable = "";
                    };
                  }
                ];

                variables = [ ];
                duration = "1h";
                refreshInterval = "0s";
              };
            };
          }
        ];
      };
    };
  };
}
