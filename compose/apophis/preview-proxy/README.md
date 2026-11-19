# Preview proxy

The Python registry stores short-lived routes in SQLite. Caddy looks up the
route on each new request and proxies directly to its target. Creating or
deleting a route does not need a Caddy reload. Neither Python container publishes
a host port or mounts the Docker socket.

| Scope | Returned hostname | Access |
| --- | --- | --- |
| `internal` (default) | `<name>.dev.misery.systems` | Internal Caddy, restricted to approved networks |
| `external` (opt-in) | `<name>.preview.external.misery.systems` | Public Caddy, with per-preview Basic Auth |

## API

Send `POST /v1/routes` to `https://preview-api.internal.misery.systems` with a
bearer token for the requested scope:

```sh
curl --fail-with-body https://preview-api.internal.misery.systems/v1/routes \
  -H "Authorization: Bearer $PREVIEW_INTERNAL_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"name":"demo","ip":"10.0.0.49","port":3000}'
```

The response contains the HTTPS `url` and `expires_at` (Unix seconds). External
registration also returns `basic_auth` credentials. Caddy strips those
credentials before proxying to the app.
Names are unique within a scope until deleted or expired. The default TTL is one
hour; set `ttl_seconds` from 60 to 86400. Delete with
`DELETE /v1/routes/<scope>/<name>` using the same scope's token. Expiry and deletion
block new requests; they do not close an already-open stream.

Long-lived internal routes can be pinned with `PREVIEW_PINNED_INTERNAL` in the
registry Compose configuration. Pinned targets must still be allowlisted. They
appear with `expires_at: null` and are changed by redeploying the configuration,
not by API registration or deletion.

On the LAN, `GET /` shows the preview dashboard and `GET /v1/routes` lists the
same active previews as JSON. Neither requires a token. External credentials
are behind “Show login” on the dashboard and in `basic_auth` in JSON. Pass `?scope=internal` or
`?scope=external` to filter. Creation and deletion still require a token, and
external previews still require their login. Listing responses aren't cacheable.
Passwords aren't stored in plaintext. Routes created before listing was added,
or before the current external token was set, may show `basic_auth: null`;
recreate the route if you need a retrievable password.

## Deploy and configure

The Apophis updater starts the registry before Caddy. Only internal Caddy joins
the management network. Each proxy has its own lookup network and service.
Use `sudo compose-update --previews` to deploy just the registry and both Caddy
stacks without updating the other applications.

API tokens are SOPS-encrypted. The default internal target is the Mac on ports
`3000–3999`, plus the existing dev-server ports `4321`, `30400`, `40004`, and
`40005`. Internal requests must have a source IP in `10.0.0.0/24` as seen by
Caddy. Verify the source observed over Tailscale before changing this policy.

External previews use their own DNS wildcard and TLS site. To permit publishing,
set `PREVIEW_EXTERNAL_TARGETS` to an exact list of approved `IP:port` pairs in the
encrypted environment and redeploy the registry. An empty list denies all public
destinations. Use only ports dedicated to previews, never management interfaces.
