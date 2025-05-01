variable "hostname" {
  description = "The hostname to be assigned to the node"
  type        = string
}

variable "ip_address" {
  description = "The IP address to be assigned to the node"
  type        = string
}

variable "gateway" {
  description = "The gateway to be assigned to the node"
  type        = string
}

variable "role" {
  description = "The role to be assigned to the node"
  type        = string
}

variable "cluster_name" {
  description = "The name of the cluster"
  type        = string
}

variable "cluster_endpoint" {
  description = "The endpoint of the cluster"
  type        = string
}

variable "machine_secrets" {
  description = "Talos machine secrets to use to join."
  type        = any
}

variable "client_configuration" {
  description = "Talos client configuration to use to join."
  type        = any
}

variable "talos_version" {
  description = "Version of Talos to install."
  type        = string
}

variable "kubernetes_version" {
  description = "Version of Kubernetes to install."
  type        = string
}

variable "region" {
  description = "Region of the node"
  type        = string
}

variable "zone" {
  description = "Zone of the node"
  type        = string
}


