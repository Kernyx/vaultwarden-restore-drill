#!/bin/bash

set -e

SERVER="vpsru"
REMOTE_DIR="/home/deploy/vaultwarden/vw-data"
BACKUP_ROOT="$HOME/backups/vaultwarden"
SSH_KEY="$HOME/.ssh/id_ed25519"

DATE=$(date +"%Y-%m-%d_%H-%M")
NEW_BACKUP="$BACKUP_ROOT/$DATE"
LATEST="$BACKUP_ROOT/latest"

mkdir -p "$BACKUP_ROOT"
mkdir -p "$NEW_BACKUP"

if [ -d "$LATEST" ]; then
    LAST_BACKUP=$(stat -c %Y "$LATEST")
    NOW=$(date +%s)
    DIFF=$(( (NOW - LAST_BACKUP) / 3600 ))
    if [ "$DIFF" -lt 20 ]; then
        echo "Last backup was ${DIFF}h ago, skipping"
        exit 0
    fi
fi

echo "Starting Vaultwarden backup: $DATE"

# если есть previous backup — используем hardlinks
if [ -d "$LATEST" ]; then
    rsync -a --delete \
        --link-dest="$LATEST" \
        -e "ssh -i $SSH_KEY" \
        $SERVER:$REMOTE_DIR \
        "$NEW_BACKUP"
else
    rsync -a \
        -e "ssh -i $SSH_KEY" \
        $SERVER:$REMOTE_DIR \
        "$NEW_BACKUP"
fi

# обновляем latest symlink
rm -f "$LATEST"
ln -s "$NEW_BACKUP" "$LATEST"

# удалить backup старше 30 дней
find "$BACKUP_ROOT" -maxdepth 1 -type d -mtime +30 -exec rm -rf {} \;

echo "Backup completed"
