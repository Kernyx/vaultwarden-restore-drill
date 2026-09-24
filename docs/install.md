# Установка

Пока вручную — на этапе 6 это станет одной командой `make up`. Команды выполняются из корня репозитория.

## 1. VPS: скрипт экспорта

```bash
install -D -m 0755 vps/vw-backup-export ~/bin/vw-backup-export

# проверка: только список файлов в архиве, ничего не сохраняется
~/bin/vw-backup-export | tar -tzvf -
```

## 2. Pi: пользователь, ключ, конфиг, скрипт, юниты

```bash
# отдельный системный пользователь без входа и без sudo
sudo useradd --system --home-dir /var/lib/vaultwarden-backup --no-create-home \
     --shell /usr/sbin/nologin vwbackup
sudo install -d -o vwbackup -g vwbackup -m 0700 \
     /var/lib/vaultwarden-backup /var/lib/vaultwarden-backup/.ssh
sudo -u vwbackup ssh-keygen -t ed25519 -N "" -C vwbackup@raspberrypi \
     -f /var/lib/vaultwarden-backup/.ssh/id_ed25519

# ключ хоста VPS: скачать один раз и сверить отпечаток
# с тем, что показывает сам VPS (ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub)
ssh-keyscan -t ed25519 <vps-tailnet-ip> > /tmp/vps_hostkey
ssh-keygen -lf /tmp/vps_hostkey
sudo install -o vwbackup -g vwbackup -m 0600 /tmp/vps_hostkey \
     /var/lib/vaultwarden-backup/.ssh/known_hosts

# конфиг: адрес VPS не хранится в git
sudo install -d /etc/vaultwarden-backup
sudo install -o root -g vwbackup -m 0640 config/backup.env.example \
     /etc/vaultwarden-backup/backup.env
sudoedit /etc/vaultwarden-backup/backup.env

# скрипт (владелец root: vwbackup не может его изменить) и юниты
sudo install -D -m 0755 scripts/backup.sh /usr/local/lib/vaultwarden-backup/backup.sh
sudo install -m 0644 systemd/vaultwarden-backup.service systemd/vaultwarden-backup.timer \
     /etc/systemd/system/
sudo systemctl daemon-reload
```

## 3. VPS: разрешить ключ Pi

Добавить в `~/.ssh/authorized_keys` строку из [`vps/authorized_keys.example`](../vps/authorized_keys.example), подставив адрес Pi в tailnet (`tailscale ip -4` на Pi) и его публичный ключ (`/var/lib/vaultwarden-backup/.ssh/id_ed25519.pub`).

## 4. Pi: первый запуск и таймер

```bash
sudo systemctl start vaultwarden-backup.service
journalctl -u vaultwarden-backup.service -n 5     # ждём "backup ok: ..."
sudo systemctl enable --now vaultwarden-backup.timer
```
