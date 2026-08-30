#!/usr/bin/env bash
#
# Runs ON the target box (via scripts/deploy.sh over SSH -- don't invoke this
# by hand). Idempotent -- safe to re-run after a reboot, a mod update, or a
# changed tml.service.
#
# Generic Ubuntu/Linux only -- no cloud-provider assumptions, works
# unchanged on any host.
#
# Expects, already placed by scripts/deploy.sh before this runs:
#   ~/.local/share/Terraria/tModLoader/Mods/*.tmod + enabled.json
#   ~/tml/serverconfig.txt
#   /tmp/tml.service
#   /tmp/backup.cron
#
# Expects in the environment: TMODLOADER_VERSION, TMODLOADER_ZIP_URL

set -euo pipefail

: "${TMODLOADER_VERSION:?TMODLOADER_VERSION not set}"
: "${TMODLOADER_ZIP_URL:?TMODLOADER_ZIP_URL not set}"

export DEBIAN_FRONTEND=noninteractive

echo "== packages =="
sudo apt-get update -qq
# iptables-persistent is what provides netfilter-persistent; the Minimal
# image does not ship it. cron and nano are also missing on Minimal.
sudo apt-get install -y -qq \
  unzip screen curl libicu-dev cron nano iptables-persistent

echo "== tModLoader install (target v${TMODLOADER_VERSION}) =="
mkdir -p ~/tml
if [[ -x ~/tml/start-tModLoaderServer.sh ]]; then
  echo "  already installed, skipping download"
else
  tmp_zip="$(mktemp)"
  trap 'rm -f "$tmp_zip"' EXIT
  curl -fL "$TMODLOADER_ZIP_URL" -o "$tmp_zip"
  # Exclude serverconfig.txt -- the zip bundles its own generic example (all
  # settings commented out) at the same path, which would silently clobber
  # the one deploy.sh already templated and uploaded before this step runs.
  unzip -q -o "$tmp_zip" -d ~/tml -x serverconfig.txt
  chmod +x ~/tml/start-tModLoaderServer.sh ~/tml/LaunchUtils/*.sh
  rm -f "$tmp_zip"
  trap - EXIT
fi

echo "== host firewall (port 7777) =="
if sudo iptables -C INPUT -p tcp --dport 7777 -j ACCEPT 2>/dev/null; then
  echo "  ACCEPT rule already present, skipping"
else
  reject_line="$(sudo iptables -L INPUT -n --line-numbers | awk '/REJECT/{print $1; exit}')"
  if [[ -z "$reject_line" ]]; then
    sudo iptables -A INPUT -p tcp --dport 7777 -j ACCEPT
  else
    sudo iptables -I INPUT "$reject_line" -p tcp --dport 7777 -j ACCEPT
  fi
  sudo netfilter-persistent save
fi
echo "  reminder: your cloud provider's firewall/security-group rule for"
echo "  7777/tcp is a one-time console/CLI step and is NOT handled by this"
echo "  script."

echo "== systemd unit =="
sudo mv /tmp/tml.service /etc/systemd/system/tml.service
sudo systemctl daemon-reload
sudo systemctl enable --now tml
sudo systemctl restart tml

echo "== backups =="
mkdir -p ~/backups
# Drop any prior world-backup/prune lines (and the header comment) before
# re-adding, so reruns don't duplicate the crontab entries.
{ crontab -l 2>/dev/null | grep -vF -e 'Terraria/tModLoader/Worlds' -e 'find ~/backups' -e '# crontab -e on the server' || true; cat /tmp/backup.cron; } | crontab -
rm -f /tmp/backup.cron

echo "== done =="
sleep 2
sudo systemctl status tml --no-pager || true
