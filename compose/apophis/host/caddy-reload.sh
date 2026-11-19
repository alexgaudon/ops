#!/bin/bash
# Run from the repo root after starting the public Caddy container.
set -euo pipefail
umask 077
cd compose/apophis/caddy

work=$(mktemp -d conf/.private-deploy.XXXXXXXX)
trap 'rm -f -- "$work/routes.caddy" "$work/Caddyfile" "$work/previous"; rmdir -- "$work"' EXIT
sops decrypt --input-type binary --output-type binary private.caddy > "$work/routes.caddy"

# Keep the candidate beside Caddy's live config, outside its active import glob.
# From the candidate directory, import only the freshly decrypted routes.
sed 's|^import private/\*\.caddy$|import routes.caddy|' conf/Caddyfile > "$work/Caddyfile"
grep -qx 'import routes.caddy' "$work/Caddyfile"
if ! docker exec caddy caddy validate --adapter caddyfile --config "/etc/caddy/${work#conf/}/Caddyfile" > /dev/null 2>&1; then
  echo 'Public Caddy candidate failed validation; active config unchanged.' >&2
  exit 1
fi

mkdir -p -m 700 conf/private
live=conf/private/routes.caddy
if [ -f "$live" ]; then cp -p -- "$live" "$work/previous"; fi
mv -- "$work/routes.caddy" "$live"
if ! docker exec caddy caddy reload --adapter caddyfile --config /etc/caddy/Caddyfile > /dev/null 2>&1; then
  if [ -f "$work/previous" ]; then
    mv -- "$work/previous" "$live"
  else
    rm -f -- "$live"
  fi
  echo 'Public Caddy rejected the reload; restored the previous route file.' >&2
  exit 1
fi
