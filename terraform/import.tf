# Aufgabe 3: brings the already-existing DOKS cluster under Terraform management without
# recreating it. `terraform plan -generate-config-out=generated.tf` reads this block and
# writes a resource matching the cluster's current live state into generated.tf -- see
# README.md for the exact command. That generated file is then hand-reviewed and cleaned up
# (this repo's own convention: nothing generated ships unread), not committed as-is.
import {
  to = digitalocean_kubernetes_cluster.this
  id = "a9dd1c11-7cef-43b8-a886-6218adc95b31" # k8s-user-mgmt
}
