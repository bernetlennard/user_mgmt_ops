# Connection details for the managed database, consumed when creating the Kubernetes Secrets
# that the backend reads (see terraform/README.md, "Wire the credentials into Kubernetes").
#
# Everything password-bearing is marked sensitive, so it never lands in plan/apply output or
# CI logs -- read it deliberately with `terraform output -raw <name>`. The state file holds
# these values in the clear, which is exactly why terraform/*.tfstate is gitignored.

output "database_private_host" {
  description = "Private (VPC) hostname of the managed Postgres cluster. Use this one from inside the cluster -- it keeps traffic off the public internet."
  value       = digitalocean_database_cluster.postgres.private_host
}

output "database_port" {
  description = "Port of the managed Postgres cluster. DigitalOcean assigns this per cluster; it is NOT 5432."
  value       = digitalocean_database_cluster.postgres.port
}

output "database_staging" {
  description = "Logical database name for staging."
  value       = digitalocean_database_db.staging.name
}

output "database_prod" {
  description = "Logical database name for prod."
  value       = digitalocean_database_db.prod.name
}

output "database_user_staging" {
  description = "Database username for staging."
  value       = digitalocean_database_user.staging.name
}

output "database_user_prod" {
  description = "Database username for prod."
  value       = digitalocean_database_user.prod.name
}

output "database_password_staging" {
  description = "Password for the staging database user."
  value       = digitalocean_database_user.staging.password
  sensitive   = true
}

output "database_password_prod" {
  description = "Password for the prod database user."
  value       = digitalocean_database_user.prod.password
  sensitive   = true
}

# DigitalOcean's built-in admin user. Needed only for the one-time schema GRANT documented in
# README.md -- the application never uses these credentials, and they are deliberately NOT
# put into any Kubernetes Secret.
output "database_admin_user" {
  description = "Built-in admin user (doadmin). For one-time bootstrap only."
  value       = digitalocean_database_cluster.postgres.user
  sensitive   = true
}

output "database_admin_password" {
  description = "Password of the built-in admin user. For one-time bootstrap only."
  value       = digitalocean_database_cluster.postgres.password
  sensitive   = true
}

# --- Managed MySQL for module_service (Aufgabe 6) ---

output "mysql_private_host" {
  description = "Private (VPC) hostname of the managed MySQL cluster."
  value       = digitalocean_database_cluster.mysql.private_host
}

output "mysql_port" {
  description = "Port of the managed MySQL cluster. Assigned by DigitalOcean; it is NOT 3306."
  value       = digitalocean_database_cluster.mysql.port
}

output "mysql_database_staging" {
  description = "Logical MySQL database for module_service in staging."
  value       = digitalocean_database_db.module_service_staging.name
}

output "mysql_database_prod" {
  description = "Logical MySQL database for module_service in prod."
  value       = digitalocean_database_db.module_service_prod.name
}

output "mysql_user_staging" {
  description = "MySQL user for module_service in staging."
  value       = digitalocean_database_user.module_service_staging.name
}

output "mysql_user_prod" {
  description = "MySQL user for module_service in prod."
  value       = digitalocean_database_user.module_service_prod.name
}

output "mysql_password_staging" {
  description = "Password of the staging MySQL user."
  value       = digitalocean_database_user.module_service_staging.password
  sensitive   = true
}

output "mysql_password_prod" {
  description = "Password of the prod MySQL user."
  value       = digitalocean_database_user.module_service_prod.password
  sensitive   = true
}

output "mysql_admin_user" {
  description = "Built-in admin user (doadmin) of the MySQL cluster. For one-time bootstrap only."
  value       = digitalocean_database_cluster.mysql.user
  sensitive   = true
}

output "mysql_admin_password" {
  description = "Password of the MySQL admin user. For one-time bootstrap only."
  value       = digitalocean_database_cluster.mysql.password
  sensitive   = true
}

# Public certificate, not a secret: goes into the chart as-is (charts/user-mgmt/files/).
output "mysql_ca_certificate" {
  description = "PEM CA certificate of the managed MySQL cluster; module_service verifies the server against it."
  value       = data.digitalocean_database_ca.mysql.certificate
}
