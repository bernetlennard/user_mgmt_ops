# The one value that must never be committed. Supply it via TF_VAR_do_token in the
# environment (or a gitignored *.auto.tfvars file) -- never hardcode it here or in any .tfvars
# that gets committed.
variable "do_token" {
  description = "DigitalOcean API token. Set via the TF_VAR_do_token environment variable, never committed."
  type        = string
  sensitive   = true
}

# Reusable config values, defaulted to the cluster's actual current state (so a bare
# `terraform plan` right after import shows no changes) but overridable per environment
# without touching cluster.tf.

variable "cluster_name" {
  description = "DOKS cluster name."
  type        = string
  default     = "k8s-user-mgmt"
}

variable "region" {
  description = "DigitalOcean region slug."
  type        = string
  default     = "fra1"
}

variable "kubernetes_version" {
  description = "DOKS Kubernetes version slug (e.g. \"1.36.3-do.2\"). Check `doctl kubernetes options versions` for valid values before bumping."
  type        = string
  default     = "1.36.3-do.2"
}

variable "node_pool_name" {
  description = "Name of the (single, default) worker node pool."
  type        = string
  default     = "pool-8gb"
}

variable "node_pool_size" {
  description = "Droplet size slug for worker nodes."
  type        = string
  default     = "s-4vcpu-8gb"
}

variable "node_pool_count" {
  description = "Number of worker nodes (fixed-size pool; autoscale is off)."
  type        = number
  default     = 1
}
