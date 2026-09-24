#!/usr/bin/env bash
# Verify the installed services and configs on the Pi. Run as root.
set -euo pipefail

root=/opt/vaultwarden-restore-drill
monitoring=$root/monitoring

shellcheck "$root"/scripts/*.sh "$root"/monitoring/render-alertmanager-config.sh
systemd-analyze verify "$root"/systemd/*.service "$root"/systemd/*.timer
docker run --rm -v "$monitoring/prometheus:/etc/prometheus:ro" \
    --entrypoint promtool prom/prometheus:v3.14.0 \
    check config /etc/prometheus/prometheus.yml
docker run --rm -v "$monitoring/prometheus:/etc/prometheus:ro" \
    -w /etc/prometheus --entrypoint promtool prom/prometheus:v3.14.0 \
    test rules rules.test.yml
docker run --rm -v /etc/vaultwarden-backup/alertmanager:/etc/alertmanager:ro \
    --entrypoint amtool prom/alertmanager:v0.34.1 \
    check-config /etc/alertmanager/alertmanager.yml

for unit in vaultwarden-backup.timer vaultwarden-drill.timer; do
    systemctl is-enabled --quiet "$unit" || { echo "$unit is disabled" >&2; exit 1; }
done
for port in 3000 9090 9093 9100; do
    ss -ltnH | grep -q "127.0.0.1:$port " || { echo "localhost:$port is not listening" >&2; exit 1; }
done

for endpoint in \
    http://127.0.0.1:3000/api/health \
    http://127.0.0.1:9090/-/healthy \
    http://127.0.0.1:9093/-/healthy \
    http://127.0.0.1:9100/metrics; do
    curl -fsS --max-time 5 "$endpoint" >/dev/null
done

echo "all checks passed"
