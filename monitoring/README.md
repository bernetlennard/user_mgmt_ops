# Monitoring stack (kube-prometheus-stack)

Declarative configuration for the `prometheus-stack` Helm release (`kube-prometheus-stack`,
namespace `monitoring`). This is a separate Helm release from `charts/user-mgmt` and is **not**
managed by ArgoCD -- apply changes here with `helm upgrade`, by hand.

## Fresh cluster: CRDs first

`kube-prometheus-stack` ships its CRDs (`ServiceMonitor`, `PrometheusRule`, ...) in its own
`crds` subchart. On a brand-new cluster the Kubernetes API server needs a few seconds to
register them after `helm install` applies them -- if the very first install fails with
`no matches for kind "ServiceMonitor" in version "monitoring.coreos.com/v1"`, that's this race,
not a real error. Either re-run the same command a few seconds later, or apply the CRDs
explicitly first:

```bash
helm pull prometheus-community/kube-prometheus-stack --untar --untardir /tmp/pcs-chart
kubectl apply -f /tmp/pcs-chart/kube-prometheus-stack/charts/crds/crds/
kubectl wait --for=condition=established --timeout=60s \
  crd -l app.kubernetes.io/part-of=kube-prometheus-stack 2>/dev/null || sleep 10
```

## Install / upgrade

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update prometheus-community

helm upgrade --install prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --version 91.2.3 \
  -f values.yaml
```

## Verify

```bash
kubectl -n monitoring get pods
kubectl -n monitoring get servicemonitors,prometheusrules -A
kubectl -n monitoring port-forward svc/prometheus-stack-kube-prom-prometheus 9090:9090
# open http://localhost:9090/targets -- the user-mgmt backend ServiceMonitor target should be UP
```

## Dashboards

Provisioned from `values.yaml` (folder *General*, tag `user-mgmt`; each has a *user_mgmt
Dashboards* menu top right to switch between them):

| Dashboard | For | Shows |
|---|---|---|
| **user_mgmt - Ruhiger Betrieb** (`user-mgmt-live`) | everyday operation | real users only: logins, failed logins, registrations, module assignments and 5xx of the last 10 minutes; one bar per minute; response time; pods; module_service circuit breaker. Refreshes every 10 s |
| **user_mgmt - Lasttest** (`user-mgmt-backend`) | load tests (Aufgabe 2) | all traffic including k6, split into load test vs. real users; throughput, latency, errors, HPA, cpu, memory |
| **module_service - Application Metrics** (`module-service`) | Aufgabe 6 | the module_service and the backend's calls to it |

Load test vs. real user comes from the backend: k6 is recognised by its User-Agent (or any
client sending `X-Load-Test`), and every request carries `source="loadtest"` or `source="user"`
on `http_server_requests` and on the counter `user_mgmt_activity_total{event, source}`. That
counter exists at 0 from startup, so even the first login on a quiet system shows up (a series
that only appears with its first request is invisible to `increase()`). All three dashboards
shade the time a k6 Job was running in orange.

```bash
kubectl -n monitoring port-forward svc/prometheus-stack-grafana 3000:80
# http://localhost:3000/d/user-mgmt-live
```

## Alertmanager notification channel

Wired to [ntfy.sh](https://ntfy.sh) (decided 2026-09-14; no Slack workspace was available).
Subscribe to the topic in the ntfy app or at
`https://ntfy.sh/user-mgmt-backend-alerts-0810489237b6` to receive alerts.

Verified end-to-end by posting a synthetic alert straight to Alertmanager's API (bypassing
Prometheus, so it didn't need 5 real minutes of errors) and confirming it reached the topic:

```bash
kubectl -n monitoring port-forward svc/prometheus-stack-kube-prom-alertmanager 9093:9093 &
curl -X POST http://localhost:9093/api/v2/alerts -H "Content-Type: application/json" -d '[{
  "labels": {"alertname": "UserMgmtBackendHighErrorRate", "service": "user-mgmt-backend", "severity": "warning"},
  "annotations": {"summary": "test"},
  "startsAt": "'"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"'"
}]'
# then: curl "https://ntfy.sh/<topic>/json?poll=1&since=10m" to confirm delivery
```

**Known limitation, accepted (2026-09-14):** ntfy.sh's free tier has no auth -- topics are
public, and this one was found and spammed by strangers within minutes of creation (one
message was offensive). Real alerts still get delivered correctly alongside the noise; a
private channel (e.g. a Discord webhook, which is unguessable rather than merely unlisted)
would avoid this if it becomes a problem. Rotating to a new random topic name only delays the
same outcome.

The topic name isn't a credential the way a Slack webhook URL is -- worst case is spam, not a
compromise -- so it's plain text in `values.yaml` here rather than a mounted Secret, same
reasoning as the backend's JWT secret (see the README, [Secrets](../README.md#secrets)). Rotate it any
time by picking a new random name; nothing else depends on the old one.

## Proof: a real alert, end to end (2026-09-25)

The synthetic alert above only proves Alertmanager → ntfy. This test drove the whole chain with a
real outage in staging: the module_service at 0 replicas, real requests failing, Prometheus
evaluating the rules, Alertmanager routing, ntfy delivering, and the all-clear afterwards.

Procedure, in Git Bash (`alert-test.sh` and `alert-test-pause-argocd.yaml` are in this directory):

```bash
# 1. ArgoCD's selfHeal would put the replica straight back: pause automated sync for staging
kubectl -n argocd patch application user-mgmt-staging --type merge \
  --patch-file monitoring/alert-test-pause-argocd.yaml
# 2. Traffic: one module assignment per second as the k6 test user, logged to ~/alert-test.log
bash monitoring/alert-test.sh
# 3. The outage, in a second terminal
kubectl -n staging scale deploy/user-mgmt-staging-user-mgmt-module-service --replicas=0
# 4. Watch Prometheus /alerts, Alertmanager and the ntfy topic, then restore automated sync;
#    selfHeal brings the replica back
kubectl apply -f argocd/application-staging.yaml
```

The patch is a file rather than an inline `-p '{...}'` because Windows PowerShell strips the
quotes of inline JSON before kubectl sees them.

Timeline in UTC, from `~/alert-test.log`, the Prometheus series `ALERTS` and the ntfy topic:

| Time | Event |
|---|---|
| 18:26:29 | test loop starts: `PUT /api/users/{me}/modules/{CLOUD-ARCH}` answers 200 in ~0.10 s |
| 18:28:06 | first 503, after 1.73 s: three attempts with 200 + 400 ms backoff |
| 18:28:10 | circuit breaker open: 503 in ~75 ms, the module_service is no longer called |
| 18:28:25 | `ModuleServiceUnavailable` pending: 0 available replicas, `for: 2m` starts |
| 18:28:51 | `UserMgmtBackendHighErrorRate` pending: 5xx share over `rate[5m]` above 5 %, `for: 5m` starts |
| 18:30:25 | `ModuleServiceUnavailable` **firing**, ntfy message at **18:30:56** (`group_wait` 30 s) |
| 18:33:51 | `UserMgmtBackendHighErrorRate` **firing**, ntfy message at **18:34:21** |
| 18:40:03 | first 200 again, after the restore |
| 18:40:56 | ntfy: `ModuleServiceUnavailable` **resolved**, at the group's next `group_interval` tick |
| 18:44:45 | the 5-minute 5xx share drops below 5 % |
| 18:49:21 | ntfy: `UserMgmtBackendHighErrorRate` **resolved** |

950 requests: 377 × 200 (0.10 s on average) and 573 × 503. The open breaker rejected 495 of the
503s in 78 ms on average. The other 78 (about 0.69 s each, two every ~15 s) were the half-open
trial calls going through their retries; `Retry-After: 15` matches that 15 s open window.

What the numbers show:

- **One outage, two alerts 3.5 minutes apart.** `ModuleServiceUnavailable` watches the replica
  count with `for: 2m`. The error-rate rule needs a 5 % share of 5xx and then `for: 5m`.
- **Notifications trail the alert state.** `group_wait` adds 30 s to the first message, and a
  resolved alert is only sent at the group's next `group_interval` tick, up to 5 minutes later.
- **The error-rate alert lags the recovery.** `rate[5m]` keeps counting the old 503s, so the rule
  resolved at 18:44:45 although requests succeeded again from 18:40:03.

## Why the ServiceMonitor/PrometheusRule in `charts/user-mgmt` carry `release: prometheus-stack`

This release's `Prometheus` custom resource only picks up `ServiceMonitor`/`PrometheusRule`
objects labeled `release: prometheus-stack` (the default kube-prometheus-stack behaviour when
`serviceMonitorSelectorNilUsesHelmValues`/`ruleSelectorNilUsesHelmValues` are `true`, which
`values.yaml` here sets explicitly). That label has nothing to do with which Kubernetes
namespace the object lives in -- `serviceMonitorNamespaceSelector`/`ruleNamespaceSelector` are
both empty, meaning "every namespace" -- so the backend's ServiceMonitor and PrometheusRule
work unmodified in `staging`, `prod`, or anywhere else, as long as they carry that one label.
