# Monitoring on the Pi

Prerequisites: Docker Compose, the backup/drill scripts with textfile metrics,
and `/etc/vaultwarden-backup/telegram.env` already configured.
Deploy this directory to `/opt/vaultwarden-restore-drill/monitoring`.

```sh
cd /opt/vaultwarden-restore-drill/monitoring
sudo install -d -o root -g vwbackup -m 0775 /var/lib/node_exporter/textfile
sudo install -m 0600 .env.example .env
sudoedit .env
sudo ./render-alertmanager-config.sh
sudo docker compose up -d
```

Do not overwrite an existing `.env` during upgrades. The admin password is
used when Grafana creates its database; changing it later does not reset the
existing account. The dashboard is provisioned from JSON, with read-only
anonymous access through localhost. Tokens and rendered configs stay outside Git.

From your laptop:

```sh
ssh -N -L 13000:127.0.0.1:3000 rasp_ether
```

Open http://localhost:13000/d/vaultwarden-backups . No login is needed for viewing.
All four HTTP listeners bind to localhost. The tunnel requires your SSH key.

Metrics are scraped every 30 seconds. Stale backup/drill alerts fire after
26 hours without success, sustained for 5 minutes; Alertmanager waits another
30 seconds before sending a new group. Missing metrics wait 30 minutes.
The graphs show the last recorded result, not an event log of every run.

The live stale-backup test injected an additional, explicitly labelled metric
30 hours old. Prometheus became pending after 52 seconds, firing after 350
seconds, and Alertmanager reported a successful Telegram notification after
380 seconds. The injected file was removed after the test.

Limitations: if the Pi, Prometheus, or the local proxy goes down, this stack
cannot reliably alert about its own outage. An independent external heartbeat
monitor is needed for that case. Prometheus retention is 90 days; watch disk use.

Validation:

```sh
sudo docker compose exec prometheus promtool check config /etc/prometheus/prometheus.yml
sudo docker compose exec alertmanager amtool check-config /etc/alertmanager/alertmanager.yml
curl -fsS http://127.0.0.1:9090/api/v1/targets
curl -fsS http://127.0.0.1:9090/api/v1/alerts
```
