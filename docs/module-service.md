# module_service (Aufgabe 6)

A user can be assigned a module. The user_mgmt_service owns the endpoint; before it assigns
anything it asks the module_service ([`linosteiner/module_service`](https://github.com/linosteiner/module_service),
FastAPI + MySQL) whether the module exists. The module data lives only in the module_service's
managed MySQL — the user_mgmt_service never touches that database.

```text
client ──HTTPS──▶ Traefik ──▶ user_mgmt_service ──HTTP (K8s Service)──▶ module_service ──TLS──▶ DO Managed MySQL
                  /api/users/{id}/modules/{moduleId}      timeout · retry · circuit breaker     private VPC, CA-verified
```

| Endpoint (user_mgmt_service, behind `/api`) | Calls to the module_service |
|---|---|
| `PUT /users/{userId}/modules/{moduleId}` — assign (idempotent) | `GET /api/v1/modules/{id}` (available?), then `PUT /api/v1/users/{userId}/modules/{id}` |
| `GET /users/{userId}/modules` — list a user's modules | `GET /api/v1/users/{userId}/modules` |
| `GET /modules` — every module that can be assigned | `GET /api/v1/modules` |

The two `/users/{userId}/modules` endpoints are allowed for the user themself or anyone with
`USER_MODIFY`; `GET /modules` for every logged-in user. `GET /modules` is how a client learns
the module ids in the first place — the module_service itself has no Ingress. All three go
through the same client, so the same timeout, retry and circuit breaker apply.

## Acceptance criteria

| Criterion | Where | Evidence below |
|---|---|---|
| New endpoint assigns a module to a user | user_mgmt_service `domain/module/UserModuleController` | [E2E](#end-to-end-staging) |
| Availability checked via the module_service API first | `UserModuleService.assign` → `ModuleServiceClient.findModule` | [E2E](#end-to-end-staging) (404 for an unknown module) |
| Synchronous REST over the K8s Service, with timeout, retry, circuit breaker | `ModuleServiceConfig` / `ModuleServiceClient`, URL from `MODULE_SERVICE_BASE_URL` (chart: `user-mgmt.moduleService.internalUrl`) | [Failure case](#failure-case-module_service-down-staging) |
| No direct access from user_mgmt_service to the MySQL | credentials only in the `module-service-db` Secret, mounted only by the module_service; NetworkPolicies | [Isolation](#isolation-backend-cannot-reach-mysql) |
| E2E works, correct status codes for success and failure | — | [E2E](#end-to-end-staging), [Failure case](#failure-case-module_service-down-staging) |
| ServiceMonitor + new Grafana dashboard (rate, response time, error rate) | `templates/module-service/servicemonitor.yaml`, `monitoring/values.yaml` (dashboard #3) | [Monitoring](#monitoring) |
| CPU/memory limits sized for load (vertical scaling) | `moduleService.resources` in `charts/user-mgmt/values.yaml` | [Load test](#load-test-and-vertical-sizing) |
| Kyverno ClusterPolicies satisfied | the module_service Deployment | [Kyverno](#kyverno) |
| GitOps deployment, pipeline builds/versions/publishes the image | module_service `.github/workflows/build-and-promote.yml`, ArgoCD | [Pipeline](#pipeline-and-gitops) |

## Resilience settings (user_mgmt_service, `module-service.*` in `application.properties`)

| Mechanism | Setting | Why |
|---|---|---|
| Timeout | connect 1 s, read 2 s (`JdkClientHttpRequestFactory`) | a hanging module_service must not hold backend threads |
| Retry | 3 attempts, 200 ms backoff × 2; only connection errors and 5xx | 4xx (e.g. 404 unknown module) is an answer, not a failure — retrying it is pointless |
| Circuit breaker | window 10 calls, opens at 50% failures after ≥ 5 calls, open 15 s, 2 trial calls half-open | stop hammering a dead service; fail in milliseconds instead of seconds |
| Order | `Retry(CircuitBreaker(call))` | every attempt is recorded by the breaker; an open breaker ends the retries at once |

Error mapping to the client:

| Situation | Status |
|---|---|
| module assigned / listed | 200 |
| module does not exist (module_service 404) | 404 `Module '…' is not available` |
| malformed UUID in the path | 400 |
| another user without `USER_MODIFY`, or no token | 403 |
| unknown user | 404 |
| module_service unreachable, timing out, 5xx, or circuit open | **503** with `Retry-After: 15` |

The breaker, retries and the client calls are exported through Micrometer
(`resilience4j_circuitbreaker_state`, `resilience4j_retry_calls_total`,
`http_client_requests_seconds`) and shown in the dashboard's *Caller* row.

## End-to-end (staging)

2026-09-24, backend `522e274`, module_service `b7f403c`, against
`https://vcs-staging.linosteiner.ch/api` with a freshly registered user:

| Request | Status | Time |
|---|---|---|
| `PUT /users/{me}/modules/{CLOUD-ARCH}` | **200** `{"userId":…,"module":{"code":"CLOUD-ARCH",…}}` | 0.71 s (first call) |
| same again (idempotent) | **200** | 0.14 s |
| `GET /users/{me}/modules` | **200** `[{"code":"CLOUD-ARCH",…}]` | 0.12 s |
| `PUT /users/{me}/modules/00000000-…` (unknown module) | **404** `Module '00000000-…' is not available` | 0.12 s |
| `PUT /users/{me}/modules/not-a-uuid` | **400** `'not-a-uuid' is not a valid value` | 0.07 s |
| `PUT /users/00000000-…/modules/{CLOUD-ARCH}` (someone else) | **403** | 0.14 s |
| `PUT` without a token | **403** | 0.07 s |
| `GET /users/00000000-…` (unknown user) | **404** | 0.07 s |

2026-09-25, backend `3ab53f9` (adds `GET /modules`), same staging API:

| Request | Status |
|---|---|
| `GET /modules` | **200** `CLOUD-ARCH, DATABASES, SECURITY, WEB-DEV` |
| `GET /modules` without a token | **403** |
| `PUT /users/{me}/modules/{DATABASES}` | **200** |

Locally (both services in Docker, called through the frontend's route handlers), with the
module_service container stopped: the assignment answered 503 with `Retry-After: 15` three
times, the third already rejected by the open breaker in 26 ms; `GET /modules` answered 503 too.

## Failure case: module_service down (staging)

ArgoCD selfHeal paused, `kubectl -n staging scale deploy/…-module-service --replicas=0` at
21:22:49 UTC, then repeated `PUT /users/{me}/modules/{CLOUD-ARCH}`:

| Call | Status | Time | |
|---|---|---|---|
| 1 | 503, `Retry-After: 15` | 0.77 s | 3 attempts with 200 + 400 ms backoff |
| 2 | 503, `Retry-After: 15` | 0.71 s | 3 attempts; the breaker now has ≥ 5 recorded failures → **open** |
| 3–7 | 503, `Retry-After: 15` | 0.08–0.11 s | rejected by the open breaker, the module_service is not called at all |

Body: `{"errors":{"moduleService":"The module service is temporarily unavailable"}}`.

The alert `ModuleServiceUnavailable` (severity critical, no Ready pod for 2 minutes) went
pending at 21:23:25 and **fired at 21:25:25**; Alertmanager routed it to the
`ntfy-user-mgmt-alerts` receiver. SelfHeal re-enabled at 21:26 → ArgoCD restored the replica;
after the 15 s open window the breaker went half-open → closed and the same call answered
**200** again (0.14 s).

## Isolation: backend cannot reach MySQL

The MySQL credentials exist only in the `module-service-db` Secret, which only the
module_service pods mount. On the network, the NetworkPolicies pin each database to its own IP
(`networkPolicy.databaseEgress` / `moduleServiceDatabaseEgress`) — necessary because DigitalOcean
gives Postgres and MySQL the same port (25060), so the earlier VPC-wide rule let the backend
open TCP connections to MySQL (measured before the fix). After the fix, from inside the pods:

| From | To | Result |
|---|---|---|
| backend | MySQL `:25060` | **blocked** (timeout) |
| backend | Postgres `:25060` | connected |
| backend | module-service `:8080` | connected |
| module-service | MySQL `:25060` | connected |
| module-service | Postgres `:25060` | **blocked** (timeout) |

Ingress to the module_service is allowed from the backend (and from Prometheus, for `/metrics`)
only — neither the frontend nor the Ingress controller can reach it.

The module_service verifies the MySQL server certificate against the cluster's CA
(`charts/user-mgmt/files/module-service-mysql-ca.crt`) including the host name; the `migrate`
init container opening its first connection under that check is what passed on the first
rollout.

## Monitoring

- **ServiceMonitor** `…-module-service` scrapes `/metrics` (prometheus_client, route templates
  as labels, probes excluded). All three pods (staging 1, prod 2) are `up == 1`.
- **Dashboard** *module_service - Application Metrics* (uid `module-service`), namespace
  selector, three rows:
  - *Application*: **request rate** per endpoint, **response time** avg/p50/p95, **error rate**
    (5xx share with the 5% alert line, 4xx for context), requests per pod;
  - *Resources*: cpu and memory per pod against request/limit, throttling, restarts — what the
    vertical sizing is read off;
  - *Caller*: the backend's calls to the module_service, circuit breaker state, retries and
    rejected calls.
- **PrometheusRule**: `ModuleServiceHighErrorRate` (5xx share > 5% for 5 min, warning) and
  `ModuleServiceUnavailable` (0 Ready pods for 2 min, critical), both routed to ntfy.

## Load test and vertical sizing

`k6/scripts/module-service-load-test.js` as a Job (`k6/module-service-job.yaml`) against the
public staging Ingress — the real path, since the module_service has no Ingress of its own.
70% list, 30% assign (idempotent), ramp 5 → 20 → 40 VUs, 7 minutes. Run 2026-09-24
21:26:34 UTC, staging module_service at 1 replica with a 500m / 256Mi limit:

```text
  ✓ 'p(95)<1000' p(95)=911.07ms        ✓ 'rate<0.01' rate=0.00%
  checks_succeeded...: 100.00% 13013 out of 13013   (✓ assign: 200  ✓ list: 200)
  http_req_duration..: avg=350.33ms med=286.87ms p(90)=710.26ms p(95)=911.07ms
  http_reqs..........: 13015  30.7/s
```

From Prometheus (dashboard *module_service - Application Metrics*, namespace staging):

| module_service | Value |
|---|---|
| request rate, peak | 58.8 req/s (17 235 requests in the run) |
| 5xx | 0; circuit breaker never opened; 0 restarts |
| response time in the module_service, peak | avg 157 ms, p95 372 ms |
| cpu, peak | **498m = the 500m limit**, throttled in 57% of CFS periods |
| memory working set, peak | 66 Mi of 256 Mi |

**Sizing decision (vertical):** cpu is the binding resource — the pod was pinned at its limit
and the throttling is what drove its response time from a few ms to hundreds. The cpu limit
was raised to **1 core**, which is also the ceiling for one uvicorn process (GIL): beyond that
only more workers or replicas would help. Memory is ~4x below its limit and stays at 256 Mi.
Requests stay at the idle level (50m / 128Mi), the ResourceQuotas were raised to match
(arithmetic in `values-staging.yaml` / `values-prod.yaml`). Stable under load either way:
0 failed requests, no OOMKill, no restart.

## Kyverno

Policy reports for every module_service object, both namespaces: Deployment 5 pass / 0 fail,
ReplicaSet and each Pod 4 pass / 0 fail (`require-resource-limits`, `disallow-latest-tag`,
`require-probes`, `disallow-privileged-containers`). The containers — app and `migrate` — also
run as uid 10001 with a read-only root filesystem, no privilege escalation and all
capabilities dropped.

## Pipeline and GitOps

The module_service repo got the same pipeline as the other two apps
(`.github/workflows/build-and-promote.yml`): **test** (ruff + pytest) → **build-and-push**
(`bernetlennard/module_service:<commit-sha>` to Docker Hub) → **promote** (rewrites
`moduleService.image.tag` in this repo's `charts/user-mgmt/values.yaml`, anchored to the
`moduleService:` block, and fails if anything but that one line changed). ArgoCD then rolls
staging and prod.

First run, 2026-09-24:
[run 36060083289](https://github.com/linosteiner/module_service/actions/runs/36060083289) —
test ✓, build-and-push ✓, promote ✓ → commit `3ebacf5 Promote module-service to b7f403c` here.
The backend's change went the same way:
[run 36060478451](https://github.com/linosteiner/user_mgmt_service/actions/runs/36060478451) →
`97a6771 Promote backend to 522e274`.

Infrastructure outside the GitOps loop, by hand like the rest of `terraform/`: the MySQL
cluster (`terraform/mysql.tf`) and the `module-service-db` Secrets
([terraform/README.md](../terraform/README.md#mysql-for-the-module_service-aufgabe-6)).
