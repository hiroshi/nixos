#!/usr/bin/env bash
# Build an arbitrary Dockerfile and push it to a registry, using kaniko as a
# disposable k8s Job. Needs no nested container runtime and no extra pod
# privilege (no CAP_SYS_ADMIN, no privileged: true) -- kaniko executes RUN
# steps and snapshots filesystem diffs entirely in userspace.
set -euo pipefail

NAMESPACE=default
REGISTRY_SECRET=ghcr-credentials
KANIKO_IMAGE=ghcr.io/kaniko-build/dist/chainguard-forks-kaniko/executor:v1.25.15

DOCKERFILE=Dockerfile
CONTEXT=
DESTINATION=

usage() {
  echo "Usage: $0 --context <context> --destination <image:tag> [--dockerfile <path>]" >&2
  echo "Example: $0 --context git://github.com/hiroshi/myapp.git#refs/heads/main --destination ghcr.io/hiroshi/myapp:abc123" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) CONTEXT=$2; shift 2 ;;
    --destination) DESTINATION=$2; shift 2 ;;
    --dockerfile) DOCKERFILE=$2; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$CONTEXT" && -n "$DESTINATION" ]] || usage

# `gh auth token` needs the write:packages scope to push to ghcr.io:
#   gh auth refresh -h github.com -s write:packages
kubectl create secret docker-registry "$REGISTRY_SECRET" \
  --namespace="$NAMESPACE" \
  --docker-server=ghcr.io \
  --docker-username="$(gh api user --jq .login)" \
  --docker-password="$(gh auth token)" \
  --dry-run=client -o yaml | kubectl apply -f -

JOB_NAME="kaniko-build-$(date +%s)"

kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB_NAME
  namespace: $NAMESPACE
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: kaniko
          image: $KANIKO_IMAGE
          args:
            - --context=$CONTEXT
            - --dockerfile=$DOCKERFILE
            - --destination=$DESTINATION
          volumeMounts:
            - name: docker-config
              mountPath: /kaniko/.docker
      volumes:
        - name: docker-config
          secret:
            secretName: $REGISTRY_SECRET
            items:
              - key: .dockerconfigjson
                path: config.json
EOF

kubectl wait --for=condition=complete --timeout=600s "job/$JOB_NAME" -n "$NAMESPACE" || true
kubectl logs "job/$JOB_NAME" -n "$NAMESPACE"
