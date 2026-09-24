#!/usr/bin/env bash
# backup.sh - runs on the Pi as the unprivileged "vwbackup" user
# (see systemd/vaultwarden-backup.service).
#
# Pulls a backup archive from the VPS over SSH, verifies it and only then
# stores it as snapshots/<UTC time>.tar.gz. A failed run leaves nothing
# behind, so every file in snapshots/ is a verified backup.
set -euo pipefail

: "${VPS_HOST:?set it in /etc/vaultwarden-backup/backup.env}"
: "${VPS_USER:?set it in /etc/vaultwarden-backup/backup.env}"
: "${KEEP_DAYS:=30}"

STATE_DIR="${STATE_DIRECTORY:-/var/lib/vaultwarden-backup}"   # set by systemd
SNAP_DIR="$STATE_DIR/snapshots"

fail() { echo "ERROR: $*" >&2; exit 1; }

mkdir -p "$SNAP_DIR"
ts=$(date -u +%Y-%m-%dT%H%M%SZ)
partial="$SNAP_DIR/.partial-$ts.tar.gz"
work=$(mktemp -d)
trap 'rm -rf -- "$work" "$partial"' EXIT

# 1. Pull. The key's forced command on the VPS (vps/vw-backup-export)
#    ignores what we ask for and streams a tar.gz to stdout. -T: no terminal.
ssh -T -i "$STATE_DIR/.ssh/id_ed25519" -o IdentitiesOnly=yes -o BatchMode=yes \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$STATE_DIR/.ssh/known_hosts" \
    -o ConnectTimeout=20 -o ServerAliveInterval=15 \
    "$VPS_USER@$VPS_HOST" > "$partial"

# 2. Verify before accepting.
gzip -t "$partial"             || fail "archive is not valid gzip"
tar -xzf "$partial" -C "$work" || fail "cannot unpack archive"
for f in db.sqlite3 manifest.env rsa_key.pem; do
    [[ -s "$work/$f" ]] || fail "archive has no $f"
done
check=$(sqlite3 "$work/db.sqlite3" 'PRAGMA integrity_check;' 2>&1) || fail "sqlite3: $check"
[[ "$check" == "ok" ]] || fail "integrity_check: $check"

# 3. Accept. rename(2) is atomic: snapshots/ never holds a half-written file.
#    latest.tar.gz is swapped the same way (ln -sf alone would unlink first).
mv "$partial" "$SNAP_DIR/$ts.tar.gz"
ln -sfn "$ts.tar.gz" "$SNAP_DIR/.latest.tmp"
mv -T "$SNAP_DIR/.latest.tmp" "$SNAP_DIR/latest.tar.gz"

# 4. Retention. It runs only after a verified backup, so it can never
#    delete the last good one.
find "$SNAP_DIR" -maxdepth 1 -type f -name '20*.tar.gz' -mtime +"$KEEP_DAYS" -print -delete
find "$SNAP_DIR" -maxdepth 1 -type f -name '.partial-*' -mmin +60 -print -delete

echo "backup ok: $ts.tar.gz, $(du -h "$SNAP_DIR/$ts.tar.gz" | cut -f1)," \
     "Vaultwarden $(sed -n 's/^VW_VERSION=//p' "$work/manifest.env")"
