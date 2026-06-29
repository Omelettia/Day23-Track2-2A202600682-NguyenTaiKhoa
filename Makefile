## Day 23 Track 2 — Observability Lab orchestration
##
## Quick start:
##   make setup    # one-time: pull images, create .env
##   make up       # start the 7-service stack
##   make smoke    # verify all services healthy
##   make demo     # run end-to-end demo (load + alert + trace + drift)
##   make verify   # rubric gate — exit 0 if all checkpoints pass
##   make down     # stop the stack
##   make clean    # stop + remove volumes (destructive)

SHELL := /bin/bash
COMPOSE ?= docker compose

## Prefer the local host-tools venv (created by `make setup` / `python3 -m venv .venv`)
## when present, so load/drift/verify/agentops work without polluting system python.
## Falls back to system python3/locust when there's no venv (unchanged behaviour).
## Absolute paths so targets that `cd` into a subdir (load, drift) still resolve them.
PY     := $(shell [ -x .venv/bin/python ] && echo $(CURDIR)/.venv/bin/python || echo python3)
LOCUST := $(shell [ -x .venv/bin/locust ] && echo $(CURDIR)/.venv/bin/locust || echo locust)

.PHONY: help setup up wait down restart logs smoke load alert trace drift demo verify clean lint-dashboards

help:
	@grep -E '^##|^[a-zA-Z_-]+:.*?## ' Makefile | sed -E 's/^## ?//; s/:.*## /\t/' | column -t -s $$'\t'

setup: ## one-time install + .env scaffold
	@test -f .env || cp .env.example .env
	@python3 -m pip install -q -r requirements.txt || echo '  (pip: use a venv; see README Python 3.12/3.13 note)'
	@bash 00-setup/pull-images.sh
	@$(PY) 00-setup/verify-docker.py

up: ## start the stack and wait until every service is ready
	$(COMPOSE) up -d
	@$(MAKE) --no-print-directory wait

wait: ## block until all 7 services are ready (Grafana provisioning + Loki ingester take ~45-60s)
	@echo "Waiting for services to become ready (Loki ingester is the slowest, ~45-60s)..."
	@for i in $$(seq 1 36); do \
	  if curl -fsS http://localhost:8000/healthz   >/dev/null 2>&1 \
	  && curl -fsS http://localhost:9090/-/healthy >/dev/null 2>&1 \
	  && curl -fsS http://localhost:9093/-/healthy >/dev/null 2>&1 \
	  && curl -fsS http://localhost:3000/api/health >/dev/null 2>&1 \
	  && curl -fsS http://localhost:3100/ready     >/dev/null 2>&1 \
	  && curl -fsS http://localhost:16686/         >/dev/null 2>&1 \
	  && curl -fsS http://localhost:8888/metrics   >/dev/null 2>&1; then \
	    echo "  all 7 services ready (after $$((i*5))s)"; exit 0; \
	  fi; \
	  sleep 5; \
	done; \
	echo "  WARNING: not all services ready after 180s — run 'make smoke' to see which"; exit 0

down: ## stop the stack (preserves volumes)
	$(COMPOSE) down

restart: down up ## stop + start

logs: ## tail logs from all services
	$(COMPOSE) logs -f --tail=50

smoke: ## health-check all 7 services
	@echo "Checking services..."
	@curl -fsS http://localhost:8000/healthz   > /dev/null && echo "  app:           OK"
	@curl -fsS http://localhost:9090/-/healthy > /dev/null && echo "  prometheus:    OK"
	@curl -fsS http://localhost:9093/-/healthy > /dev/null && echo "  alertmanager:  OK"
	@curl -fsS http://localhost:3000/api/health | grep -qE '"database":[[:space:]]*"ok"' && echo "  grafana:       OK"
	@curl -fsS http://localhost:3100/ready     > /dev/null && echo "  loki:          OK"
	@curl -fsS http://localhost:16686/         > /dev/null && echo "  jaeger:        OK"
	@curl -fsS http://localhost:8888/metrics   > /dev/null && echo "  otel-collector: OK"
	@echo "Stack healthy."

load: ## run baseline locust load (concurrency=10, 60s)
	cd 02-prometheus-grafana/load-test && \
	  $(LOCUST) -f locustfile.py --headless -u 10 -r 2 -t 60s --host http://localhost:8000

alert: ## trigger an alert by killing the app, wait, then restore
	bash scripts/trigger-alert.sh

trace: ## generate one traced request and print its trace_id
	@curl -sS -X POST http://localhost:8000/predict \
	  -H 'Content-Type: application/json' \
	  -d '{"prompt":"hello"}' | $(PY) -c 'import json,sys; d=json.load(sys.stdin); print("trace_id:",d.get("trace_id","?"))'

drift: ## run drift detection notebook (cli mode)
	cd 04-drift-detection && $(PY) scripts/drift_detect.py

agentops: ## (bonus B3) instrument a mock agent: OTel spans + agent SLIs (deck §14/§19)
	$(PY) BONUS-agentops/agent_run.py --out submission/agentops-report.json

demo: ## end-to-end demo (load -> alert -> trace -> drift)
	$(MAKE) load
	$(MAKE) alert
	$(MAKE) trace
	$(MAKE) drift

verify: ## rubric gate — exits 0 only if all checkpoints pass
	$(PY) scripts/verify.py

lint-dashboards: ## validate Grafana dashboard JSONs
	$(PY) scripts/lint-dashboards.py 02-prometheus-grafana/grafana/dashboards/*.json

clean: ## stop stack + remove volumes (DESTRUCTIVE)
	$(COMPOSE) down -v
