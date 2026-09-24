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
: "${METRICS_DIR:=/var/lib/node_exporter/textfile}"   # node_exporter textfile collector

STATE_DIR="${STATE_DIRECTORY:-/var/lib/vaultwarden-backup}"   # set by systemd
SNAP_DIR="$STATE_DIR/snapshots"

fail() { echo "ERROR: $*" >&2; exit 1; }

# Metrics for Prometheus. Written to a temp file and renamed, so
# node_exporter never reads a half-written file.
metrics() {
    local f="$METRICS_DIR/vaultwarden_$1.prom"
    cat > "$f.tmp" && chmod 0644 "$f.tmp" && mv "$f.tmp" "$f"
}
# Written on every run, success or not: the dashboard shows the history.
run_metrics() {
    metrics backup_run <<EOF
# HELP vaultwarden_backup_last_run_timestamp_seconds When the backup job last ran.
# TYPE vaultwarden_backup_last_run_timestamp_seconds gauge
vaultwarden_backup_last_run_timestamp_seconds $(date +%s)
# HELP vaultwarden_backup_last_run_success 1 if the last backup run succeeded, 0 if it failed.
# TYPE vaultwarden_backup_last_run_success gauge
vaultwarden_backup_last_run_success $(( $1 == 0 ? 1 : 0 ))
EOF
}

t_start=$(date +%s%N)
mkdir -p "$SNAP_DIR"
ts=$(date -u +%Y-%m-%dT%H%M%SZ)
partial="$SNAP_DIR/.partial-$ts.tar.gz"
work=$(mktemp -d)
on_exit() {
    local rc=$?
    rm -rf -- "$work" "$partial"
    run_metrics "$rc"
    exit "$rc"
}
trap on_exit EXIT

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

# 5. Success metrics. Only written here, so a failed run keeps the time of
#    the last good backup - that is what the "backup is stale" alert watches.
ms=$(( ($(date +%s%N) - t_start) / 1000000 ))
metrics backup_success <<EOF
# HELP vaultwarden_backup_last_success_timestamp_seconds When the last verified backup was stored.
# TYPE vaultwarden_backup_last_success_timestamp_seconds gauge
vaultwarden_backup_last_success_timestamp_seconds $(date +%s)
# HELP vaultwarden_backup_duration_seconds How long the last successful backup took.
# TYPE vaultwarden_backup_duration_seconds gauge
vaultwarden_backup_duration_seconds $((ms / 1000)).$(printf '%03d' $((ms % 1000)))
# HELP vaultwarden_backup_size_bytes Size of the last verified backup archive.
# TYPE vaultwarden_backup_size_bytes gauge
vaultwarden_backup_size_bytes $(stat -c %s "$SNAP_DIR/$ts.tar.gz")
# HELP vaultwarden_backup_snapshots Number of stored snapshots.
# TYPE vaultwarden_backup_snapshots gauge
vaultwarden_backup_snapshots $(find "$SNAP_DIR" -maxdepth 1 -type f -name '20*.tar.gz' | wc -l)
EOF

echo "backup ok: $ts.tar.gz, $(du -h "$SNAP_DIR/$ts.tar.gz" | cut -f1)," \
     "Vaultwarden $(sed -n 's/^VW_VERSION=//p' "$work/manifest.env"), ${ms} ms"
