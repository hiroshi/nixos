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
          # requests==limits at 256Mi/256Mi (the original value) left zero
          # headroom above VictoriaLogs's own cache sizing (which
          # auto-tunes to a fraction of the cgroup memory limit) -- a
          # burst shortly after startup (observed: part-merge right after
          # opening storage, 93 smallParts for the dataset at the time)
          # pushed past the 256Mi cap and OOMKilled the process on a
          # ~1-minute loop, CrashLoopBackOff for 4 days straight. Same
          # zero-headroom shape as the dockerd fix in PR #19. Confirmed
          # live via `kubectl patch` that raising just the limit to
          # 512Mi (leaving the request at 256Mi) fixes it.
          resources = {
            requests.memory = "256Mi";
            limits.memory = "512Mi";
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

        # The kubeletMetrics preset's ClusterRole only grants nodes/stats
        # (for the /stats/summary endpoint the always-on metric groups
        # use). k8s.container.memory_limit_utilization (enabled below)
        # additionally needs the receiver to hit kubelet's /pods endpoint
        # to read each container's declared memory limit -- that's proxied
        # through nodes/proxy, a separate RBAC resource. Without this rule
        # the /pods call 403s every scrape cycle and the receiver aborts
        # the *entire* scrape, silently dropping all metric groups
        # (container/pod/node/volume alike), not just the new one --
        # confirmed live via the collector's own error log.
        clusterRole.rules = [
          {
            apiGroups = [ "" ];
            resources = [ "nodes/proxy" ];
            verbs = [ "get" ];
          }
        ];

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
              # k8s.container.memory_limit_utilization is opt-in (disabled
              # by default) -- needed for the memory-%-of-limit panel,
              # same reasoning as the "volume" group above for PVC %.
              metrics = {
                "k8s.container.memory_limit_utilization".enabled = true;
              };
            };

            # TopoLVM's lvmd exposes the LVM volume group's real
            # size/available bytes (topolvm_volumegroup_size_bytes /
            # topolvm_volumegroup_available_bytes, labeled by device_class)
            # on its own plain Prometheus /metrics -- see the new
            # topolvm-lvmd-metrics Service in topolvm.nix, added because the
            # topolvm chart doesn't expose that port via any Service itself.
            # A static target (not kubernetes_sd_configs-based discovery) is
            # enough: single-node cluster, one lvmd Pod, one Service.
            prometheus.config.scrape_configs = [
              {
                job_name = "topolvm-lvmd";
                scrape_interval = "30s";
                static_configs = [
                  { targets = [ "topolvm-lvmd-metrics.topolvm-system.svc.cluster.local:8080" ]; }
                ];
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
            # kubeletstats isn't listed in `receivers` below: the
            # kubeletMetrics preset appends it into this same list
            # automatically (see chart's _config.tpl), so listing it here
            # too would just be a redundant duplicate.
            metrics = {
              receivers = [ ];
              processors = [ "k8sattributes" "memory_limiter" "batch" ];
              exporters = [ "otlphttp/vm" ];
            };
            # Separate pipeline, not folded into `metrics` above: these are
            # node/device-class-level VG metrics scraped from lvmd's own
            # /metrics, not self-reported by a workload pod, so there's
            # nothing meaningful for k8sattributes to enrich them with (and
            # no need to depend on its IP-based pod association working for
            # a scraped-not-self-reported target).
            "metrics/topolvm" = {
              receivers = [ "prometheus" ];
              processors = [ "memory_limiter" "batch" ];
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

        # Exposed via the Tailscale Ingress provisioned through
        # `services.k3s.manifests` below instead -- the tailscale-operator's
        # expected shape (defaultBackend + tls.hosts for the MagicDNS name)
        # doesn't match what this chart's own `ingress:` block generates
        # (host-based `rules`), same reasoning as the datasource/dashboard
        # ConfigMaps down there being hand-written too.
        ingress.enabled = false;
      };
    };
  };

  # The Ingress + all Perses-provisioning ConfigMaps (datasources, Project,
  # Dashboard) live here rather than in the `perses` chart's own
  # `extraObjects` -- that field is rendered through `{{ tpl (toYaml .) $ }}`
  # (see the chart's templates/extra-manifests.yaml), meaning Helm
  # re-parses the *entire* manifest as a Go template a second time. Any
  # literal `{{ ... }}` inside our content -- e.g. Perses's own
  # `seriesNameFormat` legend templating, `{{k8s.pod.name}}` -- gets
  # misread as a Helm template action instead of surviving as plain text,
  # and breaks the whole Helm upgrade with `function "k8s" not defined`
  # (confirmed live: this silently failed every `helm-install-perses` job
  # from the moment the Dashboard ConfigMap below was first added, while
  # the previously-installed Helm revision kept running unaffected --
  # caught only because the failing Job's own pod logs were checked).
  # `services.k3s.manifests` has no such re-templating step (a plain
  # Nix-to-YAML/JSON dump via `manifestFormat.generate`), so this whole
  # class of bug can't recur here.
  services.k3s.manifests.perses-extra.content = [
    {
      apiVersion = "networking.k8s.io/v1";
      kind = "Ingress";
      metadata = {
        # Named "perses-static", not "perses" -- this object (and the 4
        # ConfigMaps below) used to be part of the `perses` Helm release's
        # own `extraObjects` before the extraObjects/tpl bug above. Helm's
        # upgrade-time cleanup deletes anything present in the *previous*
        # release revision's manifest but absent from the new one, purely
        # by GVK+namespace+name -- it doesn't know or care that a
        # same-named object is now managed elsewhere, so it deleted this
        # Ingress right out from under `services.k3s.manifests` the moment
        # the `perses` Helm release upgraded away from having it in
        # extraObjects (confirmed live: `kubectl get ingress -n monitoring`
        # came back empty even though the k3s Addon controller's own log
        # showed this manifest applying successfully moments earlier).
        # Renaming sidesteps this permanently -- Helm's release history
        # will never again contain anything named "perses-static", so
        # there's nothing left for it to "clean up".
        name = "perses-static";
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
        name = "perses-datasource-victoriametrics-static";
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
            spec = {
              # Sets the *default* minStep for every query against this
              # datasource that doesn't set its own -- Perses's query step
              # calc is `query.minStep ?? datasource.scrapeInterval ?? "1m"`
              # (perses/plugins prometheus-time-series-query/get-time-series-data.ts).
              # Without this, panels silently floor to the "1m"
              # DEFAULT_SCRAPE_INTERVAL regardless of actual data
              # resolution -- confirmed live, graphs looked like 1-minute
              # resolution even though the kubeletstats receiver actually
              # pushes samples every ~20s (verified via a raw
              # /api/v1/export against VictoriaMetrics). Per-panel minStep
              # still overrides this where a panel wants something finer
              # or coarser.
              scrapeInterval = "20s";
              proxy = {
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
        name = "perses-datasource-victorialogs-static";
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

    # The Project itself changes rarely, so it's still fine to provision
    # this one via ConfigMap+sidecar. Name "k3s" matches the one already
    # created by hand via the Perses UI before this was provisioned as
    # code, rather than introducing a second, redundant project.
    {
      apiVersion = "v1";
      kind = "ConfigMap";
      metadata = {
        name = "perses-project-k3s-static";
        namespace = "monitoring";
        labels."perses.dev/resource" = "true";
      };
      data."project.json" = builtins.toJSON {
        kind = "Project";
        metadata.name = "k3s";
        spec.display.name = "k3s";
      };
    }

    # Dashboards are deliberately NOT provisioned this way (a "logs"
    # dashboard used to be here, ConfigMap+sidecar-managed like the
    # Project above). Perses re-scans its provisioning folder every
    # `config.provisioning.interval` (10m default) and overwrites
    # whatever's live with the ConfigMap's content -- confirmed live: any
    # edit made directly in the Perses UI (a rename, in this case) got
    # silently reverted back within about ten minutes. Dashboards are
    # actively being edited via Perses's own REST API instead (see
    # project memory), so forcing them back to a stale ConfigMap on a
    # timer would fight with that. If dashboards need to be captured back
    # into git, do it by reading the live content via `GET
    # /api/v1/projects/<project>/dashboards/<name>` and committing that,
    # not by adding another provisioning ConfigMap here.
  ];
}
