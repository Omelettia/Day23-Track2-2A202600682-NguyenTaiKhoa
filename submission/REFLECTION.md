# Day 23 Lab Reflection

> Fill in each section. Grader reads the "What I'd change" paragraph closest.

**Student:** Nguyen Tai Khoa (ID 2A202600682)
**Submission date:** 2026-06-29
**Lab repo URL:** https://github.com/Omelettia/Day23-Track2-2A202600682-NguyenTaiKhoa

---

## 1. Hardware + setup output

Output of `python3 00-setup/verify-docker.py` (`00-setup/setup-report.json`):

```json
{
  "docker": { "ok": true, "version": "29.3.1" },
  "compose_v2": { "ok": true, "version": "5.1.1" },
  "ram_gb_available": 11.68,
  "ram_ok": true,
  "required_ports": [8000, 9090, 9093, 3000, 3100, 16686, 4317, 4318, 8888],
  "bound_ports": [],
  "all_ports_free": true
}
```

```
Docker:        OK  (29.3.1)
Compose v2:    OK  (5.1.1)
RAM available: 11.68 GB (OK)
Ports free:    OK
```

Host: Windows + WSL2 (Docker Desktop), Docker Engine 29.3.1, Compose v5.1.1, ~11.7 GB
allocated to the VM. All 7 services (`app`, `prometheus`, `alertmanager`, `grafana`,
`loki`, `jaeger`, `otel-collector`) come up clean and `make smoke` exits 0.

---

## 2. Track 02 — Dashboards & Alerts

### 6 essential panels (screenshot)

`submission/screenshots/dashboard-overview.png` — **AI Service Overview (Day 23)**.
After a 90s locust run (`-u 10`, ~18 req/s, 1654 requests, 0 failures) the panels read:
request rate ≈ 5.6/s (5m rate), **P99 latency ≈ 0.25 s**, token throughput ≈ 205 tok/s,
quality score ≈ 0.75, in-flight gauge rising to ~10 during load and back to 0 after.

### Burn-rate panel

`submission/screenshots/slo-burn-rate.png` — **SLO Burn Rate (Day 23)**. SLO = 99.5 %
success over 30 days → 0.5 % error budget. The dashboard renders the 4 recording-rule
windows (`inference:fail_ratio:rate5m/30m/1h/6h`). Under healthy load the fail-ratio is
0, so burn rate is 0×; the multi-window/multi-burn-rate alerts (`SLOFastBurn` 14.4×,
`SLOSlowBurn` 6×) stay green until errors appear.

### Alert fire + resolve

| When | What | Evidence |
|---|---|---|
| _T0_ | killed `day23-app` (`docker stop`) | `submission/screenshots/alertmanager-firing.png` |
| _T0+~120s_ | `ServiceDown` fired (`up{job="inference-api"}==0` for 1m) | `alertmanager-firing.png` |
| _T1_ | restored app (`docker start`) | — |
| _T1+~70s_ | alert resolved | (Alertmanager cleared; verified via `/api/v2/alerts`) |

Verified end-to-end via the Alertmanager API: after the stop, a single **`ServiceDown`**
alert (`severity=critical`, `service=inference-api`, summary "inference-api is down")
went `state=active`; after restart it returned to 0 active alerts. Use
`bash scripts/alert-demo.sh` to reproduce — it holds the firing state so you can capture
the screenshot, then restores on a keypress.

> Slack delivery (item 11) was not wired in this run — no Slack workspace was used.
> The webhook is decoupled into a mounted file (`alertmanager/slack_url`), so adding a
> real `hooks.slack.com/...` URL there + `docker compose restart alertmanager` lights it
> up without editing the committed config.

### One thing surprised me about Prometheus / Grafana

The biggest gotcha: a provisioned Grafana datasource **without an explicit `uid`** gets a
random one (e.g. `PBFA97CFB590B2093`), but every dashboard JSON hard-codes
`"datasource": {"uid": "prometheus"}`. Grafana does **not** fall back to the default
datasource for an explicit-but-missing uid — it returns `404 Data source not found`, so
*every panel on every dashboard* rendered "No Data" with a red error triangle, even though
Prometheus was scraping perfectly and the raw PromQL returned data. The telemetry pipeline
was fine; the **dashboard-to-datasource binding** was broken. Pinning `uid: prometheus` in
the datasource provisioning fixed all four dashboards at once. Lesson: in
dashboards-as-code, the datasource `uid` is a contract — pin it on both sides.

Two smaller surprises: (1) Grafana's `/api/health` payload changed shape between versions
(11.3 pretty-prints `"database": "ok"` with a space), silently breaking the `make smoke`
grep — health checks are themselves code that rots. (2) Alertmanager treats `api_url`
literally: it does **not** expand `{{ env ... }}`, so the templated webhook parsed to an
empty URL scheme and crashed the container on boot — secrets belong in `*_file` directives,
not inline config.

---

## 3. Track 03 — Tracing & Logs

### One trace screenshot from Jaeger

`submission/screenshots/jaeger-trace.png` — a `POST /predict` trace (service
`inference-api`) showing the tree:

```
POST /predict                (server span, root)
 └─ predict                  gen_ai.request.model = llama3-mock
     ├─ embed-text
     ├─ vector-search
     └─ generate-tokens      gen_ai.usage.input_tokens / output_tokens, gen_ai.response.finish_reason = stop
```

> Bug I had to fix to make this work: the handler created the parent with
> `tracer.start_span("predict")`, which **never activates the span in context**, so the
> three child spans attached to nothing and each became its own single-span trace.
> Switching to `start_as_current_span` (and adding `instrument_app(app)` for the server
> span) collapsed 4 disconnected traces into one coherent trajectory. See §6.

### Log line correlated to trace

Structured JSON log emitted by the app (`structlog` → stdout), carrying the same
`trace_id` you can paste into Jaeger's "Lookup by Trace ID":

```json
{"model": "llama3-mock", "input_tokens": 4, "output_tokens": 54, "quality": 0.667,
 "duration_seconds": 0.2439, "trace_id": "a86fb1f29b16f714bc9fb88e627ee3f6",
 "event": "prediction served", "level": "info", "timestamp": "2026-06-29T04:27:02.649250Z"}
```

The Grafana Loki datasource has a derived field (`matcherRegex: "trace_id":"([a-fA-F0-9]+)"`)
that turns that `trace_id` into a click-through to the Jaeger trace — logs↔traces
correlation without copy-paste.

### Tail-sampling math

Collector policy (`otel-config.yaml`), composite, OR-combined:
1. `keep-errors` — keep **100 %** of traces with any `status_code = ERROR`
2. `keep-slow` — keep **100 %** of traces with latency > 2000 ms
3. `probabilistic-1pct` — keep **1 %** of everything else (healthy + fast)

Worked example from my run. The load generator sent ~3,045 healthy requests plus 5
deliberately-failed ones (`{"fail": true}` → HTTP 503, span status ERROR). The mock
adds a >2 s slow tail to ≈0.13 % of requests.

```
kept ≈ errors(100%) + slow(>2s, ≈0.13%) + 1% × healthy
For 1000 healthy traces/sec:
  kept ≈ (error_count) + ~1.3 + ~10  ≈ ~11 healthy + every error
  → ~99% reduction in trace storage, while NEVER dropping an error or a latency outlier.
```

I confirmed it empirically: a single healthy `/predict` trace I generated by hand was
**dropped** (404 in Jaeger — exactly the 99 % case), while all **5 forced-error traces
were retained**. That is the whole point of tail (vs head) sampling: the decision is made
*after* the trace completes, so you can keep the 1 % that's interesting (errors, slow)
instead of a blind random 1 %.

---

## 4. Track 04 — Drift Detection

### PSI scores

`04-drift-detection/reports/drift-summary.json`:

```json
{
  "prompt_length":    { "psi": 3.461,  "kl": 1.7982,  "ks_stat": 0.702, "ks_pvalue": 0.0,      "drift": "yes" },
  "embedding_norm":   { "psi": 0.0187, "kl": 0.0324,  "ks_stat": 0.052, "ks_pvalue": 0.133853, "drift": "no"  },
  "response_length":  { "psi": 0.0162, "kl": 0.0178,  "ks_stat": 0.056, "ks_pvalue": 0.086899, "drift": "no"  },
  "response_quality": { "psi": 8.8486, "kl": 13.5011, "ks_stat": 0.941, "ks_pvalue": 0.0,      "drift": "yes" }
}
```

`prompt_length` (reference mean 50 → shifted 85) and `response_quality`
(Beta(8,2) high-quality → Beta(2,6) low-quality) both blow past the PSI > 0.2 threshold;
`embedding_norm` and `response_length` were left unchanged and correctly read "no".
Evidently HTML report: `submission/screenshots/evidently-report.png`.

### Which test fits which feature?

| Feature | Type | Test I'd use in prod | Why |
|---|---|---|---|
| `prompt_length` | 1-D continuous, unimodal | **PSI** (alerting) + **KS** (backstop) | PSI bins → a single thresholdable number that's easy to alert on (0.1 warn / 0.2 critical); KS gives a hypothesis test on the full CDF (here ks=0.70, p=0). |
| `embedding_norm` | scalar summary of a vector | **KS / PSI** for the scalar; **MMD** for the *real* embedding | A 1-D norm hides multivariate drift. The honest test for the full embedding vector is **MMD** (kernel two-sample) — it doesn't need binning, which dies in high dimensions. |
| `response_length` | 1-D continuous count | **KS** | Sensitive to shifts anywhere in the distribution, no binning artifacts; PSI fine too. |
| `response_quality` | bounded [0,1], shape flip | **KL divergence** + **PSI** | The mass moves high→low quality. KL(P‖Q) directly measures that distributional *shape* divergence (here 13.5, huge); PSI on bins also flags it (8.85). This is the one that actually hurts users. |

Rule of thumb: **PSI** for binned, alertable 1-D monitoring; **KS** as the statistical
test for continuous 1-D; **KL** when you care how *different* two distributions are;
**MMD** for multivariate / embedding drift where you can't bin.

---

## 5. Track 05 — Cross-Day Integration

`submission/screenshots/cross-day-dashboard.png` — **Cross-Day Stack (Day 23
integrative)**, 6 panels (Days 16/17/18/19/20/22). I connected two prior-day sources via
their stub exporters: **Day 19 Qdrant** (`day19_qdrant_collections = 3`, on host :9101)
and **Day 20 llama.cpp** (`day20_llamacpp_tokens_per_second ≈ 23`, on host :9102),
scraped by Prometheus over `host.docker.internal`. The other four panels fail soft to
"No Data (… not running)".

### Which prior-day metric was hardest to expose? Why?

**Day 20 (llama.cpp serving) would be the hardest in reality.** llama.cpp's HTTP server
doesn't natively expose a Prometheus `/metrics` endpoint — tokens/sec, queue depth and
KV-cache occupancy live inside the inference loop, so you have to bolt on a sidecar that
parses the server's output or patches counters in. Contrast Day 19 Qdrant, which ships a
first-class `/metrics` endpoint you just scrape. The general lesson: **the systems that
most need GPU/serving telemetry are the ones least likely to emit it**, so a chunk of
LLMOps work is writing the exporter that the upstream project never shipped (deck §8,
GPU & LLM-serving telemetry).

---

## 6. The single change that mattered most

> **Grader reads this closest.**

The one change that flipped this stack from "works" to "useful" was fixing **span context
propagation** in the `/predict` handler: replacing `tracer.start_span("predict")` with
`tracer.start_as_current_span("predict")` (and instrumenting the app instance with
`FastAPIInstrumentor.instrument_app(app)` so a real `POST /predict` server span exists).

Before the fix, every metric and log was *technically* correct and every span was *being
exported* — Jaeger even listed the `inference-api` service. It looked like working
observability. But `start_span` creates a span without ever putting it in the active
context, so the three inner spans (`embed-text → vector-search → generate-tokens`) had no
parent to attach to. Each one started a **brand-new root trace**. The result: one user
request produced **four disconnected single-span traces**, and there was no way to look at
a `/predict` call and see where its time actually went. That is telemetry that exists but
cannot answer the question you bought it to answer — "for *this* request, which step was
slow?" After the change, the same request renders as one tree —
`POST /predict → predict → {embed, search, generate}` — and the latency, the GenAI token
attributes, and the error status all hang off the right node.

This is exactly the deck §7 point about tracing: a trace is only worth storing if **context
propagates**, because the entire value of a span is its *position in the parent/child
tree*, not the span in isolation. The same fix also made the §7 tail-sampling work
correctly — I set `ERROR` status on the parent span on failure, so the `keep-errors`
policy retains the *whole* failed trajectory (all 5 of my forced-error traces survived,
while a lone healthy trace was correctly dropped at 1 %). One line — `start_as_current_span`
— was the difference between "we have traces" and "we can debug a request." It's a good
reminder that with observability, the failure mode isn't usually *missing* data; it's
**data that's present but not connected**.

---

## Bonus B3 — AgentOps (deck §13/§14/§19)

`submission/agentops-report.json` + `submission/screenshots/agentops-jaeger.png`
(service `day23-agent`, `invoke_agent → execute_tool` span trees).

**Extension implemented (option c): a new failure mode + test.** I added a
**`hallucinated-tool`** detector — when the agent calls a tool name absent from the
registry (task 4 calls a non-existent `refund` tool), the harness flags
`hallucinated-tool`, counts `hallucinated_tool_calls`, and marks the span `ERROR`. Tests
in `BONUS-agentops/test_agentops.py` (6/6 pass standalone or under pytest) cover loop
detection, the tool-error path, and the new hallucinated-tool path. I also set span
`ERROR` status on every failure trajectory so the Collector's tail-sampler **keeps the
failed agent traces** — without it, all 4 agent traces would be 1 %-sampled and the Jaeger
screenshot would be empty. Result: 3 failure trajectories (loop, tool-error,
hallucinated-tool) are reliably visible in Jaeger.

Agent SLIs from the run (`agent_slis`): `success_rate = 0.5`, `avg_steps_per_task = 3.0`,
`tool_error_rate = 0.167`, `cost_per_task_usd = 4.1e-5`, `loops_detected = 1`,
`hallucinated_tool_calls = 1`.

### Why `pass^k` ≠ `pass@k`, and which SLI I'd alert on first

`pass@k` = probability that **at least one** of *k* attempts succeeds — the optimistic
eval metric (great for "can the model ever get it right?"). `pass^k` = probability that
**all** *k* runs succeed = (per-run success)^k under independence — the metric an operator
actually lives with, because in production the agent runs the task *repeatedly* and you
need it right **every time**, not once. The gap is brutal and compounding: a 90 %-per-run
agent has `pass@5 ≈ 1 - 0.1^5 ≈ 0.99999` but `pass^5 = 0.9^5 ≈ 0.59` — it fails ~40 % of
the time over five runs. My harness's per-task `success_rate = 0.5` looks survivable until
you raise it to the power of a real workload's repetition count, where it collapses. This
is the deck §19 argument for durable execution, idempotency, and retries: they raise the
*effective* `pass^k` by making individual steps recoverable.

**Which SLI I'd alert on first: `tool_error_rate`** (with `cost_per_task_usd` as the
runaway guard). `success_rate` is the *outcome* — by the time it craters, users are
already hurt. `tool_error_rate` and `loops_detected` are **leading indicators**: rising
tool errors and loop/no-progress are the upstream causes that compound into low `pass^k`,
and a runaway loop burns `cost_per_task` *before* it ever reports failure (the §13 point —
a single HTTP 200 can hide a 12-step, $5 trajectory). So I'd page on tool-error rate and
cost-per-task slope, and treat success_rate as the SLO I'm protecting, not the alarm.
