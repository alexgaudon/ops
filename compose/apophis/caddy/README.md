# Encrypted edge routes

`private.caddy` is a whole-file SOPS document. The public Caddyfile imports
only the decrypted runtime copy. The reload helper validates the combined
configuration before installing the mode-0600 copy and reloading public Caddy.
Never stage the generated copy or log the adapted configuration.
On Apophis, run `sudo compose-update --reload-caddy` to pull and reload the
public proxy without pulling images or recreating the other stacks.

These routes use public ingress. Encryption keeps route details out of readable
Git; it does not restrict requests. Require both the existing source-IP allowlist
and Basic Auth before proxying. Match the direct peer (`remote_ip`), not a
client-supplied forwarding header. Check the observed peer on the live WAN path
before publishing the DNS wildcard. Use a DNS-01 wildcard certificate so the
individual hostnames do not appear in public certificate transparency logs.

Before enabling a route, verify that an unlisted IP receives 403 even with valid
credentials, an allowed IP receives 401 without valid credentials, and both
checks passing reaches the intended upstream. Keep the legacy proxy unchanged
until these checks pass. Edit the encrypted source with `sops edit --input-type
binary --output-type binary private.caddy` from this directory.
