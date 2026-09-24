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

# The DOKS cluster's VPC. Shared by the managed database so the two talk over DigitalOcean's
# private network rather than the public internet.
variable "vpc_uuid" {
  description = "UUID of the VPC the cluster and the managed database both live in."
  type        = string
  default     = "9c49662a-56ec-4b69-9c4a-9178ef9c1cee"
}

# --- Managed PostgreSQL (Aufgabe 4) ---

variable "database_cluster_name" {
  description = "Name of the managed PostgreSQL cluster."
  type        = string
  default     = "user-mgmt-postgres"
}

variable "database_version" {
  description = "Managed PostgreSQL major version. Check `doctl databases options versions --engine pg` for what DigitalOcean currently offers before bumping."
  type        = string
  default     = "17"
}

variable "database_size" {
  description = "Managed database node size slug. db-s-1vcpu-1gb is the smallest (and cheapest) tier."
  type        = string
  default     = "db-s-1vcpu-1gb"
}

variable "database_name_staging" {
  description = "Logical database used by the staging release."
  type        = string
  default     = "user_mgmt_staging"
}

variable "database_name_prod" {
  description = "Logical database used by the prod release."
  type        = string
  default     = "user_mgmt_prod"
}

variable "database_user_staging" {
  description = "Database user for the staging release."
  type        = string
  default     = "user_mgmt_staging"
}

variable "database_user_prod" {
  description = "Database user for the prod release."
  type        = string
  default     = "user_mgmt_prod"
}

# --- Managed MySQL for module_service (Aufgabe 6) ---

variable "mysql_cluster_name" {
  description = "Name of the managed MySQL cluster."
  type        = string
  default     = "module-service-mysql"
}

variable "mysql_version" {
  description = "Managed MySQL version. Check `doctl databases options versions` for what DigitalOcean currently offers before bumping."
  type        = string
  default     = "8.4"
}

variable "mysql_size" {
  description = "Managed database node size slug. db-s-1vcpu-1gb is the smallest (and cheapest) tier."
  type        = string
  default     = "db-s-1vcpu-1gb"
}

variable "mysql_database_staging" {
  description = "Logical MySQL database used by module_service in staging."
  type        = string
  default     = "module_service_staging"
}

variable "mysql_database_prod" {
  description = "Logical MySQL database used by module_service in prod."
  type        = string
  default     = "module_service_prod"
}

variable "mysql_user_staging" {
  description = "MySQL user for module_service in staging."
  type        = string
  default     = "module_service_staging"
}

variable "mysql_user_prod" {
  description = "MySQL user for module_service in prod."
  type        = string
  default     = "module_service_prod"
}
