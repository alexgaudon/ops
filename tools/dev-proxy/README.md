# Dev proxy

Run this CLI on the Mac to publish a local dev server through Apophis at
`https://<name>.dev.misery.systems/`. Previews are reachable from the LAN and
over Tailscale, not from the public internet.

Use Node.js 22.9 or newer. Install dependencies with `npm ci` and install
`tmux` for `up` and `down`. Copy `.env.example` to `.env`, restrict it to mode
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

Set `PREVIEW_BACKEND=npm` to use the legacy Nginx Proxy Manager workflow with
the existing NPM credentials. The Apophis CLI only manages internal previews.
