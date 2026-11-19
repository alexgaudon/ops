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

# Keep private access for tailnet members.
resource "tailscale_acl" "acl" {
  overwrite_existing_content = true

  acl = <<-EOT
    {
      "acls": [
        {"action": "accept", "src": ["autogroup:member"], "dst": ["*:*"]},
      ],

      "ssh": [
        {"action": "check", "src": ["autogroup:member"], "dst": ["autogroup:self"], "users": ["autogroup:nonroot", "root"]},
      ],
    }
  EOT
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
