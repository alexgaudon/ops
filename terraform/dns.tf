data "cloudflare_zone" "misery_systems" {
  filter = {
    name = "misery.systems"
  }
}

data "cloudflare_zone" "lootsheet" {
  filter = {
    name = "lootsheet.app"
  }
}

resource "cloudflare_dns_record" "misery_systems" {
  zone_id = data.cloudflare_zone.misery_systems.zone_id
  name    = "misery.systems"
  content = module.ingress_host.public_ip
  type    = "A"
  ttl     = 1
}

resource "cloudflare_dns_record" "jellyfin" {
  zone_id = data.cloudflare_zone.misery_systems.zone_id
  name    = "jellyfin.misery.systems"
  content = local.ingress_hostname
  type    = "CNAME"
  ttl     = 1
}

resource "cloudflare_dns_record" "lootsheet_app" {
  zone_id = data.cloudflare_zone.lootsheet.zone_id
  name    = "lootsheet.app"
  content = local.ingress_hostname
  type    = "CNAME"
  ttl     = 1
}

# Public DNS returns a LAN-only address; Cloudflare does not proxy it.
resource "cloudflare_dns_record" "internal_wildcard" {
  zone_id = data.cloudflare_zone.misery_systems.zone_id
  name    = "*.internal.misery.systems"
  content = "10.0.0.51"
  type    = "A"
  proxied = false
  ttl     = 60
}
