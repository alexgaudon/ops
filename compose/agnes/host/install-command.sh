#!/usr/bin/env bash
# Run once now and through a TrueNAS POSTINIT task after boot/upgrades.
# Does not run Compose or modify services.
set -euo pipefail
target=/mnt/pool/ops/compose/agnes/host/compose-update.sh
link=/usr/local/bin/compose-update
[[ -x $target ]] || { echo 'Deployment helper is missing or not executable' >&2; exit 1; }
if [[ -L $link && $(readlink "$link") = "$target" ]]; then
  exit 0
fi
if [[ -e $link || -L $link ]]; then
  echo 'Refusing to replace an unrelated compose-update command' >&2
  exit 1
fi
ln -s "$target" "$link"
