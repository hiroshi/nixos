REGISTRY := ghcr.io/hiroshi/claude-code
TAG = $(shell git rev-parse --short=12 HEAD)
IMAGE = $(REGISTRY):$(TAG)

# Same TAG (git short SHA) as the main image above -- both always match the
# exact commit that produced them, no separate versioning scheme needed.
DOCKER_DF_EXPORTER_REGISTRY := ghcr.io/hiroshi/claude-code-docker-df-exporter
DOCKER_DF_EXPORTER_IMAGE = $(DOCKER_DF_EXPORTER_REGISTRY):$(TAG)

build:
	docker build --platform linux/amd64 -t $(IMAGE) ./

push:
	docker push $(IMAGE)

build-docker-df-exporter:
	docker build --platform linux/amd64 -t $(DOCKER_DF_EXPORTER_IMAGE) ./docker-df-exporter

push-docker-df-exporter:
	docker push $(DOCKER_DF_EXPORTER_IMAGE)

pvc:
	kubectl apply -f pvc.yaml

rbac:
	kubectl apply -f rbac.yaml

ARGS ?=
claude-code-run: pvc rbac
	kubectl run claude-code-run --rm -it --restart=Never \
		--image=$(IMAGE) \
		--overrides='{"spec":{"securityContext":{"fsGroup":1000},"serviceAccountName":"claude-code","containers":[{"name":"claude-code-run","image":"$(IMAGE)","command":["/usr/bin/claude"],"args":$(if $(ARGS),["$(ARGS)"],[]),"stdin":true,"tty":true,"volumeMounts":[{"name":"home","mountPath":"/home/claude"}]}],"volumes":[{"name":"home","persistentVolumeClaim":{"claimName":"claude-code-home"}}]}}' \
		-- /usr/bin/claude $(ARGS)

enable-remote-control: ARGS=remote-control
enable-remote-control: claude-code-run

deploy: pvc rbac
	IMAGE=$(IMAGE) DOCKER_DF_EXPORTER_IMAGE=$(DOCKER_DF_EXPORTER_IMAGE) \
		envsubst '$${IMAGE} $${DOCKER_DF_EXPORTER_IMAGE}' < deployment.yaml | kubectl apply -f -
