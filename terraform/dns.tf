data "cloudflare_zone" "misery_systems" {
  filter = {
    name = "misery.systems"
  }
}

resource "cloudflare_dns_record" "misery_systems" {
  zone_id = data.cloudflare_zone.misery_systems.zone_id
  name    = "misery.systems"
  content = local.ingress_hostname
  type    = "CNAME"
  ttl     = 1
}

resource "cloudflare_dns_record" "downward" {
  zone_id = data.cloudflare_zone.misery_systems.zone_id
  name    = "downward.misery.systems"
  content = local.ingress_hostname
  type    = "CNAME"
  ttl     = 1
}

resource "cloudflare_dns_record" "thirteenft" {
  zone_id = data.cloudflare_zone.misery_systems.zone_id
  name    = "13ft.misery.systems"
  content = local.ingress_hostname
  type    = "CNAME"
  ttl     = 1
}

resource "cloudflare_dns_record" "ntfy" {
  zone_id = data.cloudflare_zone.misery_systems.zone_id
  name    = "ntfy.misery.systems"
  content = local.ingress_hostname
  type    = "CNAME"
  ttl     = 1
}

resource "cloudflare_dns_record" "jellyfin" {
  zone_id = data.cloudflare_zone.misery_systems.zone_id
  name    = "jellyfin.misery.systems"
  content = local.ingress_hostname
  type    = "CNAME"
  ttl     = 1
}
