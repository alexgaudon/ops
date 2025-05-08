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

  set {
    name  = "speaker.resources.requests.memory"
    value = "64Mi"
  }

  set {
    name  = "speaker.resources.limits.memory"
    value = "128Mi"
  }

  set {
    name  = "speaker.frr.enabled"
    value = "false"
  }

  set {
    name  = "speaker.frrSpeaker.enabled"
    value = "false"
  }

  set {
    name  = "speaker.reloader.resources.requests.memory"
    value = "16Mi"
  }

  set {
    name  = "speaker.reloader.resources.limits.memory"
    value = "32Mi"
  }

  set {
    name  = "controller.resources.requests.memory"
    value = "48Mi"
  }

  set {
    name  = "controller.resources.limits.memory"
    value = "96Mi"
  }
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

resource "kubectl_manifest" "metallb_cluster_vip_pool" {
  depends_on = [helm_release.metallb]

  yaml_body = yamlencode({
    apiVersion = "metallb.io/v1beta1"
    kind       = "IPAddressPool"
    metadata = {
      name      = "cluster-vip"
      namespace = kubernetes_namespace.metallb_system.metadata[0].name
    }
    spec = {
      addresses = [
        var.lb_ip_range
      ]
    }
  })
}

resource "kubectl_manifest" "metallb_cluster_vip_announcement" {
  depends_on = [helm_release.metallb]

  yaml_body = yamlencode({
    apiVersion = "metallb.io/v1beta1"
    kind       = "L2Advertisement"
    metadata = {
      name      = "cluster-vip"
      namespace = kubernetes_namespace.metallb_system.metadata[0].name
    }
    spec = {
      ipAddressPools = ["cluster-vip"]
    }
  })
}

resource "kubernetes_service" "cluster_vip" {
  metadata {
    name      = "cluster-vip"
    namespace = "kube-system"
    annotations = {
      "metallb.universe.tf/allow-shared-ip"       = "true"
      "metallb.universe.tf/address-pool"          = "cluster-vip"
      "metallb.universe.tf/loadBalancerIPs"       = "10.0.0.245"
      "service.kubernetes.io/load-balancer-class" = "metallb"
    }
  }

  spec {
    type = "LoadBalancer"

    port {
      name        = "https"
      port        = 6443
      target_port = 6443
      protocol    = "TCP"
    }

    selector = {
      "component" = "kube-apiserver"
    }

    publish_not_ready_addresses = true
  }
}
