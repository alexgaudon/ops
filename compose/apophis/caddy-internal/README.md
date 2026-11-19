# Bazarr private proxy pilot

`conf/Caddyfile` holds global options and imports `conf/routes/*.caddy`.
`conf/routes/media.caddy` groups the four media apps and their shared LAN
access and TLS rules. Keep future generated dev-proxy config separate from
these tracked files and import it only on the internal listener.

`compose.pilot.yaml` isn't picked up by the normal Apophis deploy script.
Bazarr stays on Agnes at `10.0.0.5:6767`. Its new name is
`bazarr.internal.misery.systems`. Keep `bazarr.amgau.xyz` on NPM during the
transition. Only Bazarr is in scope.

The pilot is live at `https://bazarr.internal.misery.systems/`. Normal DNS
resolution and trusted HTTPS on `10.0.0.51:443` passed from the LAN, including
a phone check. Public Caddy binds only to `10.0.0.50` and does not serve Bazarr.
The old NPM route remains available. Off-LAN Tailscale access has not been
verified. For setup and verification:

1. Confirm that `10.0.0.51` is outside the DHCP pool and has no existing lease
   or reservation and is configured as a second LAN address on Apophis. Keep
   the public router forward unchanged. Ensure public Caddy is bound to
   `10.0.0.50` before starting internal Caddy on `443`. For an isolated test
   while public Caddy still binds all addresses, set `INTERNAL_CADDY_PORT=8443` and test with
   `curl --resolve bazarr.internal.misery.systems:8443:10.0.0.51 https://bazarr.internal.misery.systems:8443/`.
2. Supply a Cloudflare DNS token scoped to the `misery.systems` zone through SOPS,
   decrypting to a Git-ignored `.env` with mode `0600`. Use DNS-01 to issue the
   certificate, with no router forward to this listener.
3. Restrict the second IP with Docker-aware firewall rules and Tailscale policy.
   The Caddy LAN check is defense in depth. With Tailscale subnet-route SNAT,
   Caddy can see the subnet router's LAN address rather than the original
   client, so enforce tailnet access in Tailscale policy.
4. Test HTTPS from Wi-Fi and an approved tailnet client using `curl --resolve`
   before changing DNS. Confirm a denied client can't reach the backend, and
   verify the public listener doesn't serve Bazarr. Check IPv6 separately.
5. `terraform/dns.tf` manages the DNS-only Cloudflare wildcard
   `*.internal.misery.systems` → `10.0.0.51`. Public DNS can return this address,
   but clients still need LAN or approved Tailscale access to reach it.
   Each service needs an explicit Caddy route, not a separate DNS record.
   Keep the old name unchanged for rollback.
