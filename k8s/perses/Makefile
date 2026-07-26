.SHELLFLAGS := -eu -o pipefail -c
DASHBOARDS_DEFAULT_URL := https://perses.tail3aefc0.ts.net/api/v1/projects/k3s/dashboards/default

dashboards/default.json:
	curl -vf $(DASHBOARDS_DEFAULT_URL) | jq > $@

dashboards-put: dashboards/default.json
	curl -vf -T- -H "Content-Type: application/json" $(DASHBOARDS_DEFAULT_URL) < $<
