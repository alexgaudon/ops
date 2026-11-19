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
  content = var.home_public_ipv4
  type    = "A"
  proxied = false
  ttl     = 1

  lifecycle {
    # DDNS on Apophis owns the address; home_public_ipv4 bootstraps the record.
    ignore_changes = [content]
  }
}

resource "cloudflare_dns_record" "jellyfin" {
  zone_id = data.cloudflare_zone.misery_systems.zone_id
  name    = "jellyfin.misery.systems"
  content = "misery.systems"
  type    = "CNAME"
  proxied = false
  ttl     = 1
}

resource "cloudflare_dns_record" "jellyseer" {
  zone_id = data.cloudflare_zone.misery_systems.zone_id
  name    = "jellyseer.misery.systems"
  content = "misery.systems"
  type    = "CNAME"
  proxied = false
  ttl     = 60
}

resource "cloudflare_dns_record" "lootsheet_app" {
  zone_id = data.cloudflare_zone.lootsheet.zone_id
  name    = "lootsheet.app"
  content = "misery.systems"
  type    = "CNAME"
  proxied = false
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

# Public DNS for protected routes; Caddy only proxies explicitly configured hosts.
resource "cloudflare_dns_record" "external_wildcard" {
  zone_id = data.cloudflare_zone.misery_systems.zone_id
  name    = "*.external.misery.systems"
  content = "misery.systems"
  type    = "CNAME"
  proxied = false
  ttl     = 60
}

# The preview API and internal previews terminate only on internal Caddy.
resource "cloudflare_dns_record" "dev_wildcard" {
  zone_id = data.cloudflare_zone.misery_systems.zone_id
  name    = "*.dev.misery.systems"
  content = "10.0.0.51"
  type    = "A"
  proxied = false
  ttl     = 60
}

resource "cloudflare_dns_record" "public_preview_wildcard" {
  zone_id = data.cloudflare_zone.misery_systems.zone_id
  name    = "*.preview.external.misery.systems"
  content = "misery.systems"
  type    = "CNAME"
  proxied = false
  ttl     = 60
}
