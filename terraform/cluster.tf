locals {
  cluster_nodes = {
    k8s-control-plane-1 = {
      ip     = "10.0.0.40"
      role   = "controlplane"
      region = "sorrow"
      zone   = "a"
    }
    k8s-control-plane-2 = {
      ip     = "10.0.0.41"
      role   = "controlplane"
      region = "despair"
      zone   = "a"
    }
    k8s-control-plane-3 = {
      ip     = "10.0.0.42"
      role   = "controlplane"
      region = "bleak"
      zone   = "a"
    }

    k8s-worker-1 = {
      ip     = "10.0.0.46"
      role   = "worker"
      region = "sorrow"
      zone   = "a"
    }
    k8s-worker-2 = {
      ip     = "10.0.0.47"
      role   = "worker"
      region = "despair"
      zone   = "a"
    }
    k8s-worker-3 = {
      ip     = "10.0.0.48"
      role   = "worker"
      region = "bleak"
      zone   = "a"
    }
  }

  talos_version      = "1.10.7"
  kubernetes_version = "1.33.0"

  control_plane_nodes = { for k, v in local.cluster_nodes : k => v if v.role == "controlplane" }
  worker_nodes        = { for k, v in local.cluster_nodes : k => v if v.role == "worker" }
}

resource "talos_machine_secrets" "secrets" {}

module "control_plane_node" {
  source   = "./modules/node"
  for_each = local.control_plane_nodes

  hostname             = each.key
  ip_address           = each.value.ip
  gateway              = "10.0.0.2"
  role                 = each.value.role
  region               = each.value.region
  zone                 = each.value.zone
  cluster_name         = var.cluster_name
  cluster_endpoint     = var.cluster_endpoint
  machine_secrets      = talos_machine_secrets.secrets.machine_secrets
  client_configuration = talos_machine_secrets.secrets.client_configuration

  talos_version      = local.talos_version
  kubernetes_version = local.kubernetes_version
}

module "worker_node" {
  source   = "./modules/node"
  for_each = local.worker_nodes

  hostname             = each.key
  ip_address           = each.value.ip
  gateway              = "10.0.0.2"
  region               = each.value.region
  zone                 = each.value.zone
  role                 = "worker"
  cluster_name         = var.cluster_name
  cluster_endpoint     = var.cluster_endpoint
  machine_secrets      = talos_machine_secrets.secrets.machine_secrets
  client_configuration = talos_machine_secrets.secrets.client_configuration

  talos_version      = local.talos_version
  kubernetes_version = local.kubernetes_version
}


resource "talos_machine_bootstrap" "cluster" {
  depends_on = [module.control_plane_node]

  node                 = local.control_plane_nodes.k8s-control-plane-1.ip
  client_configuration = talos_machine_secrets.secrets.client_configuration
}

data "talos_client_configuration" "config" {
  depends_on = [module.control_plane_node]

  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.secrets.client_configuration
  endpoints            = [for k, v in local.control_plane_nodes : v.ip]
}

resource "cloudflare_dns_record" "cluster" {
  for_each = local.control_plane_nodes

  zone_id = data.cloudflare_zone.misery_systems.zone_id
  name    = "cluster.ops.misery.systems"
  content = each.value.ip
  type    = "A"
  ttl     = 1
}

resource "talos_cluster_kubeconfig" "config" {
  depends_on = [module.control_plane_node]

  client_configuration = talos_machine_secrets.secrets.client_configuration
  node                 = local.control_plane_nodes.k8s-control-plane-1.ip
}
