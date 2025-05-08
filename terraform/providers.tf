provider "kubernetes" {
  config_path = pathexpand("~/.kube/config")
  insecure    = true
}

provider "helm" {
  kubernetes {
    config_path = pathexpand("~/.kube/config")
  }
}

provider "kubectl" {
  config_path = "~/.kube/config"
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

provider "tailscale" {
  api_key = var.tailscale_api_key
}

provider "digitalocean" {
  token = var.digitalocean_token
}
