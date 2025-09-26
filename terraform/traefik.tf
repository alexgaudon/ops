resource "kubernetes_namespace" "traefik" {
  metadata {
    name = "traefik"
  }
}

resource "helm_release" "traefik" {
  name      = "traefik"
  namespace = kubernetes_namespace.traefik.id

  repository = "https://traefik.github.io/charts"
  chart      = "traefik"
  version    = "37.0.0"

  set = [
    {
      name  = "logs.access.enabled"
      value = true
    },
    {
      name  = "logs.access.format"
      value = "json"
    },
    {
      name  = "logs.general.format"
      value = "json"
    },
    {
      name  = "providers.kubernetesCRD.allowCrossNamespace"
      value = true
    },
    {
      name  = "deployment.kind"
      value = "DaemonSet"
    },
    {
      name  = "resources.requests.memory"
      value = "64Mi"
    },
    {
      name  = "resources.limits.memory"
      value = "64Mi"
    },
    {
      name  = "ports.web.proxyProtocol.insecure"
      value = true
    },
    {
      name  = "ports.websecure.proxyProtocol.insecure"
      value = true
    }
  ]

  timeout = 60
}

resource "kubernetes_manifest" "traefik_https_redirect" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"

    metadata = {
      name      = "https-redirect"
      namespace = kubernetes_namespace.traefik.id
    }

    spec = {
      redirectScheme = {
        scheme    = "https"
        permanent = true
      }
    }
  }
}

resource "kubernetes_secret" "traefik_dashboard_auth" {
  metadata {
    name      = "traefik-dashboard-auth"
    namespace = kubernetes_namespace.traefik.id
  }

  data = {
    users = var.traefik_basic_auth_entry
  }
}

resource "kubernetes_manifest" "traefik_dashboard_auth" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"

    metadata = {
      name      = "traefik-dashboard-auth"
      namespace = kubernetes_namespace.traefik.id
    }

    spec = {
      basicAuth = {
        secret = kubernetes_secret.traefik_dashboard_auth.metadata[0].name
      }
    }
  }
}

resource "cloudflare_dns_record" "traefik_dashboard" {
  zone_id = data.cloudflare_zone.misery_systems.zone_id
  name    = "traefik.ops.misery.systems"
  content = local.ingress_hostname
  type    = "CNAME"
  ttl     = 1
}

resource "kubernetes_manifest" "traefik_dashboard" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"

    metadata = {
      name      = "traefik-dashboard"
      namespace = kubernetes_namespace.traefik.id
    }

    spec = {
      routes = [
        {
          kind  = "Rule"
          match = "Host(`traefik.ops.misery.systems`)"

          middlewares = [
            {
              name      = kubernetes_manifest.traefik_dashboard_auth.manifest.metadata.name
              namespace = kubernetes_manifest.traefik_dashboard_auth.manifest.metadata.namespace
            },
          ]

          services = [
            {
              kind = "TraefikService"
              name = "api@internal"
            },
          ]
        },
      ]
    }
  }
}
