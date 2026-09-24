#!/usr/bin/env bash
# render-alertmanager-config.sh - builds Alertmanager's config and bot token
# file from /etc/vaultwarden-backup/telegram.env (the same settings the
# systemd notifier uses), so the chat id and the token never go into git.
# Run as root on the Pi.
set -euo pipefail

SRC=/etc/vaultwarden-backup/telegram.env
OUT=/etc/vaultwarden-backup/alertmanager
TEMPLATE="$(dirname "$0")/alertmanager/alertmanager.yml.tmpl"

get() { sed -n "s/^$1=//p" "$SRC"; }
chat_id=$(get TELEGRAM_CHAT_ID)
token=$(get TELEGRAM_BOT_TOKEN)
proxy=$(get TELEGRAM_PROXY)
if [[ ! "$chat_id" =~ ^-?[0-9]+$ || -z "$token" ]]; then
    echo "fill in TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID in $SRC first" >&2
    exit 1
fi

# Alertmanager runs as nobody:nogroup - it may read these files, others may not.
install -d -o root -g nogroup -m 0750 "$OUT"
printf '%s' "$token" | install -o root -g nogroup -m 0440 /dev/stdin "$OUT/telegram_bot_token"
# Go's HTTP client takes socks5:// (it passes host names to the proxy anyway).
sed -e "s|@TELEGRAM_CHAT_ID@|$chat_id|" \
    -e "s|@TELEGRAM_PROXY_URL@|${proxy/socks5h:/socks5:}|" \
    "$TEMPLATE" | install -o root -g nogroup -m 0440 /dev/stdin "$OUT/alertmanager.yml"
echo "rendered $OUT/alertmanager.yml"
