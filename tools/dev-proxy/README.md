# Dev proxy

Run this CLI on the Mac to publish a local dev server through Apophis at
`https://<name>.dev.misery.systems/`. Previews are reachable from the LAN and
over Tailscale, not from the public internet.

Use Node.js 22.9 or newer and install `tmux` for session management. There are
no npm dependencies. Copy `.env.example` to `.env`, restrict it to mode
`0600`, and set `PREVIEW_INTERNAL_TOKEN` for route creation and removal.
`list` and `status` do not need a token. Don't commit `.env`.

```sh
npm run up -- demo 3000 -- npm run dev -- --host 0.0.0.0 --port 3000
npm run list
npm run down -- demo
```

The server must listen on the Mac's LAN address or all interfaces. If it
validates hostnames, allow `.dev.misery.systems`. To register a server that is
already running, use `npm run add -- demo 3000`. `down` removes the Apophis route
and stops the matching tmux session. Routes expire after an hour by default.

## External previews

`up`, `add`, `down`, `remove`, `list`, and `status` remain internal-only. To
publish an already-running preview, use the separate `publish` command.
Before running it:

1. Serve only the preview build on a dedicated port on the Mac. Have an admin
   approve that exact `IP:port` in Apophis's `PREVIEW_EXTERNAL_TARGETS`.
2. The Mac CLI uses Apophis's publishing helper over its existing SSH access.
   The server-side credential never leaves Apophis. `npm run publish-check`
   verifies authentication without creating a route. For direct API clients,
   the CLI also accepts `PREVIEW_EXTERNAL_TOKEN` from the process environment.

```sh
npm run publish -- rockycoastmassage 3007 --ttl 604800
```

In an interactive terminal, the CLI shows the hostname, backend, and lifetime,
then prompts for the full external hostname. Agents and other non-interactive
callers must pass `--confirm <name>.preview.external.misery.systems` after an
explicit request to publish the preview externally. The flag checks the
intended hostname; it isn't proof of human approval. The registry separately
enforces the external token and destination allowlist.
The default lifetime is one hour and the maximum is seven days. `publish`
does not start a server or touch an internal route.

Get the per-preview login from the [external preview dashboard](https://preview-api.internal.misery.systems/?scope=external)
and share it privately with the recipient. The CLI prints the URL only, not
the login. For early revocation, use the registry's external DELETE endpoint.
