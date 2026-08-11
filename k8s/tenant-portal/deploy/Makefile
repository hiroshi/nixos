REGISTRY := ghcr.io/hiroshi/tenant-portal
TAG = $(shell git rev-parse --short=12 HEAD)
IMAGE = $(REGISTRY):$(TAG)

# The image tenant pods run. Not tied to this app's TAG: it's whatever
# claude-code build the cluster is on (see k8s/claude-code/Makefile).
CLAUDE_CODE_IMAGE ?= ghcr.io/hiroshi/claude-code:87714ee97089

build:
	docker build --platform linux/amd64 -t $(IMAGE) ..

push:
	docker push $(IMAGE)

pvc:
	kubectl apply -f pvc.yaml

rbac:
	kubectl apply -f rbac.yaml

networkpolicy-protection:
	kubectl apply -f networkpolicy-protection.yaml

# Created once and then left alone: rotating SECRET_KEY_BASE logs everyone out
# and rotating PORTAL_PASSWORD changes the shared password on every deploy.
# Pass PORTAL_PASSWORD=... to choose it, or let it be generated and read it back
# with `make password`.
secret:
	kubectl get secret tenant-portal-secrets >/dev/null 2>&1 || \
		kubectl create secret generic tenant-portal-secrets \
			--from-literal=SECRET_KEY_BASE=$$(python3 -c 'import secrets; print(secrets.token_hex(64))') \
			--from-literal=PORTAL_PASSWORD=$${PORTAL_PASSWORD:-$$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')}

password:
	@kubectl get secret tenant-portal-secrets -o jsonpath='{.data.PORTAL_PASSWORD}' | base64 -d; echo

deploy: pvc rbac networkpolicy-protection secret
	IMAGE=$(IMAGE) CLAUDE_CODE_IMAGE=$(CLAUDE_CODE_IMAGE) \
		envsubst '$${IMAGE} $${CLAUDE_CODE_IMAGE}' < deployment.yaml | kubectl apply -f -
	kubectl apply -f service.yaml

cloudflared-deploy:
	kubectl apply -f cloudflared-deployment.yaml

logs-url:
	kubectl logs -n default deploy/cloudflared-tenant-portal | grep trycloudflare.com
