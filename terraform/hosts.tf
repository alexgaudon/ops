locals {
  proxmox_hosts = {
    "sorrow"  = "10.0.0.6"
    "despair" = "10.0.0.7"
    "bleak"   = "10.0.0.8"
  }
}

module "proxmox_hosts" {
  for_each = local.proxmox_hosts

  source = "./modules/proxmox_hosts"

  name    = each.key
  ip      = each.value
  zone_id = data.cloudflare_zone.misery_systems.zone_id
}


resource "cloudflare_dns_record" "proxy_internal" {
  zone_id = data.cloudflare_zone.misery_systems.zone_id
  name    = "proxy.hosts.misery.systems"
  content = "10.0.0.136"
  type    = "A"
  ttl     = 1
}
