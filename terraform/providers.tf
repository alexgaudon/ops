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

provider "github" {
  owner = "alexgaudon"
  app_auth {
    id              = var.github_app_id
    installation_id = var.github_app_installation_id
    pem_file        = file("github-app.pem")
  }
}

provider "flux" {
  kubernetes = {
    host                   = talos_cluster_kubeconfig.config.kubernetes_client_configuration.host
    cluster_ca_certificate = base64decode(talos_cluster_kubeconfig.config.kubernetes_client_configuration.ca_certificate)
    client_certificate     = base64decode(talos_cluster_kubeconfig.config.kubernetes_client_configuration.client_certificate)
    client_key             = base64decode(talos_cluster_kubeconfig.config.kubernetes_client_configuration.client_key)
  }

  git = {
    url = "ssh://git@github.com/alexgaudon/ops.git"
    ssh = {
      username    = "git"
      private_key = tls_private_key.flux.private_key_pem
    }
  }
}
