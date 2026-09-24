#!/usr/bin/env bash
# restore-drill.sh [archive] - proves that a backup can actually be restored:
# unpacks it, checks the database, starts the same Vaultwarden version on the
# restored data in a throwaway container with no network and waits until the
# app answers /alive. Any failed check -> non-zero exit -> Telegram alert.
#
# Runs as root (rootful Podman) from vaultwarden-drill.service. Without an
# argument it takes the newest verified snapshot made by backup.sh.
set -euo pipefail

SNAP_DIR=/var/lib/vaultwarden-backup/snapshots
DRILL_DIR="${STATE_DIRECTORY:-/var/lib/vaultwarden-drill}"   # set by systemd
LAST="$DRILL_DIR/last.env"       # counts from the last successful drill
IMAGE_REPO="${DRILL_IMAGE_REPO:-docker.io/vaultwarden/server}"
MIN_CIPHERS_PERCENT=80           # fewer items than 80% of last time = alarm
NAME=vaultwarden-restore-drill
METRICS_DIR="${METRICS_DIR:-/var/lib/node_exporter/textfile}"   # node_exporter textfile collector

archive="${1:-${DRILL_ARCHIVE:-$SNAP_DIR/latest.tar.gz}}"

fail() { echo "DRILL FAILED: $*" >&2; exit 1; }
ms_since() { echo $(( ($(date +%s%N) - $1) / 1000000 )); }
secs() { printf '%d.%03d' $(($1 / 1000)) $(($1 % 1000)); }   # ms -> seconds

# Metrics for Prometheus, written atomically (temp file + rename).
metrics() {
    local f="$METRICS_DIR/vaultwarden_$1.prom"
    cat > "$f.tmp" && chmod 0644 "$f.tmp" && mv "$f.tmp" "$f"
}
# Written on every run, success or not: the dashboard shows the history.
run_metrics() {
    metrics drill_run <<EOF
# HELP vaultwarden_drill_last_run_timestamp_seconds When the restore drill last ran.
# TYPE vaultwarden_drill_last_run_timestamp_seconds gauge
vaultwarden_drill_last_run_timestamp_seconds $(date +%s)
# HELP vaultwarden_drill_last_run_success 1 if the last restore drill passed, 0 if it failed.
# TYPE vaultwarden_drill_last_run_success gauge
vaultwarden_drill_last_run_success $(( $1 == 0 ? 1 : 0 ))
EOF
}

t_start=$(date +%s%N)
mkdir -p "$DRILL_DIR"
work=$(mktemp -d "$DRILL_DIR/run.XXXXXX")
on_exit() {
    local rc=$?
    podman rm -f "$NAME" >/dev/null 2>&1 || true
    rm -rf -- "$work"
    run_metrics "$rc"
    exit "$rc"
}
trap on_exit EXIT
trap 'exit 1' HUP INT TERM

# 1. Unpack into an empty dir. Layout made by vw-backup-export:
#    db.sqlite3, manifest.env, rsa_key.pem, attachments/
[[ -r "$archive" ]] || fail "no archive: $archive"
tar -xzf "$archive" -C "$work" --no-same-owner || fail "cannot unpack $archive"
version=$(sed -n 's/^VW_VERSION=//p' "$work/manifest.env")
created=$(sed -n 's/^CREATED_AT=//p' "$work/manifest.env")
[[ "$version" =~ ^[0-9]+(\.[0-9]+)+$ ]] || fail "bad VW_VERSION in manifest: '$version'"

# 2. Database: intact, not empty, and not much smaller than last time.
#    A sudden drop is what a wiped or encrypted vault looks like.
db="$work/db.sqlite3"
check=$(sqlite3 "$db" 'PRAGMA integrity_check;' 2>&1) || fail "sqlite3: $check"
[[ "$check" == "ok" ]] || fail "integrity_check: $check"
users=$(sqlite3 "$db" 'SELECT COUNT(*) FROM users;')
ciphers=$(sqlite3 "$db" 'SELECT COUNT(*) FROM ciphers;')
(( users > 0 && ciphers > 0 )) || fail "empty vault: users=$users ciphers=$ciphers"
if [[ -r "$LAST" ]]; then
    prev=$(sed -n 's/^CIPHERS=//p' "$LAST")
    (( ciphers * 100 >= prev * MIN_CIPHERS_PERCENT )) ||
        fail "items dropped from $prev to $ciphers (delete $LAST if that was on purpose)"
fi

# 3. Start the same Vaultwarden version on the restored data, locked down:
#    no network (cannot send mail or reach anything), read-only root fs,
#    no capabilities, unprivileged user inside.
mkdir "$work/data"
mv "$db" "$work/rsa_key.pem" "$work/data/"
if [[ -d "$work/attachments" ]]; then
    mv "$work/attachments" "$work/data/"
fi
chown -R 65534:65534 "$work/data"

t_app=$(date +%s%N)
# --log-driver k8s-file: app output stays in a file (podman logs still works)
# instead of flooding the system journal every night.
podman run -d --name "$NAME" --replace --pull=missing --log-driver k8s-file \
    --network none --read-only --tmpfs /tmp \
    --cap-drop all --security-opt no-new-privileges --user 65534:65534 \
    -e ROCKET_PORT=8080 -v "$work/data:/data" \
    "$IMAGE_REPO:$version" >/dev/null

# 4. Wait for /alive, checked inside the container by the image's own
#    healthcheck script (the container has no network to check from outside).
healthy=false
for _ in $(seq 1 120); do
    if podman exec "$NAME" /healthcheck.sh >/dev/null 2>&1; then
        healthy=true
        break
    fi
    [[ "$(podman inspect -f '{{.State.Running}}' "$NAME")" == true ]] || break
    sleep 0.5
done
app_ms=$(ms_since "$t_app")
if [[ "$healthy" != true ]]; then
    podman logs --tail 15 "$NAME" >&2 || true
    fail "Vaultwarden $version did not come up on the restored data"
fi

# 5. Remember counts for the next drill, export metrics and report.
printf 'CIPHERS=%s\nUSERS=%s\nBACKUP_CREATED_AT=%s\n' "$ciphers" "$users" "$created" > "$LAST"
total_ms=$(ms_since "$t_start")
metrics drill_success <<EOF
# HELP vaultwarden_drill_last_success_timestamp_seconds When a restore drill last passed.
# TYPE vaultwarden_drill_last_success_timestamp_seconds gauge
vaultwarden_drill_last_success_timestamp_seconds $(date +%s)
# HELP vaultwarden_drill_duration_seconds Whole restore: unpack, checks, app up (our RTO on a warm host).
# TYPE vaultwarden_drill_duration_seconds gauge
vaultwarden_drill_duration_seconds $(secs "$total_ms")
# HELP vaultwarden_drill_app_start_seconds From container start to the first answer on /alive.
# TYPE vaultwarden_drill_app_start_seconds gauge
vaultwarden_drill_app_start_seconds $(secs "$app_ms")
# HELP vaultwarden_drill_items Vault items (ciphers) in the restored backup.
# TYPE vaultwarden_drill_items gauge
vaultwarden_drill_items $ciphers
# HELP vaultwarden_drill_users Users in the restored backup.
# TYPE vaultwarden_drill_users gauge
vaultwarden_drill_users $users
# HELP vaultwarden_drill_backup_age_seconds How old the restored backup was at drill time.
# TYPE vaultwarden_drill_backup_age_seconds gauge
vaultwarden_drill_backup_age_seconds $(( $(date +%s) - $(date -d "$created" +%s) ))
EOF
echo "drill ok: backup from $created, Vaultwarden $version, users=$users," \
     "items=$ciphers, app up in ${app_ms} ms, total ${total_ms} ms"
