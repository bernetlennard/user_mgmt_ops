# Terraform: DOKS cluster (Aufgabe 3)

Brings the already-existing `k8s-user-mgmt` DigitalOcean Kubernetes cluster under Terraform
management, without recreating it. This directory is **not** deployed through ArgoCD or any
CI pipeline -- run it by hand, from your own machine, same reasoning as `monitoring/` and
`k6/`: it manages the cluster itself, not something running inside it.

## Setup

1. A DigitalOcean API token (read-only is enough to import + plan; you'll need a
   read-write one to `apply` future changes). Supply it via a gitignored `*.auto.tfvars`
   file -- **never** as a committed value or a hardcoded default:

   ```bash
   echo 'do_token = "<your-token>"' > local.auto.tfvars
   ```

   (`terraform/*.auto.tfvars` is in `.gitignore`; Terraform loads any `*.auto.tfvars` file in
   the working directory automatically, no `-var-file` flag needed.)

2. ```bash
   terraform init
   ```

## Files

- `versions.tf` -- required Terraform + provider versions.
- `providers.tf` -- the `digitalocean` provider, reading `var.do_token`.
- `variables.tf` -- `do_token` plus the reusable, overridable config values (cluster name,
  region, Kubernetes version, node pool name/size/count), each defaulted to the cluster's
  actual current state.
- `import.tf` -- the `import` block that brought the cluster under management. Left in place
  after the one-time import (harmless on every subsequent `plan`/`apply` -- Terraform sees the
  resource is already in state and treats the block as a no-op), both for traceability and
  because it's the exact mechanism Aufgabe 3 asks for.
- `cluster.tf` -- the actual resource, hand-cleaned from `terraform plan
  -generate-config-out=generated.tf`'s raw output. See its header comment for exactly what was
  wrong with the generated version and why (two real provider bugs, not just formatting).
- `vpc.tf` -- reads the pre-existing VPC (not managed here) and outputs its CIDR, which the
  chart's NetworkPolicy needs to allow backend egress to the managed database.
- `database.tf` -- the managed PostgreSQL cluster (Aufgabe 4): one cluster, one logical
  database and one user per environment, plus a Trusted Sources firewall rule scoped to the
  DOKS cluster.
- `outputs.tf` -- the connection details, password outputs marked `sensitive`.

## Wire the credentials into Kubernetes

The chart deliberately does not render the database Secret: that would put the managed
database's password into git. Instead the Secret is created out of band from the Terraform
outputs, once per namespace. Because the chart never declares it, ArgoCD neither manages nor
prunes it.

```bash
# Values the chart needs in values-staging.yaml / values-prod.yaml:
terraform output -raw database_private_host
terraform output database_port

# The Secret itself, per namespace. `--dry-run=client -o yaml | kubectl apply -f -` makes this
# re-runnable (e.g. after a password rotation) instead of failing with AlreadyExists.
for env in staging prod; do
  kubectl create secret generic user-mgmt-db \
    --from-literal=username="$(terraform output -raw database_user_${env})" \
    --from-literal=password="$(terraform output -raw database_password_${env})" \
    -n "$env" --dry-run=client -o yaml | kubectl apply -f -
done
```

**Ordering matters.** Both ArgoCD Applications run with `prune: true`, so the moment a chart
without the postgres templates reaches `HEAD`, ArgoCD deletes the old in-cluster Postgres
Deployment *and its PVC* in both namespaces. Create these Secrets first: a backend pod whose
`secretKeyRef` target is missing sits in `CreateContainerConfigError` with no logs to read.

## Verify

```bash
terraform fmt -check   # exits 0, no diff
terraform validate     # "Success! The configuration is valid."
terraform plan          # "No changes. Your infrastructure matches the configuration."
```

## Why the cluster still exists if you `terraform destroy` right now

It won't -- `terraform state show digitalocean_kubernetes_cluster.this` matches the live
cluster's actual configuration exactly (confirmed via the `plan`/`apply` cycle used to do the
import: `1 imported, 0 added, 0 changed, 0 destroyed`, then a follow-up `plan` showing `No
changes`). Nothing here recreates or modifies the running cluster; it only starts tracking it.
