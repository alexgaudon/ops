#!/bin/bash
# Deploy/update every stack on this host.
#
# From the repo: install -m 755 compose/apophis/host/compose-update.sh /usr/local/bin/compose-update
# Needs:   git (deploy key), sops (age key in /root/.config/sops/age/), docker
set -e
case "$#:${1-}" in
  0:|1:--reload-caddy) ;;
  *) echo 'Usage: compose-update [--reload-caddy]' >&2; exit 2 ;;
esac
cd /srv/compose
git pull --ff-only
if [ "${1-}" = --reload-caddy ]; then
  exec bash compose/apophis/host/caddy-reload.sh
fi
docker network create edge 2>/dev/null || true
for stack in compose/apophis/*/; do
  [ -f "$stack/compose.yaml" ] || continue
  cd "$stack"
  [ -f secrets.env ] && sops -d secrets.env > .env
  docker compose pull --quiet 2>/dev/null || true
  docker compose up -d --build
  cd - >/dev/null
done
bash compose/apophis/host/caddy-reload.sh
