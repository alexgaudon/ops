variable "cluster_name" {
  type    = string
  default = "misery"
}

variable "cluster_endpoint" {
  type    = string
  default = "https://cluster.ops.misery.systems:6443"
}

variable "lb_ip_range" {
  type    = string
  default = "10.0.0.246-10.0.0.252"
}

variable "github_app_id" {
  type = string
}

variable "github_app_installation_id" {
  type = string
}

variable "cloudflare_api_token" {
  type = string
}

variable "tailscale_key" {
  type = string
}

variable "tailscale_api_key" {
  type = string
}

variable "tailnet_name" {
  type = string
}

variable "digitalocean_token" {
  type = string
}

variable "home_public_ipv4" {
  description = "Public IPv4 address of the home ingress, supplied via a local tfvars file."
  type        = string
  sensitive   = true
}

variable "ssh_key_ids" {
  type    = list(string)
  default = []
}

variable "traefik_basic_auth_entry" {
  type = string
}

variable "age_secret_key" {
  type = string
}
