resource "time_sleep" "wait_for_device" {
  depends_on      = [kubernetes_deployment.router]
  create_duration = "60s"  # Increased wait time
}

data "tailscale_devices" "router" {
  depends_on = [time_sleep.wait_for_device]

  name_prefix = var.router_name
}

# Manual step: You'll need to approve the subnet routes in Tailscale admin console
# This resource will be created after the device appears
resource "tailscale_device_subnet_routes" "service_router" {
  depends_on = [data.tailscale_devices.router]
  
  device_id  = data.tailscale_devices.router.devices[0].id
  routes     = var.routes
}
