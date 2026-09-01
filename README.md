# terraria-server

Reproducible setup for a modded Terraria (tModLoader) server on any Ubuntu
24.04 box reachable by SSH. Everything below is generic — it works for any
tModLoader mod list and for any host (a cheap VPS, a spare machine, a
free-tier cloud instance). Your mod list, versions, and any
deployment-specific gotchas live in `.env` and `NOTES.md` (both
git-ignored, see [Layout](#layout)) — nothing here assumes a particular
modpack.

This repo assumes you already have a box and its IP/SSH access in hand.
Getting the box itself is a separate step — see
[Getting a server](#getting-a-server) below.

## Layout

```
.env.example               Config for the scripts below; copy to .env (git-ignored)
NOTES.md                    Optional: your own deployment-specific notes (git-ignored, not committed)
scripts/
  deploy.sh                 Run from your machine, pushes everything to SERVER_HOST — idempotent
  server-init.sh            Runs ON the server itself, invoked by deploy.sh over SSH — don't run standalone
server/
  serverconfig.txt.example  Templated by deploy.sh (world name + password substituted)
  tml.service               systemd unit, deployed by deploy.sh
  discord-notify.sh         Tails server logs, posts join/leave events to Discord
  discord-notify.service    systemd unit for the above, deployed by deploy.sh
  backup.cron               World backup schedule, deployed by deploy.sh
```

## Getting a server

Any Ubuntu 24.04 box reachable by SSH works — a paid VPS, a spare machine,
or a free-tier cloud instance. Provisioning one is a separate concern from
deploying to it, so it's deliberately out of scope here: if your provider
needs its own tooling (capacity retries, quota/sizing choices, idle-instance
reclamation rules), keep that outside this repo. Once you have a box and SSH
access to it, its IP becomes `SERVER_HOST` below.

## Prerequisites

On the machine you'll run `deploy.sh` from (a Linux box or WSL2 — not the
server itself):

- **`ssh`, `scp`, `ssh-keygen`** — already present on any Linux box or WSL2.
- **Steam + tModLoader on the game client** — needed for the mod-gathering
  step below; not needed on the server itself.

## Getting the `.env` values

```bash
cp .env.example .env
ssh-keygen -t ed25519 -f ~/.ssh/terraria-server.key -C terraria-server -N ""
```

| Variable | How to get it |
|---|---|
| `SERVER_HOST` | `user@ip` of your box — see [Getting a server](#getting-a-server) above |
| `SSH_PRIVATE_KEY_FILE` | The keypair from `ssh-keygen` above (its public half must be authorized on the server) |
| `TMOD_STAGING_DIR`, `TMODLOADER_VERSION`, `TMODLOADER_ZIP_URL`, `WORLD_NAME`, `SERVER_PASSWORD`, `ENABLED_MODS`, `CLIENT_ONLY_MODS` | Your own choices, see [Mods](#mods) below |
| `DISCORD_WEBHOOK_URL` | Optional -- see [Discord join/leave notifications](#discord-joinleave-notifications) below |

## Quick start

```bash
# fill in SERVER_HOST=ubuntu@<ip> and a real SERVER_PASSWORD in .env, then:
./scripts/deploy.sh       # packages, tModLoader, mods, firewall, systemd, cron
```

Then gather mods on the client and hand them to the server (see
[Mods](#mods) below), and open the cloud-side firewall (see
[Firewall](#firewall) below) — those two are not automated. After that:
tModLoader → Multiplayer → Join via IP → the server's public IP, port `7777`.

`deploy.sh` is idempotent — re-run it any time to pick up a mod update, a
`serverconfig.txt.example` change, or a `tml.service` edit.

## Mods

Two kinds of tModLoader mods, handled differently:

- **Server-side mods** run on both the server and every player's client, in
  identical versions. List their *internal* names — not Workshop display
  names, check the actual `.tmod` filename — in `ENABLED_MODS` (`.env`,
  space-separated); `deploy.sh` generates `enabled.json` from it. Version
  mismatches, not firewall issues, are the most common cause of "can't
  connect" once the server is up.
- **Client-only ("NoSync") mods** — QoL/UI mods like health bar overlays or
  minimap tweaks — never go on the server and don't need matching versions.
  List their `.tmod` filenames in `CLIENT_ONLY_MODS` (`.env`,
  space-separated); `deploy.sh` refuses to run if one turns up in staging, so
  it can't reach the server by accident.

Two gotchas:

- A mod pinned to a specific tModLoader branch (a total-conversion mod, say)
  should be installed through the in-game mod browser at your target
  tModLoader version, not picked by hand from its release page — a
  hand-picked mismatch is what produces "mod needs to be upgraded to match
  the current tModLoader version."
- Enable every server-side mod you want before generating the world you'll
  actually play — adding one mid-playthrough is usually fine, removing one
  can corrupt saves.

### Gathering mods (manual — not automated)

Steam Workshop mods aren't in the normal
`Documents/My Games/Terraria/tModLoader/Mods/` folder — that only holds
mods installed through tModLoader's in-game browser. Workshop mods live
under the Steam library instead, at
`steamapps/workshop/content/1281930/<workshop-id>/<version>/*.tmod`
(Windows default:
`C:\Program Files (x86)\Steam\steamapps\workshop\content\1281930\`).

Subscribe to everything you want, launch tModLoader once so Steam downloads
it, then copy every `.tmod` — Workshop and in-game-browser installs alike —
into `../tmod-staging/` (sibling of this repo, git-ignored;
`TMOD_STAGING_DIR` in `.env` points at it). If a mod has several version
subfolders, take the highest-numbered one.

```powershell
# Windows PowerShell
mkdir $HOME\tmod-staging
Get-ChildItem "C:\Program Files (x86)\Steam\steamapps\workshop\content\1281930" `
  -Recurse -Filter *.tmod | Copy-Item -Destination $HOME\tmod-staging
```

```bash
# Linux/macOS
find ~/.steam/steam/steamapps/workshop/content/1281930 -name '*.tmod' \
  -exec cp {} ../tmod-staging/ \;
```

Once staging holds everything, `./scripts/deploy.sh` handles the rest: `scp`
to the server, plus generating `enabled.json` from `ENABLED_MODS`.

**Why not `steamcmd` server-side instead:** auto-syncing would let a client
silently diverge if they skip an update — worse than today's mismatch, which
at least fails loudly as a rejected connection — and needs headless Steam
login for a task that runs a handful of times a year. tModLoader also pushes
the server's mods to joining clients automatically, so staging is a speed
optimization, not a requirement.

## Firewall

This is where most setups fail. Opening only one layer leaves the port
closed.

**Cloud side (manual, not automated):** whatever firewall/security-group
layer your provider puts in front of the box — allow ingress on TCP `7777`
from `0.0.0.0/0`. `deploy.sh` deliberately doesn't touch this: blind-editing
an existing rule set via CLI risks clobbering unrelated rules already on it,
so it's a one-time console (or careful CLI) step per instance, specific to
whichever provider you're using.

**Host side:** `deploy.sh` handles this — Ubuntu cloud images commonly ship
a REJECT rule in `iptables INPUT`, and the ACCEPT for 7777 has to land
*above* it (the line number varies by image; inserting below it silently
does nothing). It also installs `iptables-persistent` so the rule survives a
reboot — Minimal images don't ship it.

Port 7777 is open to `0.0.0.0/0`, so bots will find it — `serverconfig.txt`'s
password is not optional.

## What `deploy.sh` handles for you

- **Packages**: `unzip screen curl libicu-dev cron nano iptables-persistent`.
  `libicu-dev` is the one people miss — .NET won't start without it. `cron`
  and `nano` are also absent on the Minimal image.
- **tModLoader install**: downloads and unpacks `TMODLOADER_VERSION` if not
  already present (idempotent — safe to re-run).
- **World generation**: `serverconfig.txt.example` sets `worldname` and
  `autocreate` so the server generates its world non-interactively on first
  start under systemd — no attached console needed, unlike a manual
  `./start-tModLoaderServer.sh` first run.
- **systemd unit**: installs `server/tml.service`, `daemon-reload`,
  `enable --now`.
- **Backups**: `server/backup.cron` — world copied every 6h to `~/backups`,
  pruned after 14 days. Same-disk backups don't protect against instance
  loss; push copies to off-box object storage or pull them to your own
  machine periodically. Every other decision here is reversible — losing the
  world isn't.
- **Discord notifications**: if `DISCORD_WEBHOOK_URL` is set, installs and
  enables `discord-notify.service`; if it's empty, disables that service.
  See [Discord join/leave notifications](#discord-joinleave-notifications).

## Discord join/leave notifications

Optional — posts a message to a Discord channel whenever a player joins or
leaves.

1. In Discord: channel Settings → Integrations → Webhooks → New Webhook,
   copy its URL.
2. Set `DISCORD_WEBHOOK_URL` in `.env` to that URL.
3. `./scripts/deploy.sh`.

`discord-notify.service` tails `journalctl -u tml` for the server's own
`<player> has joined.` / `<player> has left.` console lines and posts them to
the webhook — nothing runs inside the game or needs a mod. Leave
`DISCORD_WEBHOOK_URL` empty to disable it; `deploy.sh` disables the service
on the next run if you clear the value later.

## Troubleshooting

| Symptom | Most likely cause |
|---|---|
| SSH permission denied | Log in as `ubuntu`, not `root` |
| Client hangs on "Connecting" | Host-side iptables — check the 7777 ACCEPT rule is *above* the REJECT (`sudo iptables -L INPUT -n --line-numbers`) |
| Server won't start, .NET error | Missing `libicu-dev` — re-run `deploy.sh` |
| "Different version" on join | tModLoader (or another version-pinned mod) mismatch — see [Mods](#mods) |
| `scp`/staging has nothing in it | Looking in the manual Mods folder instead of the Steam workshop path — see [Mods](#mods) |
| `deploy.sh` refuses to run | Check its error: usually a `CLIENT_ONLY_MODS` entry found in staging, or `SERVER_PASSWORD` still `CHANGE_ME` |
| Mod missing in-game | Wrong internal name in `ENABLED_MODS` |
| Can't get a box in the first place | See [Getting a server](#getting-a-server) — not something `deploy.sh` handles |

## What is deliberately not in here

- **Secrets.** SSH keys, the server password. See `.gitignore`.
- **`.tmod` files.** They can be large, and redistributing other people's
  Workshop mods isn't yours to do. tModLoader sends the server's mods to
  joining clients automatically, so players don't need them in advance
  anyway.
- **World saves.** Backed up off-box, not versioned here.
- **Provisioning a server.** Getting a box in the first place (cloud
  console/CLI, capacity retries, sizing/cost tradeoffs) is a different
  problem from deploying to one you already have — see
  [Getting a server](#getting-a-server).

## If doing this again elsewhere or with different mods

Everything in this repo works against any Ubuntu 24.04 box reachable by
SSH — just set `SERVER_HOST` and run `deploy.sh`. Nothing here assumes a
particular provider.

Swapping mods is even simpler: edit `ENABLED_MODS` and `CLIENT_ONLY_MODS` in
`.env`, re-stage `TMOD_STAGING_DIR`, and re-run `deploy.sh`. Nothing else in
this repo assumes a particular mod list.
