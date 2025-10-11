data "cloudflare_zone" "misery_systems" {
  filter = {
    name = "misery.systems"
  }
}

resource "cloudflare_dns_record" "misery_systems" {
  zone_id = data.cloudflare_zone.misery_systems.zone_id
  name    = "misery.systems"
  content = module.ingress_host.public_ip
  type    = "A"
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

resource "cloudflare_dns_record" "jellyseer" {
  zone_id = data.cloudflare_zone.misery_systems.zone_id
  name    = "jellyseer.misery.systems"
  content = local.ingress_hostname
  type    = "CNAME"
  ttl     = 1
}

resource "cloudflare_dns_record" "immich" {
  zone_id = data.cloudflare_zone.misery_systems.zone_id
  name    = "immich.misery.systems"
  content = local.ingress_hostname
  type    = "CNAME"
  ttl     = 1
}

resource "cloudflare_dns_record" "flux_webhook_receiver" {
  zone_id = data.cloudflare_zone.misery_systems.zone_id
  name    = "flux-webhook-receiver.ops.misery.systems"
  content = local.ingress_hostname
  type    = "CNAME"
  ttl     = 1
}


