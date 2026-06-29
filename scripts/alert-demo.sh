#!/usr/bin/env bash
## Fire the ServiceDown alert and HOLD it firing so you can screenshot
## Alertmanager (rubric item 10), then restore the app on a keypress.
##
## Usage: bash scripts/alert-demo.sh
## Unlike trigger-alert.sh (which auto-restores after 90s), this waits for YOU.

set -euo pipefail

AM=http://localhost:9093/api/v2/alerts

echo "Step 1: stop day23-app to trigger ServiceDown (up{job=inference-api}==0 for 1m)"
docker stop day23-app >/dev/null

echo "Step 2: waiting for ServiceDown to fire (~90-150s)..."
fired=0
for i in $(seq 1 36); do
  sleep 5
  if curl -fsS "$AM" 2>/dev/null | grep -q '"alertname":"ServiceDown"' \
     && curl -fsS "$AM" 2>/dev/null | grep -q '"state":"active"'; then
    fired=1
    break
  fi
  echo "  ...not firing yet (${i}x5s)"
done

if [ "$fired" -eq 1 ]; then
  echo ""
  echo "  ============================================================"
  echo "  ServiceDown is FIRING. Screenshot now:"
  echo "    - http://localhost:9093         -> submission/screenshots/alertmanager-firing.png"
  echo "    - http://localhost:9090/alerts  (Prometheus view, optional)"
  echo "  ============================================================"
  read -rp "  Press Enter when you've captured the screenshot to restore the app... "
else
  echo "  WARNING: alert did not fire within the window; restoring anyway." >&2
fi

echo "Step 3: restart day23-app"
docker start day23-app >/dev/null
echo "Done. The alert will resolve within ~60-90s (watch :9093)."
