# tenant-portal

A Rails app that turns "namespaces as multi-tenancy" into a web form: submit a
tenant name and you get a namespace containing a claude-code pod that the tenant
signs into with **their own** Claude account, then drives from claude.ai/code or
the Claude app via Remote Control.

## What a tenant gets

`tenant-<name>` namespace, containing:

| Resource | Purpose |
| --- | --- |
| `ServiceAccount claude-code` + `RoleBinding` → built-in `edit` | kubectl inside that namespace and nowhere else |
| `PersistentVolumeClaim claude-code-home` | `/home/claude`, so the login survives pod restarts |
| `ConfigMap tenant-agent` | `agent/supervisor.py`, shipped without an image rebuild |
| `Deployment claude-code` | the supervisor, driving `claude` through a pty |
| `Service claude-code:8080` | the supervisor's JSON API, which this portal polls |

The namespace is labelled `pod-security.kubernetes.io/enforce: restricted`, so a
tenant can't use its `edit` rights to run a privileged pod and escape the
namespace (unlike `default`, see hiroshi/nixos#8).

## The bootstrap flow

`claude auth login` and `claude remote-control` are interactive-only, so
`agent/supervisor.py` drives them through a pty and exposes the parts a human has
to see over HTTP:

```
portal  ──GET  /status──▶  supervisor   phase: logging_in, auth_url: https://claude.com/cai/oauth/...
 user   ──opens auth_url in their browser, copies the code──▶
portal  ──POST /code────▶  supervisor   writes code + "\r" into the pty
                           supervisor   seeds ~/.claude.json, starts remote-control
portal  ──GET  /status──▶  supervisor   phase: running, session_url: https://claude.ai/code?environment=...
```

`claude setup-token` / `CLAUDE_CODE_OAUTH_TOKEN` deliberately cannot be used
here: those are inference-only scopes and `remote-control` rejects them. It needs
a full `claude auth login`, which is why there's a pty driver at all.

## Talking to Kubernetes

`KubernetesClient` calls the API directly over Net::HTTP -- no kubectl binary in
the image, no kubeconfig. Writes are Server-Side Apply (`PATCH` with the
apply-patch content type), which makes provisioning idempotent in one request
per object without branching on whether it already exists.

The API server address is the DNS name `https://kubernetes.default.svc`, not
`KUBERNETES_SERVICE_HOST`: Thruster does not pass that variable through to the
Rails process, so anything derived from it works under `rails runner` and fails
under a web request.

## Deploying

```sh
cd deploy
make build push deploy          # generates tenant-portal-secrets on first run
make cloudflared-deploy         # only needed once
make logs-url                   # the trycloudflare.com URL
make password                   # the generated basic auth password (user: admin)
```

`CLAUDE_CODE_IMAGE` in `deploy/Makefile` pins the image tenant pods run; bump it
when `k8s/claude-code` is rebuilt.

## Tests

No Ruby on the claude-code pod, so run them in the built image:

```sh
docker run --rm -e RAILS_ENV=test -e SECRET_KEY_BASE=dummy <image> bundle exec rspec
```

## Network isolation

Each tenant namespace carries a `NetworkPolicy` (`namespace-isolation`)
restricting ingress on 8080 to the portal pod only, and egress to DNS, the
Kubernetes API server, and the outside world -- never another tenant's
pod/Service, and never the private address space (RFC1918, Tailscale's CGNAT
range, and link-local) that this node's LAN and tailnet live in.

The API server has no backing pod in k3s, so it can't be reached by a
podSelector. `TenantProvisioner` looks up its real address at provision time
from the core `Endpoints` object named `kubernetes` in the `default`
namespace (the same thing `kubectl get endpoints kubernetes` shows) and
renders it into a narrow ipBlock rule -- nothing about the node's real address
is hardcoded or committed. If that address ever changes, re-running
`provision!` (idempotent via Server-Side Apply) against an existing tenant
picks up the new one.

The broader egress exclusion is `10.0.0.0/8`, `172.16.0.0/12`,
`192.168.0.0/16`, `100.64.0.0/10`, and `169.254.0.0/16` -- standard private,
CGNAT, and link-local address space, not a description of this network's
actual layout, so it's safe to commit without leaking topology. It's
deliberately broader than this cluster's own pod/Service CIDRs (both fall
inside `10.0.0.0/8`) or its one LAN segment (inside `192.168.0.0/16`). See the
comment above the `NetworkPolicy` in `lib/templates/tenant.yaml.erb` for the
full rationale.

Existing tenants provisioned before this was added don't have it until their
namespace is re-provisioned (Server-Side Apply makes re-running `provision!`
against an existing namespace safe and idempotent -- it only adds what's
missing).

## Known gaps

- No ResourceQuota/LimitRange per tenant yet: tenants are only bounded by the
  Deployment's own requests/limits and a 1Gi PVC.
- Basic auth is interim. The intended public deployment is on an external VM with
  real authentication, at which point the portal talks to the cluster with a
  token from somewhere other than a mounted ServiceAccount (`KubernetesClient`
  reads its address and credentials from a few constants with environment
  overrides, so that's a configuration change, not a code change).
- Tenants can't run `docker build`: no dockerd sidecar and no Kata runtime class,
  unlike the `default` namespace's claude-code pod.
- The `namespace-isolation` NetworkPolicy's `podSelector: {}` covers every pod
  in the tenant's namespace, but its ingress/egress rules don't include a
  same-namespace allow -- pods the tenant creates alongside claude-code (their
  `edit` role permits this) can't reach each other. Only matters once a tenant
  runs more than the one claude-code pod.
- The tenant's `edit` RoleBinding includes full CRUD on
  `networkpolicies.networking.k8s.io` (it's one of the resources aggregated
  into the built-in `edit` ClusterRole), so a tenant can edit or delete
  `namespace-isolation` themselves and remove their own network isolation.
  `edit` was chosen so the rule list stays in sync with upstream (see the
  RoleBinding's comment); reconciling that with "don't let tenants touch this
  one policy" needs either a narrower custom role (breaking that sync) or an
  admission policy blocking SA `claude-code` from writing NetworkPolicy.
