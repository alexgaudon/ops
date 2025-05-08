data "tailscale_devices" "router" {
  depends_on = [kubernetes_deployment.router]

  name_prefix = var.router_name
}

resource "time_sleep" "wait_for_device" {
  depends_on      = [kubernetes_deployment.router]
  create_duration = "30s"
}

resource "tailscale_device_subnet_routes" "service_router" {
  depends_on = [time_sleep.wait_for_device]
  device_id  = data.tailscale_devices.router.devices[0].id
  routes     = var.routes
}
