terraform {
  required_providers {
    talos = {
      source  = "siderolabs/talos"
      version = ">=0.2.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "5.4.0"
    }
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "2.53.0"
    }
    tailscale = {
      source  = "tailscale/tailscale"
      version = "0.20.0"
    }
  }
}
