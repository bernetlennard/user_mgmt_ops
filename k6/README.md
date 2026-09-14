# k6 Chaos/Load Testing

Runs `k6` as a one-off Kubernetes Job (namespace `k6`, no NetworkPolicy) against the public
staging Ingress, to verify the backend's HPA under Aufgabe 2's acceptance criteria. Not
deployed through ArgoCD -- see `job.yaml`'s own comment for why.

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

Watch during the run (separate terminals):

```bash
# HPA reacting to load
kubectl -n staging get hpa user-mgmt-staging-user-mgmt-backend-hpa -w

# replicas coming and going
kubectl -n staging get pods -l app.kubernetes.io/component=backend -w

# Grafana: import Prometheus -> "user_mgmt_service - Application Metrics" (request rate,
# response time, error rate) and "Kubernetes / Compute Resources / Pod" (CPU per pod) side by
# side -- see monitoring/values.yaml for how they're provisioned
```

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
