#!/usr/bin/env bash
# Run once now and through a TrueNAS POSTINIT task after boot/upgrades.
# Does not run Compose or modify services.
set -euo pipefail
target=/mnt/pool/ops/compose/agnes/host/compose-update.sh
bindir=/mnt/pool/ops-tools/bin
link=$bindir/compose-update
profile=/root/.bashrc
pathline='export PATH="/mnt/pool/ops-tools/bin:$PATH"'
[[ -x $target ]] || { echo 'Deployment helper is missing or not executable' >&2; exit 1; }
if [[ (-e $link || -L $link) && ! (-L $link && $(readlink "$link") = "$target") ]]; then
  echo 'Refusing to replace an unrelated compose-update command' >&2
  exit 1
fi
install -d -m 700 "$bindir"
if [[ ! -L $link ]]; then
  ln -s "$target" "$link"
fi
if ! grep -Fqx "$pathline" "$profile"; then
  printf '\n# Agnes deployment tools live on the persistent data pool.\n%s\n' "$pathline" >> "$profile"
fi
