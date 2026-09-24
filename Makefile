SHELL := /usr/bin/env bash
PI_HOST ?= rasp_ether
VPS_HOST ?= vpsru
REMOTE_DIR := /opt/vaultwarden-restore-drill

.PHONY: up deploy-vps deploy-pi check status logs

up: deploy-vps deploy-pi check

deploy-vps:
	ssh $(VPS_HOST) 'install -d -m 0755 ~/bin'
	scp -q vps/vw-backup-export $(VPS_HOST):/tmp/vw-backup-export
	ssh $(VPS_HOST) 'install -m 0755 /tmp/vw-backup-export ~/bin/vw-backup-export && rm /tmp/vw-backup-export'

deploy-pi:
	ssh $(PI_HOST) 'sudo install -d -m 0755 $(REMOTE_DIR)'
	rsync -a --delete --rsync-path='sudo rsync' --exclude='.env' \
		scripts systemd config monitoring $(PI_HOST):$(REMOTE_DIR)/
	ssh $(PI_HOST) 'sudo $(REMOTE_DIR)/scripts/install-pi.sh $(REMOTE_DIR)'

check:
	ssh $(PI_HOST) 'sudo $(REMOTE_DIR)/scripts/check.sh'

status:
	ssh $(PI_HOST) 'systemctl list-timers vaultwarden-backup.timer vaultwarden-drill.timer --no-pager; sudo docker compose -f $(REMOTE_DIR)/monitoring/compose.yaml ps'

logs:
	ssh $(PI_HOST) 'journalctl -u vaultwarden-backup.service -u vaultwarden-drill.service -n 30 --no-pager'
