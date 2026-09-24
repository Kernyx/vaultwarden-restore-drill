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

archive="${1:-${DRILL_ARCHIVE:-$SNAP_DIR/latest.tar.gz}}"

fail() { echo "DRILL FAILED: $*" >&2; exit 1; }
ms_since() { echo $(( ($(date +%s%N) - $1) / 1000000 )); }

t_start=$(date +%s%N)
mkdir -p "$DRILL_DIR"
work=$(mktemp -d "$DRILL_DIR/run.XXXXXX")
trap 'podman rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf -- "$work"' EXIT
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
podman run -d --name "$NAME" --replace --pull=missing \
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

# 5. Remember counts for the next drill and report.
printf 'CIPHERS=%s\nUSERS=%s\nBACKUP_CREATED_AT=%s\n' "$ciphers" "$users" "$created" > "$LAST"
echo "drill ok: backup from $created, Vaultwarden $version, users=$users," \
     "items=$ciphers, app up in ${app_ms} ms, total $(ms_since "$t_start") ms"
