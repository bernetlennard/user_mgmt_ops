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
