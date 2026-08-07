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
      version = "5.22.0"
    }
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "2.96.0"
    }
    tailscale = {
      source  = "tailscale/tailscale"
      version = "0.29.2"
    }
    flux = {
      source  = "fluxcd/flux"
      version = "1.9.4"
    }
    github = {
      source  = "integrations/github"
      version = "6.13.0"
    }
  }
}
