# Aufgabe 4: the managed PostgreSQL that replaces the in-cluster postgres Deployment/PVC.
#
# One cluster, two logical databases (staging + prod) with a DB user each -- rather than two
# managed clusters -- because a DOKS-sized managed Postgres is billed per cluster and the two
# environments here are coursework-scale. The isolation that matters (separate databases,
# separate users, separate credentials) is still there; what's shared is the compute.
resource "digitalocean_database_cluster" "postgres" {
  name       = var.database_cluster_name
  engine     = "pg"
  version    = var.database_version
  size       = var.database_size
  region     = var.region
  node_count = 1

  # Same VPC as the DOKS cluster, so the backend reaches it over DigitalOcean's private
  # network instead of the public internet. This is also what makes the "k8s" firewall rule
  # below meaningful -- see the private_host output.
  private_network_uuid = var.vpc_uuid
}

resource "digitalocean_database_db" "staging" {
  cluster_id = digitalocean_database_cluster.postgres.id
  name       = var.database_name_staging
}

resource "digitalocean_database_db" "prod" {
  cluster_id = digitalocean_database_cluster.postgres.id
  name       = var.database_name_prod
}

resource "digitalocean_database_user" "staging" {
  cluster_id = digitalocean_database_cluster.postgres.id
  name       = var.database_user_staging
}

resource "digitalocean_database_user" "prod" {
  cluster_id = digitalocean_database_cluster.postgres.id
  name       = var.database_user_prod
}

# Trusted Sources: the managed database rejects everything that isn't listed here, regardless
# of what Kubernetes NetworkPolicy allows on the cluster side. Scoping this to the DOKS
# cluster's own ID means only workloads on that cluster can connect at all -- no public
# password-guessing surface.
resource "digitalocean_database_firewall" "postgres" {
  cluster_id = digitalocean_database_cluster.postgres.id

  rule {
    type  = "k8s"
    value = digitalocean_kubernetes_cluster.this.id
  }
}
