# Policy as Code (Kyverno)

Kyverno runs as an admission webhook in the `policy` namespace and checks every workload
before the API server stores it. Anything that breaks a policy is **rejected at
`kubectl apply` / ArgoCD sync time**, not discovered later in a crash-looping pod.

```
policy/
├── values.yaml        Kyverno Helm release config (installed by hand, like monitoring/)
├── policies/          the ClusterPolicies -- synced by ArgoCD (argocd/application-policies.yaml)
└── tests/
    ├── invalid-deployment.yaml   breaks all four policies -- must be rejected
    └── valid-deployment.yaml     the same container, compliant -- must be accepted
```

Two separate delivery paths on purpose: Kyverno itself (CRDs, webhooks, controllers) is
platform infrastructure installed once with Helm, exactly like the monitoring stack. The
policies are the part that changes, so they go through GitOps -- a policy is added, changed
or removed by a commit, and ArgoCD's `selfHeal` reverts anyone editing one by hand in the
cluster.

## The policies

All four run with `failureAction: Enforce`.

| ClusterPolicy | Rule | Why here |
|---|---|---|
| `require-resource-limits` | every container has cpu/memory requests **and** limits | one node shared by everything; no BestEffort pods; the HPA measures against the cpu request |
| `disallow-latest-tag` | every image has an explicit tag, and it is not `latest` | the GitOps flow deploys immutable commit-SHA tags; `latest` breaks traceability and rollback |
| `require-probes` | Deployments/StatefulSets/DaemonSets have readiness and liveness probes | zero-downtime rollouts and scale-outs depend on readiness gating |
| `disallow-privileged-containers` | `securityContext.privileged` unset or `false` | a privileged container is root on the node (Pod Security Standards, baseline) |

`require-probes` matches the controllers, not Pods: a Job's pod (e.g. the k6 load test in
`k6/`) runs to completion, so probes mean nothing there. The other three match Pods, and
Kyverno's autogen extends them to Deployments, StatefulSets, Jobs and CronJobs -- so a bad
Deployment is rejected as a whole instead of its ReplicaSet silently failing to create pods.

### Scope

Every namespace **except** the platform ones: `kube-system`, `kube-public`, `kube-node-lease`,
`default` (Traefik), `argocd`, `monitoring` and `policy` itself. Those run third-party charts
this repo does not control -- ArgoCD, Grafana's sidecars and Traefik have no limits or probes
(checked against the live cluster before enabling Enforce). Everything else is covered,
including namespaces created later -- a new service lands in a checked namespace by default.

The same list appears twice and must stay in sync:

- the `exclude` block of each policy decides the verdict;
- `config.webhooks.namespaceSelector` in `values.yaml` keeps those namespaces away from the
  webhook entirely. That is about availability: the policies fail closed, so while the
  admission controller restarts, every request the webhook sees is rejected. Without the
  selector a Kyverno restart would also block a Traefik or Prometheus pod from being recreated.

### Deprecation note

Kyverno 1.19 marks `kyverno.io/v1` `ClusterPolicy` as deprecated in favour of the CEL-based
`ValidatingPolicy` (`policies.kyverno.io`), so `kubectl apply` prints a deprecation warning.
The assignment asks for ClusterPolicies explicitly, and they remain fully supported in 1.19;
the migration path is https://kyverno.io/docs/guides/migration-to-cel/.

## Install

Kyverno first -- the ArgoCD Application fails with `no matches for kind "ClusterPolicy"` until
its CRDs exist.

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update kyverno

helm upgrade --install kyverno kyverno/kyverno \
  --namespace policy --create-namespace \
  --version 3.9.1 \
  -f policy/values.yaml \
  --wait

kubectl apply -f argocd/application-policies.yaml
```

## Verify

```bash
kubectl -n policy get pods
kubectl get clusterpolicy                          # all four READY=True
kubectl -n argocd get application cluster-policies # Synced / Healthy

# Background scan of what already runs -- staging and prod must show no FAIL
kubectl get policyreport -A
```

## Proof: a violating Deployment is rejected

```bash
kubectl apply -f policy/tests/invalid-deployment.yaml
```

The request is denied by the admission webhook, and the error names each ClusterPolicy and
rule that failed. Nothing is created:

```bash
kubectl -n staging get deploy kyverno-policy-violation-demo   # NotFound
```

The compliant counterpart passes. It is a server-side dry run, which still goes through every
admission webhook, so this is a real verdict without starting a pod:

```bash
kubectl apply --dry-run=server -f policy/tests/valid-deployment.yaml
```

## For new services (module_service)

A Deployment in `staging`/`prod` is admitted only with: a pinned image tag (the commit SHA the
pipeline publishes), cpu and memory requests and limits on every container, a readinessProbe
and a livenessProbe, and no privileged container. Check a chart change before pushing it:

```bash
helm template um charts/user-mgmt -f charts/user-mgmt/values.yaml \
  -f charts/user-mgmt/values-staging.yaml | kubectl apply --dry-run=server -n staging -f -
```

`-n staging` on the `kubectl` side matters: the chart's manifests carry no namespace, so
without it they would be checked in `default` -- which is excluded, and would pass anything.
