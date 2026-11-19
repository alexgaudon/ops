#!/bin/bash
# Nightly backup for apophis - runtime state only.
#
# Everything else on this host is recoverable without a backup:
#   - compose definitions and sops-encrypted secrets are in the ops repo
#   - decrypted .env files are regenerated from secrets.env by compose-update
#   - ssh keys are re-applied by the 26.04 template's cloudinit
# The contract: if it is precious, it lives in a stack's data/ directory,
# and this script finds every one of those and nothing else.
#
# Install: cp host/backup.sh /root/backup.sh && chmod 700 /root/backup.sh
# Cron:    30 22 * * * /root/backup.sh >> /var/log/backup.log 2>&1

set -e
BACKUP_DIR="/mnt/backup/apophis.hosts.amgau.xyz"
FILENAME="backup_apophis_$(date +%F).tar.gz"

mkdir -p "$BACKUP_DIR"
cd /srv/compose

DATA_DIRS=$(find compose/apophis -mindepth 2 -maxdepth 2 -type d -name data)

if [ -z "$DATA_DIRS" ]; then
    echo "$(date '+%F %T') no data dirs found, refusing to write empty backup" >&2
    exit 1
fi

if tar czf "$BACKUP_DIR/$FILENAME" $DATA_DIRS; then
    echo "$(date '+%F %T') wrote $FILENAME ($(du -h "$BACKUP_DIR/$FILENAME" | cut -f1)): $DATA_DIRS"
else
    echo "$(date '+%F %T') FAILED to write $FILENAME" >&2
    exit 1
fi
