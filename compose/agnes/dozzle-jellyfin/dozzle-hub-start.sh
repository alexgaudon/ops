#!/bin/sh
set -eu
cd /mnt/pool/ops/compose/agnes/dozzle-jellyfin
/usr/sbin/nft -f data/dozzle-hub.nft
docker compose up -d --pull never --wait --wait-timeout 60
