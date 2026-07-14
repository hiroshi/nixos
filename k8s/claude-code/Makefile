IMAGE := ghcr.io/hiroshi/claude-code:latest

build:
	docker build --platform linux/amd64 -t $(IMAGE) ./

push:
	docker push $(IMAGE)

# 初回セットアップの手順: make pvc -> make login -> make deploy

pvc:
	kubectl apply -f pvc.yaml

# 使い捨てpodで /home/claude を deployment と同じPVCにマウントし、
# `claude` を対話起動して /login する（docker compose run 相当）。
# 終了すると --rm によりpodだけ消え、認証情報はPVCに残る。
login:
	kubectl run claude-code-login --rm -it --restart=Never \
		--image=$(IMAGE) \
		--overrides='{"spec":{"securityContext":{"fsGroup":1000},"containers":[{"name":"claude-code-login","image":"$(IMAGE)","command":["/usr/bin/claude"],"stdin":true,"tty":true,"volumeMounts":[{"name":"home","mountPath":"/home/claude"}]}],"volumes":[{"name":"home","persistentVolumeClaim":{"claimName":"claude-code-home"}}]}}' \
		-- /usr/bin/claude

# login 済みであることを前提に、常駐Deploymentを立てる。
deploy:
	kubectl apply -f deployment.yaml

# ペアリングURL/接続状態の確認用
logs:
	kubectl logs -f deploy/claude-code

delete:
	kubectl delete -f deployment.yaml -f pvc.yaml
