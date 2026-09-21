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

# The lifecycle block works around a provider bug, not a real setting. After creation the
# provider reads back an empty `settings {}` block that was never configured, then tries to
# PUT it on the next apply -- which the API rejects outright:
#
#   400 request is missing the following required fields: user_settings
#
# That turns every subsequent `terraform apply` into a hard failure, including applies that
# have nothing to do with these users. Ignoring the phantom block is the fix; there are no
# real per-user settings to manage here.
resource "digitalocean_database_user" "staging" {
  cluster_id = digitalocean_database_cluster.postgres.id
  name       = var.database_user_staging

  lifecycle {
    ignore_changes = [settings]
  }
}

resource "digitalocean_database_user" "prod" {
  cluster_id = digitalocean_database_cluster.postgres.id
  name       = var.database_user_prod

  lifecycle {
    ignore_changes = [settings]
  }
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
