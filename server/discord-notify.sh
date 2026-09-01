#!/usr/bin/env bash
#
# Tails the tModLoader server's journal and posts a Discord notification
# whenever a player joins or leaves. Started by discord-notify.service,
# which server-init.sh only enables if DISCORD_WEBHOOK_URL is set -- the
# notifier is opt-in.
#
# Reads the webhook URL from /home/ubuntu/tml/discord-webhook-url, uploaded
# by deploy.sh from DISCORD_WEBHOOK_URL in .env (not committed).

set -euo pipefail

webhook_file="/home/ubuntu/tml/discord-webhook-url"
if [[ ! -s "$webhook_file" ]]; then
  echo "discord-notify: DISCORD_WEBHOOK_URL not set, nothing to do"
  exit 0
fi
webhook_url="$(<"$webhook_file")"

# -n 0: don't replay old log lines, only notify on things that happen from
# now on.
journalctl -u tml -f -n 0 -o cat | while IFS= read -r line; do
  # tModLoader logs every event twice: once as a bare console line ("<player>
  # has joined."), once through its structured logger, prefixed with
  # "<Module>: [HH:MM:SS.fff] [Thread/Level] [Logger]: ". Skip the latter --
  # otherwise both match the patterns below and each join/leave fires twice,
  # with the second message's "player name" being the logger preamble.
  if [[ "$line" =~ ^[A-Za-z]+:\ \[ ]]; then
    continue
  fi
  if [[ "$line" =~ ^(.+)\ has\ joined\.$ ]]; then
    player="${BASH_REMATCH[1]}"
    emoji="⛏️"; verb="joined"
  elif [[ "$line" =~ ^(.+)\ has\ left\.$ ]]; then
    player="${BASH_REMATCH[1]}"
    emoji="🪦"; verb="left"
  else
    continue
  fi
  # Escape backslashes/quotes so the player name can't break the JSON payload.
  esc_player="${player//\\/\\\\}"
  esc_player="${esc_player//\"/\\\"}"
  payload="$(printf '{"content":"%s **%s** %s the server"}' "$emoji" "$esc_player" "$verb")"
  curl -fsS -H "Content-Type: application/json" -d "$payload" "$webhook_url" >/dev/null \
    || echo "discord-notify: failed to notify for ${player}" >&2
done
