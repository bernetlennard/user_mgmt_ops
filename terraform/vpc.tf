# The VPC is pre-existing (created with the cluster), so it's read, not managed. Its IP range
# is what the chart's NetworkPolicy needs: the backend's egress rule has to allow the managed
# database's private endpoint, and a NetworkPolicy can only express that as an ipBlock CIDR --
# a podSelector can never match an address outside the cluster.
data "digitalocean_vpc" "cluster" {
  id = var.vpc_uuid
}

output "vpc_ip_range" {
  description = "CIDR of the VPC shared by the DOKS cluster and the managed database. Feed this into charts/user-mgmt's networkPolicy.databaseEgress.cidrs."
  value       = data.digitalocean_vpc.cluster.ip_range
}
