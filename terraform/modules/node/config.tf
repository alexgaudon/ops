data "talos_machine_configuration" "config" {
  cluster_name     = var.cluster_name
  cluster_endpoint = var.cluster_endpoint
  machine_type     = var.role
  machine_secrets  = var.machine_secrets

  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version
}

resource "talos_machine_configuration_apply" "node" {
  node = var.ip_address

  client_configuration        = var.client_configuration
  machine_configuration_input = data.talos_machine_configuration.config.machine_configuration
  config_patches = concat(
    [
      templatefile(
        "${path.module}/templates/networking.yaml.tmpl", {
          hostname   = var.hostname
          ip_address = var.ip_address
          gateway    = var.gateway
      }),
      templatefile(
        "${path.module}/templates/topology.yaml.tmpl", {
          region = var.region
          zone   = var.zone
        }
      ),
    ],
    var.role == "controlplane" ? [
      file("${path.module}/files/controlplane-scheduling.yaml")
    ] : []
  )
}
