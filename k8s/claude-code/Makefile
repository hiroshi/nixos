REGISTRY := ghcr.io/hiroshi/claude-code
TAG = $(shell git rev-parse --short=12 HEAD)
IMAGE = $(REGISTRY):$(TAG)

build:
	docker build --platform linux/amd64 -t $(IMAGE) ./

push:
	docker push $(IMAGE)

pvc:
	kubectl apply -f pvc.yaml

ARGS ?=
claude-code-run: pvc
	kubectl run claude-code-run --rm -it --restart=Never \
		--image=$(IMAGE) \
		--overrides='{"spec":{"securityContext":{"fsGroup":1000},"containers":[{"name":"claude-code-run","image":"$(IMAGE)","command":["/usr/bin/claude"],"args":$(if $(ARGS),["$(ARGS)"],[]),"stdin":true,"tty":true,"volumeMounts":[{"name":"home","mountPath":"/home/claude"}]}],"volumes":[{"name":"home","persistentVolumeClaim":{"claimName":"claude-code-home"}}]}}' \
		-- /usr/bin/claude $(ARGS)

enable-remote-control: ARGS=remote-control
enable-remote-control: claude-code-run

deploy: pvc
	IMAGE=$(IMAGE) envsubst '$${IMAGE}' < deployment.yaml | kubectl apply -f -
