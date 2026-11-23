#!/bin/bash
# Run from the caddy-internal stack directory, with the container running.
set -euo pipefail
umask 077

route=conf/routes/tibia.caddy
work=$(mktemp -d conf/routes/.private-deploy.XXXXXXXX)
trap 'rm -f -- "$work/route" "$work/previous"; rmdir -- "$work"' EXIT
# The shared secret also contains public routes. Only materialize the lines
# marked for internal Caddy; the public Caddyfile treats them as comments.
sops decrypt --input-type binary --output-type binary ../caddy/private.caddy |
  sed -n 's/^# internal: //p' > "$work/route"
if [ ! -s "$work/route" ]; then
  echo 'No internal routes found in the shared Caddy secret.' >&2
  exit 1
fi
if cmp -s "$work/route" "$route"; then exit 0; fi

if [ -f "$route" ]; then cp -p -- "$route" "$work/previous"; fi
# The container needs to read the route, but it is never tracked in Git.
chmod 644 "$work/route"
mv -- "$work/route" "$route"
restore_route() {
  if [ -f "$work/previous" ]; then
    mv -- "$work/previous" "$route"
  else
    rm -f -- "$route"
  fi
}
if ! docker compose exec -T caddy caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile > /dev/null 2>&1; then
  restore_route
  echo 'Internal Caddy rejected the private route; restored the previous config.' >&2
  exit 1
fi
# Internal Caddy has its admin API disabled.
if ! docker compose restart caddy; then
  restore_route
  docker compose restart caddy
  exit 1
fi
