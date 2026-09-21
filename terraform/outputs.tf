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
