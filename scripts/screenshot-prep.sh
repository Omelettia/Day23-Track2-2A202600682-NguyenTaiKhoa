#!/usr/bin/env bash
## Generate a stable ~5-minute load window (plus a few errors) so every Grafana
## panel populates while you capture screenshots. Run this in one terminal, then
## screenshot these (set the time picker to "Last 15 minutes"):
##
##   http://localhost:3000/d/day23-ai-overview   overview — 6 panels + in-flight gauge (item 4,7)
##   http://localhost:3000/d/day23-slo           SLO burn rate (item 8)
##   http://localhost:3000/d/day23-cost-tokens   cost & tokens, non-zero $/hr (item 9)
##   http://localhost:3000/d/day23-cross-day     cross-day stack, Day19/20 data (item 19,20)
##
## Tip: capture the overview WHILE this runs so "In-Flight Requests" reads > 0.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCUST="$ROOT/.venv/bin/locust"; [ -x "$LOCUST" ] || LOCUST=locust

echo "Injecting 3 forced errors (so the Error Rate panel shows a value)..."
for _ in 1 2 3; do
  curl -sS -X POST http://localhost:8000/predict \
    -H 'Content-Type: application/json' \
    -d '{"prompt":"err","fail":true}' -o /dev/null || true
done

echo "Running 5 min of load — screenshot the dashboards now. Ctrl-C to stop early."
cd "$ROOT/02-prometheus-grafana/load-test"
exec "$LOCUST" -f locustfile.py --headless -u 12 -r 4 -t 300s --host http://localhost:8000
