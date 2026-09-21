# Hand-cleaned from `terraform plan -generate-config-out=generated.tf` (see import.tf and
# README.md). The raw generator output needed two real fixes, not just tidying:
#
# 1. It emitted BOTH halves of several mutually-exclusive optional blocks at once (e.g.
#    amd_gpu_device_plugin + amd_gpu_dra_driver, nvidia_gpu_device_plugin +
#    nvidia_gpu_dra_driver), which `terraform validate` rejected outright as conflicting
#    arguments -- a bug in the provider's (explicitly experimental) config generation, not a
#    real property of this cluster. None of these apply here anyway -- no GPU node pools exist
#    -- so the fix is to omit the whole family of GPU/exotic-feature blocks rather than pick a
#    side; they default to disabled when absent.
# 2. It generated node_pool.node_count = 0, min_nodes = 0, max_nodes = 0 for a pool that
#    actually runs 1 node (confirmed via `doctl kubernetes cluster node-pool list`) with
#    autoscaling off. min_nodes/max_nodes only mean anything when auto_scale = true, so they're
#    dropped; node_count is corrected to the real value via var.node_pool_count.
#
# Everything else below matches the cluster's actual live state at import time, confirmed by
# `terraform plan` showing zero changes afterward (see README.md, "Verify").
resource "digitalocean_kubernetes_cluster" "this" {
  name     = var.cluster_name
  region   = var.region
  version  = var.kubernetes_version
  vpc_uuid = var.vpc_uuid

  ha            = false
  auto_upgrade  = false
  surge_upgrade = true

  maintenance_policy {
    day        = "any"
    start_time = "15:00"
  }

  node_pool {
    name       = var.node_pool_name
    size       = var.node_pool_size
    node_count = var.node_pool_count
    auto_scale = false
  }
}
