data "cloudflare_zone" "misery_systems" {
  filter = {
    name = "misery.systems"
  }
}
