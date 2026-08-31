# user_mgmt_ops

Deployment configuration for the **user management stack** — a Spring Boot backend
([`linosteiner/user_mgmt_service`](https://github.com/linosteiner/user_mgmt_service)), a Next.js
frontend (`auth_portal`) and a PostgreSQL database — running on DigitalOcean Kubernetes
(`do-fra1-k8s-user-mgmt`).

This is the **Ops repository**: it holds *how the application is deployed*, separately from the
application source. That separation is what Aufgabe 3 (ArgoCD) needs — ArgoCD watches this repo and
reconciles the cluster against it, and Aufgabe 4's pipeline promotes a new image by committing a
tag here rather than by pushing to the cluster.

It replaces the static manifests in `user_mgmt_service/k8s/`, which remain in the app repo as
documentation of Aufgabe 1.

## Layout

```
charts/
└── user-mgmt/          the application chart -- installed once per environment
    ├── Chart.yaml
    ├── values.yaml     the single source of configuration
    └── templates/
        ├── _helpers.tpl
        ├── NOTES.txt
        ├── ingress.yaml
        ├── postgres/   configmap, secret, pvc, deployment, service
        ├── backend/    configmap, secret, deployment, service, hpa, pdb
        └── frontend/   configmap, deployment, service
docs/
└── helm-phase1.md      the hands-on Helm walkthrough this chart was built from
```

The ingress controller (Traefik) is deliberately **not** in this chart. It is cluster
infrastructure: its `IngressClass` and `ClusterRole` are cluster-scoped, and its
`Service type: LoadBalancer` provisions a real, billed DigitalOcean load balancer. Installing the
app chart twice would try to create those a second time. One Traefik routes by hostname into
Ingress objects in every namespace — its ClusterRole already watches cluster-wide. It currently
still runs from `user_mgmt_service/k8s/traefik/`; moving it into a separate `charts/platform` is
planned but is the only step that can cost the public IP and the TLS certificate, so it is done
last.

## Install

```bash
helm install um-prod ./charts/user-mgmt -n prod --create-namespace
kubectl -n prod rollout status deploy/um-prod-user-mgmt-backend
```

Every object is named `<release>-<chart>-<component>`, so the chart is namespace-agnostic and
installs cleanly more than once in the same cluster:

```bash
helm install um-staging ./charts/user-mgmt -n staging --create-namespace \
  --set ingress.enabled=false
```

Verify before installing anything:

```bash
helm lint ./charts/user-mgmt --strict
helm template um ./charts/user-mgmt | kubectl apply --dry-run=server -f -

# no hardcoding: two releases must not collide on any name
diff <(helm template a ./charts/user-mgmt) <(helm template b ./charts/user-mgmt)
```

## Configuration

Everything is in `charts/user-mgmt/values.yaml`. The keys worth knowing:

| Key | Note |
|---|---|
| `backend.image.tag` | the single line Aufgabe 4's pipeline rewrites on promotion |
| `ingress.hosts` | list; the `/api` → backend and `/` → frontend paths are structural and stay in the template |
| `ingress.enabled` | set `false` to install a second release without it fighting for the hostnames |
| `backend.autoscaling` | HPA, shipped disabled — Aufgabe 6 |
| `backend.podDisruptionBudget` | PDB, shipped disabled — Aufgabe 6 |
| `postgres.strategy` | `Recreate`. The PVC is ReadWriteOnce; two Postgres pods can never hold the volume at once |

A few things are intentionally *not* values, because they are structural rather than
configuration: the `/` and `/api` ingress paths, `PGDATA`, and the Postgres data mount path.

## Secrets — a known simplification

`postgres.auth.password` and `backend.jwtSecret` are plain values in `values.yaml`, rendered into
`Secret.stringData`. **This repository is private, and that is the only thing protecting them.**

The real answer is [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) or External
Secrets: commit an encrypted `SealedSecret` that only the in-cluster controller can decrypt, so the
repo can be public and a leak of the git history is not a leak of the credentials. That is a whole
additional component to install and operate, so it is out of scope here — the same tradeoff, and
the same reasoning, as the note in `user_mgmt_service/k8s/README.md`.

What *was* fixed: the JWT signing key committed in the app repo at
`k8s/user-mgmt/user-mgmt-secret.yaml` is shared with the local `.env` and is public if that repo
is. The key in this chart is a freshly generated one and is not reused anywhere.

Rotating it:

```bash
openssl rand -base64 64 | tr -d '\n'
```

It must be at least 256 bits — jjwt rejects a shorter HS256 key with `WeakKeyException`. The
`checksum/config` annotation on the Deployments means a config change rolls the pods automatically.

## Template helpers

`templates/_helpers.tpl` — the three naming/label helpers take a `dict` so one definition serves
all three components:

```gotemplate
{{- include "user-mgmt.labels" (dict "ctx" $ "component" "backend") | nindent 4 }}
```

| Helper | Purpose |
|---|---|
| `user-mgmt.name` / `.fullname` | standard naming, release-prefixed |
| `user-mgmt.componentName` | `<release>-user-mgmt-postgres`, `-backend`, `-frontend` |
| `user-mgmt.selectorLabels` | the three keys that go into `spec.selector` — **immutable after install** |
| `user-mgmt.labels` | the above plus chart/version/managed-by metadata |
| `user-mgmt.image` | `repository:tag` from any image dict |
| `user-mgmt.postgres.jdbcUrl` | builds the JDBC URL from the release-prefixed Service name |

That last one is the point of the exercise. The original manifest hardcoded
`jdbc:postgresql://postgres:5432/…`, which only worked because the Service happened to be named
exactly `postgres`. Once names are release-prefixed, that breaks — and the helper is what fixes it.
