# Aufgabe 6: the managed MySQL behind module_service.
#
# Same shape as the PostgreSQL in database.tf, for the same reasons: one cluster with one
# logical database and one user per environment, in the cluster's VPC, reachable only from the
# DOKS cluster. It is a separate cluster rather than a second database on the Postgres one
# because the engines differ -- DigitalOcean runs one engine per cluster.
#
# Only module_service gets credentials for it. user_mgmt_service never connects here; it
# reaches module data through module_service's REST API, and the chart's NetworkPolicy only
# lets the module-service pods open connections to this port.
resource "digitalocean_database_cluster" "mysql" {
  name       = var.mysql_cluster_name
  engine     = "mysql"
  version    = var.mysql_version
  size       = var.mysql_size
  region     = var.region
  node_count = 1

  private_network_uuid = var.vpc_uuid
}

resource "digitalocean_database_db" "module_service_staging" {
  cluster_id = digitalocean_database_cluster.mysql.id
  name       = var.mysql_database_staging
}

resource "digitalocean_database_db" "module_service_prod" {
  cluster_id = digitalocean_database_cluster.mysql.id
  name       = var.mysql_database_prod
}

# ignore_changes for the same provider bug as the Postgres users in database.tf: a phantom
# empty `settings` block would otherwise break every later apply.
resource "digitalocean_database_user" "module_service_staging" {
  cluster_id = digitalocean_database_cluster.mysql.id
  name       = var.mysql_user_staging

  lifecycle {
    ignore_changes = [settings]
  }
}

resource "digitalocean_database_user" "module_service_prod" {
  cluster_id = digitalocean_database_cluster.mysql.id
  name       = var.mysql_user_prod

  lifecycle {
    ignore_changes = [settings]
  }
}

# Trusted Sources: only workloads on the DOKS cluster may connect.
resource "digitalocean_database_firewall" "mysql" {
  cluster_id = digitalocean_database_cluster.mysql.id

  rule {
    type  = "k8s"
    value = digitalocean_kubernetes_cluster.this.id
  }
}

# The CA that signed the cluster's server certificate. module_service verifies the server
# against it instead of accepting any certificate. It is public data, not a credential.
data "digitalocean_database_ca" "mysql" {
  cluster_id = digitalocean_database_cluster.mysql.id
}
