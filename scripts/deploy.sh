#!/usr/bin/env bash
#
# Takes a bare Ubuntu 24.04 box, on any host reachable by SSH, to a running
# tModLoader server with whatever mods are staged in TMOD_STAGING_DIR and
# listed in ENABLED_MODS (.env): mods, enabled.json, serverconfig.txt,
# systemd unit, backup cron, host firewall.
#
# Idempotent -- safe to re-run, e.g. after a mod update or a serverconfig.txt
# change. Requires nothing provider-specific; only .env values and SSH.
#
# One thing this does NOT do: your cloud provider's firewall/security-group
# rule for 7777 is a one-time console/CLI step, not scriptable here without
# risking clobbering unrelated existing rules on someone's default rule set.
# See README.md "Firewall — two layers".

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ -f "$ROOT/.env" ]]; then
  # shellcheck disable=SC1090
  source "$ROOT/.env"
fi

: "${SERVER_HOST:?Set SERVER_HOST=user@ip in .env}"
: "${SSH_PRIVATE_KEY_FILE:?Set SSH_PRIVATE_KEY_FILE in .env}"
: "${TMOD_STAGING_DIR:?Set TMOD_STAGING_DIR in .env}"
: "${TMODLOADER_VERSION:?Set TMODLOADER_VERSION in .env}"
: "${TMODLOADER_ZIP_URL:?Set TMODLOADER_ZIP_URL in .env}"
: "${WORLD_NAME:?Set WORLD_NAME in .env}"
: "${SERVER_PASSWORD:?Set SERVER_PASSWORD in .env}"
: "${WORLD_SIZE:?Set WORLD_SIZE in .env}"
: "${WORLD_DIFFICULTY:?Set WORLD_DIFFICULTY in .env}"
: "${MAX_PLAYERS:?Set MAX_PLAYERS in .env}"
CLIENT_ONLY_MODS="${CLIENT_ONLY_MODS:-}"
ENABLED_MODS="${ENABLED_MODS:-}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"

if [[ "$SERVER_PASSWORD" == "CHANGE_ME" ]]; then
  echo "ERROR: SERVER_PASSWORD is still the placeholder. Set a real one in .env." >&2
  exit 1
fi

if [[ ! "$WORLD_SIZE" =~ ^[123]$ ]]; then
  echo "ERROR: WORLD_SIZE must be 1 (small), 2 (medium), or 3 (large)." >&2
  exit 1
fi

if [[ ! "$WORLD_DIFFICULTY" =~ ^[0123]$ ]]; then
  echo "ERROR: WORLD_DIFFICULTY must be 0 (normal), 1 (expert), 2 (master)," \
       "or 3 (journey)." >&2
  exit 1
fi

if [[ ! "$MAX_PLAYERS" =~ ^[0-9]+$ ]] || (( MAX_PLAYERS < 1 || MAX_PLAYERS > 255 )); then
  echo "ERROR: MAX_PLAYERS must be a number between 1 and 255." >&2
  exit 1
fi

if [[ ! -f "$SSH_PRIVATE_KEY_FILE" ]]; then
  echo "ERROR: SSH private key not found at $SSH_PRIVATE_KEY_FILE" >&2
  exit 1
fi

# TMOD_STAGING_DIR is conventionally "../tmod-staging" (sibling of the repo);
# resolve relative paths against the repo root so this works regardless of
# the caller's cwd.
if [[ "$TMOD_STAGING_DIR" != /* ]]; then
  TMOD_STAGING_DIR="$ROOT/$TMOD_STAGING_DIR"
fi

SSH=(ssh -i "$SSH_PRIVATE_KEY_FILE" -o StrictHostKeyChecking=accept-new)
SCP=(scp -i "$SSH_PRIVATE_KEY_FILE" -o StrictHostKeyChecking=accept-new)

# Uploads $1 (content, e.g. a secret or a generated config) to $2 (remote
# path) via a local temp file. mktemp files are created mode 600, and -p
# preserves that mode across the copy, so a secret like the Discord webhook
# URL never sits at a default/world-readable mode on the remote host even
# mid-transfer.
upload_content() {
  local content="$1" dest="$2" tmp
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN
  # No forced trailing newline: an empty $content (e.g. DISCORD_WEBHOOK_URL
  # unset) must produce a genuinely empty 0-byte file, since server-init.sh
  # and discord-notify.sh both gate on `[[ -s file ]]` to detect "unset".
  printf '%s' "$content" > "$tmp"
  "${SCP[@]}" -p "$tmp" "$SERVER_HOST:$dest"
}

echo "== verifying tmod-staging =="
shopt -s nullglob
tmods=("$TMOD_STAGING_DIR"/*.tmod)
shopt -u nullglob
if [[ ${#tmods[@]} -eq 0 ]]; then
  echo "ERROR: no .tmod files in $TMOD_STAGING_DIR" >&2
  exit 1
fi
for f in "${tmods[@]}"; do
  name="$(basename "$f")"
  for bad in $CLIENT_ONLY_MODS; do
    if [[ "$name" == "$bad" ]]; then
      echo "ERROR: $name is in staging -- it's listed in CLIENT_ONLY_MODS" \
           "(.env) as client-side/NoSync and must never be deployed to the" \
           "server. Remove it and re-run." >&2
      exit 1
    fi
  done
done
echo "  ${#tmods[@]} mod file(s), no client-only mods present -- OK"

echo "== mods =="
"${SSH[@]}" "$SERVER_HOST" 'mkdir -p ~/.local/share/Terraria/tModLoader/Mods'
"${SCP[@]}" "${tmods[@]}" "$SERVER_HOST:~/.local/share/Terraria/tModLoader/Mods/"

enabled_json="$(
  echo "["
  first=1
  for mod in $ENABLED_MODS; do
    [[ $first -eq 1 ]] && first=0 || echo ","
    printf '  "%s"' "$mod"
  done
  echo
  echo "]"
)"
upload_content "$enabled_json" "~/.local/share/Terraria/tModLoader/Mods/enabled.json"

echo "== serverconfig.txt =="
# Escape sed's delimiter/backreference/escape characters so a WORLD_NAME or
# SERVER_PASSWORD containing '/', '&', or '\' can't corrupt the substitution.
esc_world="$(printf '%s' "$WORLD_NAME" | sed -e 's/[\/&\\]/\\&/g')"
esc_password="$(printf '%s' "$SERVER_PASSWORD" | sed -e 's/[\/&\\]/\\&/g')"
cfg_content="$(sed -e "s/YourWorld/${esc_world}/g" \
    -e "s/CHANGE_ME/${esc_password}/g" \
    -e "s/MAXPLAYERS_PLACEHOLDER/${MAX_PLAYERS}/g" \
    -e "s/WORLDSIZE_PLACEHOLDER/${WORLD_SIZE}/g" \
    -e "s/WORLDDIFFICULTY_PLACEHOLDER/${WORLD_DIFFICULTY}/g" \
    "$ROOT/server/serverconfig.txt.example")"
"${SSH[@]}" "$SERVER_HOST" 'mkdir -p ~/tml'
upload_content "$cfg_content" "~/tml/serverconfig.txt"

echo "== discord webhook =="
upload_content "$DISCORD_WEBHOOK_URL" "~/tml/discord-webhook-url"
"${SCP[@]}" "$ROOT/server/discord-notify.sh" "$SERVER_HOST:~/tml/discord-notify.sh"
"${SSH[@]}" "$SERVER_HOST" 'chmod +x ~/tml/discord-notify.sh'
if [[ -z "$DISCORD_WEBHOOK_URL" ]]; then
  echo "  DISCORD_WEBHOOK_URL not set in .env -- notifier will stay disabled"
fi

echo "== staging systemd unit + backup cron =="
"${SCP[@]}" "$ROOT/server/tml.service" "$SERVER_HOST:/tmp/tml.service"
"${SCP[@]}" "$ROOT/server/discord-notify.service" "$SERVER_HOST:/tmp/discord-notify.service"
"${SCP[@]}" "$ROOT/server/backup.cron" "$SERVER_HOST:/tmp/backup.cron"

echo "== remote setup (packages, tModLoader, firewall, systemd, cron) =="
"${SCP[@]}" "$ROOT/scripts/server-init.sh" "$SERVER_HOST:/tmp/server-init.sh"
"${SSH[@]}" "$SERVER_HOST" \
  "chmod +x /tmp/server-init.sh && TMODLOADER_VERSION='$TMODLOADER_VERSION' TMODLOADER_ZIP_URL='$TMODLOADER_ZIP_URL' /tmp/server-init.sh"

echo
echo "Done. Remaining manual steps: your cloud provider's firewall rule for"
echo "7777/tcp, and gathering mods on the client if you haven't already --"
echo "see README.md."
echo
echo "Tail server logs with:"
echo "  ssh -i $SSH_PRIVATE_KEY_FILE $SERVER_HOST 'sudo journalctl -u tml -f'"
