resource "kubernetes_namespace" "metallb_system" {
  metadata {
    name = "metallb-system"

    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
      "pod-security.kubernetes.io/audit"   = "privileged"
      "pod-security.kubernetes.io/warn"    = "privileged"
    }
  }
}

resource "helm_release" "metallb" {
  name      = "metallb"
  namespace = kubernetes_namespace.metallb_system.id

  repository = "https://metallb.github.io/metallb"
  chart      = "metallb"
  version    = "0.14.9"

  timeout = 900 # 15 minutes timeout

  set = [
    {
      name  = "speaker.resources.requests.memory"
      value = "64Mi"
    },
    {
      name  = "speaker.resources.limits.memory"
      value = "128Mi"
    },
    {
      name  = "speaker.frr.enabled"
      value = "false"
    },
    {
      name  = "speaker.frrSpeaker.enabled"
      value = "false"
    },
    {
      name  = "speaker.reloader.resources.requests.memory"
      value = "16Mi"
    },
    {
      name  = "speaker.reloader.resources.limits.memory"
      value = "32Mi"
    },
    {
      name  = "controller.resources.requests.memory"
      value = "48Mi"
    },
    {
      name  = "controller.resources.limits.memory"
      value = "96Mi"
    }
  ]
}

resource "kubectl_manifest" "metallb_ip_pool" {
  depends_on = [helm_release.metallb]

  yaml_body = yamlencode({
    apiVersion = "metallb.io/v1beta1"
    kind       = "IPAddressPool"
    metadata = {
      name      = "default"
      namespace = kubernetes_namespace.metallb_system.metadata[0].name
    }
    spec = {
      addresses = [
        var.lb_ip_range
      ]
    }
  })
}

resource "kubectl_manifest" "metallb_default_l2_announcement" {
  depends_on = [helm_release.metallb]

  yaml_body = yamlencode({
    apiVersion = "metallb.io/v1beta1"
    kind       = "L2Advertisement"
    metadata = {
      name      = "default"
      namespace = kubernetes_namespace.metallb_system.metadata[0].name
      annotations = {
        "metallb.universe.tf/allow-shared-ip" = "true"
      }
    }
    spec = {
      ipAddressPools = ["default"]
    }
  })
}
