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

## Wiring a real Alertmanager notification channel

`values.yaml` ships a placeholder Alertmanager receiver on purpose (decided 2026-09-14). To
point it at a real Slack webhook without ever putting the URL in git:

```bash
kubectl create secret generic alertmanager-user-mgmt-notifications \
  --from-literal=url='https://hooks.slack.com/services/...' \
  -n monitoring
```

Then in `values.yaml`:

1. Add `alertmanager.alertmanagerSpec.secrets: [alertmanager-user-mgmt-notifications]` so the
   Operator mounts it into the Alertmanager pod under
   `/etc/alertmanager/secrets/alertmanager-user-mgmt-notifications/`.
2. Change the `placeholder` receiver's `webhook_configs` entry to `slack_configs` with
   `api_url_file: /etc/alertmanager/secrets/alertmanager-user-mgmt-notifications/url` instead
   of an inline `url:`.
3. `helm upgrade` again with the command above.

## Why the ServiceMonitor/PrometheusRule in `charts/user-mgmt` carry `release: prometheus-stack`

This release's `Prometheus` custom resource only picks up `ServiceMonitor`/`PrometheusRule`
objects labeled `release: prometheus-stack` (the default kube-prometheus-stack behaviour when
`serviceMonitorSelectorNilUsesHelmValues`/`ruleSelectorNilUsesHelmValues` are `true`, which
`values.yaml` here sets explicitly). That label has nothing to do with which Kubernetes
namespace the object lives in -- `serviceMonitorNamespaceSelector`/`ruleNamespaceSelector` are
both empty, meaning "every namespace" -- so the backend's ServiceMonitor and PrometheusRule
work unmodified in `staging`, `prod`, or anywhere else, as long as they carry that one label.
