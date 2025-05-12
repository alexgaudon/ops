data "cloudflare_zone" "misery_systems" {
  filter = {
    name = "misery.systems"
  }
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

