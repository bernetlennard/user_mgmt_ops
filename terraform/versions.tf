terraform {
  required_version = ">= 1.16"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.55"
    }
  }
}
