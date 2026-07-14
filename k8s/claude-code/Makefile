IMAGE := ghcr.io/hiroshi/claude-code:latest
build:
	docker build --platform linux/amd64 -t $(IMAGE) ./

push:
	docker push $(IMAGE)
