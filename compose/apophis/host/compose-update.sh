#!/bin/bash
# Deploy/update every stack on this host.
#
# Install: cp host/compose-update.sh /usr/local/bin/compose-update
# Needs:   git (deploy key), sops (age key in /root/.config/sops/age/), docker
set -e
cd /srv/compose
git pull --ff-only
docker network create edge 2>/dev/null || true
for stack in compose/apophis/*/; do
  [ -f "$stack/compose.yaml" ] || continue
  cd "$stack"
  [ -f secrets.env ] && sops -d secrets.env > .env
  docker compose pull --quiet 2>/dev/null || true
  docker compose up -d --build
  cd - >/dev/null
done
docker exec caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || true
