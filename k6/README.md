# k6 Chaos/Load Testing

Runs `k6` as a one-off Kubernetes Job (namespace `k6`, no NetworkPolicy) against the public
staging Ingress, to verify the backend's HPA under Aufgabe 2's acceptance criteria. Not
deployed through ArgoCD -- see `job.yaml`'s own comment for why.

The module_service load test of Aufgabe 6 (`module-service-job.yaml`,
`scripts/module-service-load-test.js`, same test user) and its results are in
[docs/module-service.md](../docs/module-service.md#load-test-and-vertical-sizing). Run it like
this one, with `k6-module-service-load-test` as the ConfigMap name.

## One-time setup: the test user

`scripts/login-load-test.js` logs in as a dedicated, pre-registered user so the script itself
never needs to create or clean up data:

```bash
curl -s -X POST https://vcs-staging.linosteiner.ch/api/users/register \
  -H "Content-Type: application/json" \
  -d '{"firstName":"K6","lastName":"LoadTest","email":"k6-loadtest@user-mgmt.local","password":"K6LoadTest123!"}'
```

Already done for the current staging database (2026-09-14) -- only needed again after a DB
reset.

## Run

```bash
kubectl apply -f job.yaml
kubectl create configmap k6-login-load-test \
  --from-file=login-load-test.js=scripts/login-load-test.js \
  -n k6 --dry-run=client -o yaml | kubectl apply -f -
kubectl -n k6 wait --for=condition=complete job/login-load-test --timeout=15m
kubectl -n k6 logs job/login-load-test
```

**Start from 1 replica.** Check `kubectl -n staging get hpa` first: right after a backend
rollout the HPA is often still at 2, because the JVM's startup cpu spike scaled it out and the
5-minute scale-down window has not passed yet. A test started then shows no scale-out at all.

Watch during the run (separate terminals):

```bash
# HPA reacting to load
kubectl -n staging get hpa user-mgmt-staging-user-mgmt-backend-hpa -w

# replicas coming and going
kubectl -n staging get pods -l app.kubernetes.io/component=backend -w
```

In Grafana, open **user_mgmt_service - Application Metrics** with namespace `staging`: the
first row shows request rate, response time (avg/p95), error rate and requests per pod; the
*Scaling* row shows the HPA's replicas against the available pods and cpu as % of the request
with the 70% target line.

The scale-down happens about 5 minutes *after* the load ends (the HPA's scale-down
stabilization window), i.e. after the Job has already completed -- keep watching.

## Results: run of 2026-09-24

Target `staging` (HPA 1–2 replicas, cpu target 70% of a 100m request, cpu limit 750m, memory
limit 700Mi), backend image `01a86a1`. Job started 19:43:44 UTC with the HPA at 1 replica.

### k6 summary

```text
  █ THRESHOLDS
    http_req_failed
    ✓ 'rate<0.05' rate=0.00%

    checks_succeeded...: 100.00% 3682 out of 3682
    ✓ status is 200
    ✓ issued a bearer token

    http_req_duration..............: avg=1.29s min=52.76ms med=216.44ms max=9.33s  p(90)=4.29s p(95)=5.25s
    http_req_failed................: 0.00%  0 out of 1841
    http_reqs......................: 1841   5.108027/s
    vus............................: 1      min=1         max=20

running (6m00.4s), 00/20 VUs, 1841 complete and 0 interrupted iterations
```

### Scaling timeline (`kubectl get hpa` / pods, sampled every 15 s)

| UTC | HPA cpu | current → desired | ready pods | what happened |
|---|---|---|---|---|
| 19:43:42 | 5% | 1 → 1 | 1 | baseline before the test |
| 19:44:13 | 117% | 1 → **2** | 1 | 29 s into the 5-VU baseline: scale-out, second pod created |
| 19:45:14 | 648% | 2 → 2 | **2** | second pod passed its readinessProbe (61 s JVM start) and joins the Service |
| 19:46–19:49 | 480–590% | 2 → 2 | 2 | 20-VU peak; HPA at maxReplicas |
| 19:49:50 | | | 2 | load ends (Job complete) |
| 19:55:24 | 5% | 2 → **1** | 1 | scale-down, 5.5 min after the load ended = the 300 s stabilization window |

HPA events: `New size: 2; reason: cpu resource utilization (percentage of request) above
target`, then `New size: 1; reason: All metrics below target`.

### From Prometheus (dashboard "user_mgmt_service - Application Metrics", namespace staging)

| Metric | Value |
|---|---|
| request rate, peak | 7.2 req/s |
| requests per pod, peak | 3.71 / 3.69 req/s — evenly split once both pods were ready |
| request share over the whole run | 55.1% / 44.9% — the first pod served alone until 19:45:14 |
| p95 response time, peak | 6.7 s (average peak 2.1 s) |
| 5xx share | 0% throughout |
| available pods, minimum | 1 — never 0 |
| cpu per pod, peak | 750% of the request = the 750m limit; throttled in 100% of CFS periods at peak |
| memory working set per pod, peak | 644 Mi of the 700 Mi limit; no restarts, no OOMKill |

### Reading

- **The HPA works in both directions** — out within ~30 s of the load crossing the target,
  back in after exactly the configured 5-minute window.
- **Availability held**: 0 failed requests and at least one Ready pod at every sample. The new
  replica only received traffic after its readinessProbe passed, and the Service spread the
  requests evenly over both replicas (round robin, `sessionAffinity: None`).
- **The load is CPU-bound by design.** Passwords are hashed with Argon2 (Spring's
  `defaultsForSpringSecurity_v5_8`: 16 MiB, 2 iterations per hash), deliberately expensive
  to slow down brute force. Even the 5-VU baseline is above 70% of the 100m request, so the
  scale-out happens in the first stage, not at the peak.
- **Capacity ceiling = 2 × 750m.** At maxReplicas both pods ran at their cpu limit and were
  throttled; latency rose (p95 5–7 s) instead of requests failing. More headroom would need a
  higher `maxReplicas` (the resized node has room) or a higher cpu limit.
- **Memory is the tighter margin**: 644 Mi of 700 Mi under 20 concurrent Argon2 hashes. The
  heap itself is capped by `-XX:MaxRAMPercentage=60`, so the risk is GC pressure rather than an
  OOMKill, but a heavier test should raise the memory limit first.

## Re-run

```bash
kubectl -n k6 delete job login-load-test
kubectl apply -f job.yaml
```

## Clean up

The namespace only exists for the duration of testing:

```bash
kubectl delete namespace k6
```
