#!/usr/bin/env bash
# Idempotent installation/update on the Pi. Run as root.
set -euo pipefail

src=${1:-/opt/vaultwarden-restore-drill}
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

if ! id vwbackup >/dev/null 2>&1; then
    useradd --system --home-dir /var/lib/vaultwarden-backup --no-create-home \
        --shell /usr/sbin/nologin vwbackup
fi
install -d -o vwbackup -g vwbackup -m 0700 \
    /var/lib/vaultwarden-backup /var/lib/vaultwarden-backup/.ssh
install -d -o root -g vwbackup -m 0775 /var/lib/node_exporter/textfile
install -d -o root -g vwbackup -m 0750 /etc/vaultwarden-backup

for required in backup.env telegram.env; do
    if [[ ! -s /etc/vaultwarden-backup/$required ]]; then
        echo "missing /etc/vaultwarden-backup/$required; see docs/install.md" >&2
        exit 1
    fi
done
for required in id_ed25519 known_hosts; do
    if [[ ! -s /var/lib/vaultwarden-backup/.ssh/$required ]]; then
        echo "missing backup SSH $required; see docs/install.md" >&2
        exit 1
    fi
done

install -d -m 0755 /usr/local/lib/vaultwarden-backup
install -m 0755 "$src"/scripts/{backup,restore-drill,notify-telegram}.sh \
    /usr/local/lib/vaultwarden-backup/
install -m 0644 "$src"/systemd/*.service "$src"/systemd/*.timer /etc/systemd/system/

monitoring=$src/monitoring
if [[ ! -f $monitoring/.env ]]; then
    password=$(head -c 24 /dev/urandom | base64 | tr -d '/+=')
    printf 'GF_SECURITY_ADMIN_PASSWORD=%s\n' "$password" > "$monitoring/.env"
    chmod 0600 "$monitoring/.env"
fi
"$monitoring/render-alertmanager-config.sh"

systemctl daemon-reload
systemctl enable --now vaultwarden-backup.timer vaultwarden-drill.timer
docker compose -f "$monitoring/compose.yaml" up -d --quiet-pull

echo "installed: backup 03:30, restore drill 04:00, monitoring on localhost"
