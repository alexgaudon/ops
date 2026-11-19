5# Preview proxy pilot

The Python registry stores short-lived routes in SQLite. Caddy looks up the
route on each new request and proxies directly to its target. Creating or
deleting a route does not need a Caddy reload. Neither Python container publishes
a host port or mounts the Docker socket.

| Scope | Returned hostname | Access |
| --- | --- | --- |
| `internal` (default) | `<name>.dev.misery.systems` | Internal Caddy, restricted to approved networks |
| `external` (opt-in) | `<name>.external.misery.systems` | Public Caddy, with per-preview Basic Auth |

## API

Send `POST /v1/routes` to `https://preview-api.dev.misery.systems` with a bearer
token for the requested scope. For example, after deploying the pilot:

```sh
curl --fail-with-body https://preview-api.dev.misery.systems/v1/routes \
  -H "Authorization: Bearer $PREVIEW_INTERNAL_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"name":"demo","ip":"10.0.0.49","port":3000}'
```

The response contains the HTTPS `url` and `expires_at` (Unix seconds). External
registration also returns the generated `basic_auth` credentials once; store them
separately from the URL. Caddy strips those credentials before proxying to the app.
Names are unique within a scope until deleted or expired. The default TTL is one
hour; set `ttl_seconds` from 60 to 86400. Delete with
`DELETE /v1/routes/<scope>/<name>` using the same scope's token. Expiry and deletion
block new requests; they do not close an already-open stream.

## Rollout

1. Prepare SOPS-encrypted API credentials. The pilot requires a random internal
   token. The default target policy allows only the Mac on ports `3000–3999`;
   otherwise configure exact `IP:port` or `IP:start-end` entries. Leave the
   external token and target allowlist unset for the first run. Do not allow
   management interfaces, shared infrastructure, or an entire subnet.
2. Start explicitly with `docker compose -f compose.pilot.yaml up -d --build`.
   The normal Apophis updater skips this pilot. Attach only internal Caddy to
   `preview-control`; attach Caddy instances serving previews to `preview-lookup`.
   Persist the network attachments in each Caddy Compose definition before relying
   on the setup. Never attach public Caddy to `preview-control`.
3. The internal pilot uses `compose.preview.yaml` alongside `compose.pilot.yaml`
   in the internal Caddy stack. Its checked-in route only allows source IPs in
   `10.0.0.0/24`; verify which source IP Caddy sees over Tailscale before changing
   that policy. OpenTofu points `*.dev.misery.systems` at `10.0.0.51`. Keep the
   existing NPM previews until the new route works on all intended networks.
4. Opt into external previews separately. Set a distinct external token, an
   exact allowlist of public-preview backends, and the labels of all protected
   static routes in `PREVIEW_RESERVED_EXTERNAL` without committing those labels
   in plaintext. Add the preview handler only as the final fallback in the
   existing encrypted public wildcard site. Verify that the static routes retain
   their original policy and that a new preview cannot be opened without its
   generated login. Remove the fallback to turn off all dynamic public routes.

The disposable demo backends and routes are not part of the deployment. After
removing them, set the internal target policy to an approved, running backend
before registering a new preview. Dynamic public publishing remains disabled
until explicitly configured.
