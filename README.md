# user_mgmt_ops

Deployment configuration for the **user management stack** — a Spring Boot backend
([`linosteiner/user_mgmt_service`](https://github.com/linosteiner/user_mgmt_service)) and a Next.js
frontend ([`linosteiner/auth_portal`](https://github.com/linosteiner/auth_portal)), backed by a
DigitalOcean Managed PostgreSQL — running on DigitalOcean Kubernetes (`k8s-user-mgmt`, fra1).

This is the **Ops repository**: it holds *how the application is deployed*, separately from the
application source. ArgoCD watches this repo and reconciles the cluster against it, and the app
repos' pipelines promote a new image by committing its tag here rather than by pushing to the
cluster.

It replaces the static manifests in `user_mgmt_service/k8s/`, which remain in the app repo only as
documentation of the earlier, pre-Helm setup.

## Layout

| Path | What | Delivered by |
|---|---|---|
| `charts/user-mgmt/` | the application chart: backend, frontend, ingress, HPA, PDB, NetworkPolicy, ResourceQuota, ServiceMonitor, PrometheusRule | ArgoCD (`argocd/application-{prod,staging}.yaml`) |
| `argocd/` | the ArgoCD `Application` objects | `kubectl apply`, once |
| `monitoring/` | kube-prometheus-stack: Prometheus, Alertmanager (→ ntfy), Grafana + dashboards | `helm upgrade` by hand — [monitoring/README.md](monitoring/README.md) |
| `k6/` | load test as a one-off Job, for the HPA | `kubectl apply` on demand — [k6/README.md](k6/README.md) |
| `policy/` | Kyverno: Helm values + ClusterPolicies | Kyverno by hand, policies via ArgoCD (`argocd/application-policies.yaml`) — [policy/README.md](policy/README.md) |
| `terraform/` | the DOKS cluster (imported) and the managed PostgreSQL | `terraform apply` by hand — [terraform/README.md](terraform/README.md) |

Only the application chart and the policies are continuously reconciled. The rest is platform
infrastructure (cluster-scoped CRDs, webhooks, a billed load balancer or database) that is
installed once and changed deliberately, so it is applied by hand from the config committed here.

The ingress controller (Traefik) is deliberately **not** in the chart. Its `IngressClass` and
`ClusterRole` are cluster-scoped and its `Service type: LoadBalancer` provisions a real, billed
DigitalOcean load balancer; installing the app chart twice would try to create those twice. One
Traefik routes by hostname into Ingress objects in every namespace. It still runs from
`user_mgmt_service/k8s/traefik/`.

## Environments

| | `staging` | `prod` |
|---|---|---|
| Hosts | vcs-staging.linosteiner.ch, vcs-staging.lennardbernet.ch | vcs.linosteiner.ch, vcs.lennardbernet.ch |
| Backend | HPA 1–2 replicas | HPA 2–3 replicas |
| Frontend | 1 replica | 2 replicas |
| Database | `user_mgmt_staging` | `user_mgmt_prod` |

Both share one node (`s-4vcpu-8gb`), so the replica ceilings and ResourceQuotas are sized
together — the arithmetic is in the comments of `values-prod.yaml` and `values-staging.yaml`.

## Install

ArgoCD does this; by hand it is:

```bash
helm install um-prod ./charts/user-mgmt -n prod --create-namespace \
  -f charts/user-mgmt/values.yaml -f charts/user-mgmt/values-prod.yaml
kubectl -n prod rollout status deploy/um-prod-user-mgmt-backend
```

The backend needs the `user-mgmt-db` Secret in its namespace first — see
[terraform/README.md](terraform/README.md). Every object is named `<release>-<chart>-<component>`,
so the chart is namespace-agnostic and installs cleanly more than once in the same cluster.

Verify before pushing:

```bash
helm lint ./charts/user-mgmt --strict -f charts/user-mgmt/values-prod.yaml

# server-side dry run: also runs the Kyverno policies
helm template um ./charts/user-mgmt -f charts/user-mgmt/values.yaml \
  -f charts/user-mgmt/values-staging.yaml | kubectl apply --dry-run=server -n staging -f -
```

## Configuration

Everything is in `charts/user-mgmt/values.yaml`, with per-environment overlays. The keys worth
knowing:

| Key | Note |
|---|---|
| `backend.image.tag` / `frontend.image.tag` | the lines the app pipelines rewrite on promotion — an immutable commit SHA |
| `externalDatabase.*` | host/port from `terraform output`; credentials only via the `user-mgmt-db` Secret |
| `backend.autoscaling` | HPA on cpu, enabled in both overlays |
| `backend.podDisruptionBudget` | enabled in both overlays |
| `ingress.hosts` | list; `/api` → backend and `/` → frontend are structural and stay in the template |
| `monitoring.*` | ServiceMonitor + PrometheusRule wiring to the kube-prometheus-stack release |
| `networkPolicy` / `resourceQuota` | namespace guardrails, enabled in both overlays |

## Secrets

The managed database credentials never enter git: the chart only references the `user-mgmt-db`
Secret, which is created out of band from the Terraform outputs.

`backend.jwtSecret` is still a plain value in `values.yaml`, rendered into `Secret.stringData`.
**This repository is private, and that is the only thing protecting it.** The real answer is
[Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) or External Secrets — a whole
additional component to install and operate, so it is out of scope here. The key is a freshly
generated one, not reused from the app repo's local `.env`.

Rotating it:

```bash
openssl rand -base64 64 | tr -d '\n'
```

It must be at least 256 bits — jjwt rejects a shorter HS256 key with `WeakKeyException`. The
`checksum/config` annotation on the Deployments means a config change rolls the pods
automatically.

## Template helpers

`templates/_helpers.tpl` — the naming/label helpers take a `dict` so one definition serves every
component:

```gotemplate
{{- include "user-mgmt.labels" (dict "ctx" $ "component" "backend") | nindent 4 }}
```

| Helper | Purpose |
|---|---|
| `user-mgmt.name` / `.fullname` | standard naming, release-prefixed |
| `user-mgmt.componentName` | `<release>-user-mgmt-backend`, `-frontend` |
| `user-mgmt.selectorLabels` | the three keys that go into `spec.selector` — **immutable after install** |
| `user-mgmt.labels` | the above plus chart/version/managed-by metadata |
| `user-mgmt.image` | `repository:tag` from any image dict |
| `user-mgmt.backend.internalUrl` | in-cluster backend URL for the frontend's server-side calls |
| `user-mgmt.podDisruptionBudget` | one PDB definition for every component; fails on min+max both set |
| `user-mgmt.database.jdbcUrl` | JDBC URL for the managed database; fails the render if host/database are empty |
