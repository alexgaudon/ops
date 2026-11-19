resource "kubernetes_namespace_v1" "tailscale" {
  metadata {
    name = "tailscale"

    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
      "pod-security.kubernetes.io/audit"   = "privileged"
      "pod-security.kubernetes.io/warn"    = "privileged"
    }
  }
}

resource "tailscale_tailnet_key" "k8s" {
  reusable      = true
  ephemeral     = true
  preauthorized = true
  expiry        = 90 * 24 * 60 * 60
}

resource "tailscale_tailnet_key" "droplet" {
  reusable      = true
  ephemeral     = true
  preauthorized = true
  expiry        = 90 * 24 * 60 * 60
  tags          = ["tag:edge"]
}

# Tailnet access policy: the public edge droplet may reach exactly one
# target - the compose host's Caddy edge (10.0.0.50:80,443) - and nothing
# else. A compromised droplet sees one port on one host instead of the
# whole LAN. Member devices keep unrestricted access, including reaching
# the droplet itself.
resource "tailscale_acl" "acl" {
  overwrite_existing_content = true

  acl = <<-EOT
    {
      "tagOwners": {
        "tag:edge": ["autogroup:member"],
      },

      "acls": [
        {"action": "accept", "src": ["tag:edge"], "dst": ["10.0.0.50/32:80,443"]},
        {"action": "accept", "src": ["autogroup:member"], "dst": ["*:*"]},
      ],

      "ssh": [
        {"action": "check", "src": ["autogroup:member"], "dst": ["autogroup:self"], "users": ["autogroup:nonroot", "root"]},
      ],
    }
  EOT
}

# Tag the current edge droplet so the ACL binds to it. Future droplet
# recreations inherit the tag from the auth key above; this resource keeps
# the live device id pinned regardless.
resource "tailscale_device_tags" "edge_droplet" {
  device_id = "222748365225131"
  tags      = ["tag:edge"]
}

resource "kubernetes_secret_v1" "tailscale_auth" {
  metadata {
    name      = "tailscale-auth"
    namespace = kubernetes_namespace_v1.tailscale.metadata[0].name
  }

  data = {
    TS_AUTHKEY = tailscale_tailnet_key.k8s.key
  }
}
