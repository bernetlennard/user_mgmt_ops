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

## Grant the app users schema rights (one-time, required)

**Without this the application silently has no database schema.** PostgreSQL 15+ revoked the
default `CREATE` privilege on the `public` schema for everyone except the schema owner. The
databases are owned by DigitalOcean's built-in `doadmin`, so the per-environment users this
Terraform creates can connect but cannot create tables -- Hibernate's `ddl-auto: update` logs
`ERROR: permission denied for schema public` at DEBUG level and carries on with no tables.

The failure is nastier than it sounds: the pods stay `Ready` (the health check only opens a
connection, it does not touch a table) while every request returns **403/401**, because the
security filter chain's user lookup hits a missing relation. Nothing points at the database.

Run once per database, as `doadmin`:

```sql
GRANT ALL ON SCHEMA public TO "user_mgmt_staging";
ALTER SCHEMA public OWNER TO "user_mgmt_staging";
-- and the same for user_mgmt_prod in the user_mgmt_prod database
```

The admin credentials are `terraform output -raw database_admin_user` /
`database_admin_password`. They exist for exactly this bootstrap -- the application never uses
them and they are deliberately not put into any Kubernetes Secret. Restart the backends
afterwards so Hibernate retries the DDL:

```bash
kubectl -n staging rollout restart deploy user-mgmt-staging-user-mgmt-backend
kubectl -n prod rollout restart deploy user-mgmt-prod-user-mgmt-backend
```

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
