locals {
  proxied_ports = {
    traefik-http = {
      source_port = 80
      dest_addr   = "10.0.0.230:80"
    }
    traefik-https = {
      source_port = 443
      dest_addr   = "10.0.0.230:443"
    }
  }
}

data "http" "ip_resp" {
  url = "https://ipv4.icanhazip.com"
}

module "ingress_host" {
  source = "./modules/droplet"

  name   = "ingress"
  vcpus  = 1
  memory = 1024
  # TODO: Upgrade to Debian 12
  distribution_version = "12 x64"

  userdata = templatefile(
    "${path.module}/templates/ingress_userdata.sh.tmpl",
    {
      tailscale_token = tailscale_tailnet_key.droplet.key,
      caddy_config = jsonencode({
        apps = {
          layer4 = {
            servers = { for k, v in local.proxied_ports : k => {
              listen = [":${v.source_port}"]
              routes = [{
                handle = [{
                  handler        = "proxy"
                  proxy_protocol = "v2"
                  upstreams = [{
                    dial = [v.dest_addr]
                  }]
                }]
              }]
              }
            }
          }
        }
      })
    }
  )

  use_static_ip = true
  ingress_rules = [
    {
      protocol         = "tcp"
      port_range       = "22",
      source_addresses = ["${chomp(data.http.ip_resp.response_body)}/32"]
    },
    {
      protocol         = "tcp"
      port_range       = "80"
      source_addresses = ["0.0.0.0/0", "::/0"]
    },
    {
      protocol         = "tcp"
      port_range       = "443"
      source_addresses = ["0.0.0.0/0", "::/0"]
    }
  ]
}

resource "cloudflare_dns_record" "ingress" {
  zone_id = data.cloudflare_zone.misery_systems.zone_id
  name    = "ingress.misery.systems"
  content = module.ingress_host.public_ip
  type    = "A"
  ttl     = 1
}

locals {
  ingress_hostname = cloudflare_dns_record.ingress.name
  ingress_ip       = cloudflare_dns_record.ingress.content
}
