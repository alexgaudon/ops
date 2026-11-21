#!/bin/bash
set -euo pipefail
umask 077

mount=/mnt/backup
dest=$mount/apophis.hosts.amgau.xyz/tallyo
[[ $(findmnt -rn -M "$mount" -o SOURCE,FSTYPE) =~ ^10\.0\.0\.5:/mnt/pool/backup[[:space:]]+nfs4?$ ]] || {
    echo 'Agnes backup export is not mounted' >&2
    exit 1
}
install -d -m 700 "$dest"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
work=$(mktemp "$dest/.tallyo-dump.XXXXXXXX")
trap 'rm -f -- "$work"' EXIT

docker exec tallyo-postgres-prod sh -ec 'exec pg_dump -Fc -U "$POSTGRES_USER" -d "$POSTGRES_DB"' |
    age -r age1gn9rqrgxqwkhs2ggpn6tp9yk22rtwczn2j5rxuxcrd2muea09afqnryz0y \
        -r age12ghzgz7n3nefdj98x643yu4lccjcyv09zvx6mvav9qwwm0flpg5qrc0e3h > "$work"
test -s "$work"
sync -f "$work"
mv -T -- "$work" "$dest/tallyo-$stamp.dump.age"
echo "Tallyo backup saved: tallyo-$stamp.dump.age"

# Only prune this job's completed archives, and only after a new success.
find "$dest" -maxdepth 1 -type f -regextype posix-extended \
    -regex '.*/tallyo-[0-9]{8}T[0-9]{6}Z\.dump\.age' -mmin +30240 -delete
