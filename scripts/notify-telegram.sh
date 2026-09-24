#!/usr/bin/env bash
# notify-telegram.sh <unit> - Telegram alert "<unit> failed" with the log
# lines of the failed run. Started by notify-telegram@.service, which other
# units reference via OnFailure=notify-telegram@%n.service.
set -euo pipefail

# For units started via OnFailure=, systemd itself says which unit failed,
# how, and the invocation ID of exactly that run (see systemd.exec(5)).
# The argument is only a fallback for manual runs.
unit="${MONITOR_UNIT:-${1:?usage: notify-telegram.sh <unit>}}"
result="${MONITOR_SERVICE_RESULT:-unknown}, exit status ${MONITOR_EXIT_STATUS:-?}"

# Settings come as a systemd credential (LoadCredential=): a private copy of
# /etc/vaultwarden-backup/telegram.env, readable only by this service run.
conf="${CREDENTIALS_DIRECTORY:?run me via notify-telegram@.service}/telegram.env"
get() { sed -n "s/^$1=//p" "$conf"; }
token=$(get TELEGRAM_BOT_TOKEN)
chat_id=$(get TELEGRAM_CHAT_ID)
proxy=$(get TELEGRAM_PROXY)
if [[ -z "$token" || -z "$chat_id" ]]; then
    echo "TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID is empty" >&2
    exit 1
fi

# Log lines of exactly the failed run: each run of a unit gets its own
# invocation ID, so lines of older runs do not end up in the message.
# (Not `systemctl show`: from a DynamicUser sandbox it cannot reach D-Bus.)
logs=""
if [[ -n "${MONITOR_INVOCATION_ID:-}" ]]; then
    logs=$(journalctl --no-pager -o cat _SYSTEMD_INVOCATION_ID="$MONITOR_INVOCATION_ID" | tail -n 10)
fi
if [[ -z "$logs" ]]; then
    logs=$(journalctl --no-pager -o cat -u "$unit" -n 10)
fi

text="❌ $unit failed ($result) on $(hostname), $(date '+%Y-%m-%d %H:%M %Z')

${logs:0:3000}"

# The token is part of the URL. URL and proxy go through a curl config file
# instead of argv, so the token does not show up in `ps` for other users.
cfg=$(mktemp)
trap 'rm -f -- "$cfg"' EXIT
printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$token" > "$cfg"
if [[ -n "$proxy" ]]; then
    printf 'proxy = "%s"\n' "$proxy" >> "$cfg"
fi

if ! resp=$(curl -sS --fail-with-body --max-time 30 --retry 3 --retry-all-errors \
                 -K "$cfg" --data-urlencode "chat_id=$chat_id" \
                 --data-urlencode "text=$text"); then
    echo "Telegram API error: $resp" >&2
    exit 1
fi
echo "alert sent for $unit"
