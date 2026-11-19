#!/bin/bash
# Deploy/update every stack on this host.
#
# From the repo: install -m 755 compose/apophis/host/compose-update.sh /usr/local/bin/compose-update
# Needs:   git (deploy key), sops (age key in /root/.config/sops/age/), docker
set -e
case "$#:${1-}" in
  0:|1:--reload-caddy|1:--previews) ;;
  *) echo 'Usage: compose-update [--reload-caddy|--previews]' >&2; exit 2 ;;
esac
cd /srv/compose
git pull --ff-only
if [ "${1-}" = --reload-caddy ]; then
  exec bash compose/apophis/host/caddy-reload.sh
fi
docker network create edge 2>/dev/null || true
umask 077

deploy_stack() (
  cd "$1"
  if [ -f secrets.env ]; then
    tmp=$(mktemp .env.XXXXXXXX)
    trap 'rm -f -- "$tmp"' EXIT
    sops -d secrets.env > "$tmp"
    mv -- "$tmp" .env
  fi
  docker compose pull --quiet 2>/dev/null || true
  docker compose up -d --build
)

# Caddy attaches to networks created by the registry stack.
deploy_stack compose/apophis/preview-proxy
if [ "${1-}" = --previews ]; then
  deploy_stack compose/apophis/caddy-internal
  deploy_stack compose/apophis/caddy
  exec bash compose/apophis/host/caddy-reload.sh
fi
for stack in compose/apophis/*/; do
  [ -f "$stack/compose.yaml" ] || continue
  [ "$stack" != compose/apophis/preview-proxy/ ] || continue
  deploy_stack "$stack"
done
bash compose/apophis/host/caddy-reload.sh
