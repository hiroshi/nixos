IMAGE := ghcr.io/hiroshi/claude-code:latest

build:
	docker build --platform linux/amd64 -t $(IMAGE) ./

push:
	docker push $(IMAGE)

# 初回セットアップの手順: make pvc -> make login -> make enable-remote-control -> make deploy

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

# login と同様に使い捨てpodで一度だけ対話実行し、初回の
# `Enable Remote Control? (y/n)` に y と答える。答えたらそのまま Ctrl-C で
# 抜けてよい(同意状態はPVC上の設定に保存され、以降 `deploy` の
# headless実行では聞かれなくなる。無応答だとexit 0でpodがCompletedになり
# CrashLoopBackOffする)。
enable-remote-control:
	kubectl run claude-code-enable-remote-control --rm -it --restart=Never \
		--image=$(IMAGE) \
		--overrides='{"spec":{"securityContext":{"fsGroup":1000},"containers":[{"name":"claude-code-enable-remote-control","image":"$(IMAGE)","command":["/usr/bin/claude"],"args":["remote-control"],"stdin":true,"tty":true,"volumeMounts":[{"name":"home","mountPath":"/home/claude"}]}],"volumes":[{"name":"home","persistentVolumeClaim":{"claimName":"claude-code-home"}}]}}' \
		-- /usr/bin/claude remote-control

# login・enable-remote-control 済みであることを前提に、常駐Deploymentを立てる。
deploy:
	kubectl apply -f deployment.yaml

# ペアリングURL/接続状態の確認用
logs:
	kubectl logs -f deploy/claude-code

delete:
	kubectl delete -f deployment.yaml -f pvc.yaml
