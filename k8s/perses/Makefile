# https://perses.dev/perses/docs/api/dashboard/
DASHBOARDS_DEFAULT_URL := https://perses.tail3aefc0.ts.net/api/v1/projects/k3s/dashboards/default

.PHONY: dashboards/default.json
dashboards/default.json:
	curl -vf $(DASHBOARDS_DEFAULT_URL) | jq > $@

.PHONY: dashboards-put
dashboards-put:
	curl -vf -T- -H "Content-Type: application/json" $(DASHBOARDS_DEFAULT_URL) < dashboards/default.json
