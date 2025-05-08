output "kubeconfig" {
  value       = talos_cluster_kubeconfig.config.kubeconfig_raw
  sensitive   = true
  description = "Kubeconfig for the cluster"
}

output "talosconfig" {
  value       = data.talos_client_configuration.config.talos_config
  sensitive   = true
  description = "Talosconfig for the cluster"
}

output "ingress_ip" {
  value       = module.ingress_host.public_ip
  description = "Public IP of the ingress host"
}
