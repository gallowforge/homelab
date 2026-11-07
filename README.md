# Raspberry Pi homelab

One Raspberry Pi 5 runs a household's DNS, password vault, notes sync, smart home and
monitoring. Every hand-written piece of its configuration lives in git, host files
included, and a script proves the live machine still matches the repo. An always-on
Claude Code session works as the on-call operator, bound by a written charter.

This is a public copy of the private repo that runs the Pi. It has been sanitized, and
some services are left out (see [What this copy leaves out](#what-this-copy-leaves-out)).

## Architecture

```mermaid
flowchart LR
  subgraph home["Home LAN 192.168.1.0/24"]
    clients["Phones, laptops,<br/>TV, Apple TV"]
    router["Router<br/>DHCP + DNS redirect"]
    subgraph pi["Raspberry Pi 5 · 192.168.1.10"]
      adguard["AdGuard Home<br/>DNS :53"]
      caddy["Caddy<br/>TLS :8443-8453"]
      apps["Vaultwarden · CouchDB<br/>Home Assistant · Syncthing<br/>Uptime Kuma · Dockge"]
      jobs["systemd timers<br/>backup · health · heartbeat<br/>restore drill"]
      agent["Claude Code<br/>caretaker session"]
    end
  end
  remote["Devices away<br/>from home"]
  internet(("Internet"))
  ntfy["ntfy.sh<br/>push to phone"]
  hc["healthchecks.io<br/>dead-man switch"]
  pc["Desktop PC<br/>LUKS disk"]
  mac["MacBook"]

  clients -- "DNS" --> adguard
  router -. "redirects all DNS to the Pi" .-> adguard
  clients -- "HTTPS, tailnet cert" --> caddy
  remote -- "Tailscale (WireGuard)" --> caddy
  caddy --> apps
  adguard -- "DoH upstreams" --> internet
  jobs -- "deduped alerts" --> ntfy
  jobs -- "ping every 5 min" --> hc
  jobs -. "alert wakes" .-> agent
  jobs -- "nightly archives,<br/>pulled by the PC" --> pc
  jobs -- "push when awake" --> mac
  pc -- "Syncthing, no secrets" --> mac
```

## By the numbers

Figures are from the live Pi's repo and runbooks as of November 2026.

- **15 containers** on one Pi 5 (8 GB). 9 of them are in this copy.
- **20 systemd timers** for homelab jobs, **0 cron jobs**. 13 of the timers are in this copy.
- **12 backup sets** every night at 05:00, about 2.5 minutes for all of them. Each archive
  is verified before anything older is pruned. Copies live on **3 machines**.
- **Weekly restore drill**, Sunday 05:45: the newest archive of every set is unpacked
  into RAM and checked against live data. About 10 seconds.
- **Daily health check**: 21 alert categories, 77 distinct alert conditions. They cover
  what an HTTP monitor cannot see.
- **13 Uptime Kuma monitors**, every 60 seconds.
- **External dead-man switch**: a heartbeat every 5 minutes. healthchecks.io alerts after
  20 minutes of silence.
- **376 commits** since the repo started on 2026-09-17.
- **About 1,900 lines** of top-level runbooks and charter, 1,900 lines of per-stack notes,
  and a 1,000-line operating journal.
- **Rebuild target**: 2-3 hours from bare hardware, plus the vault re-sync in the
  background. The data sets were rehearsed end to end on another machine in about
  10 minutes.

## Services

| Service | What it does | How it is reached |
|---|---|---|
| AdGuard Home | DNS and ad blocking for every device in the house | `:53`; web UI through Caddy `:8445` |
| Caddy | The only TLS front door. One port per site, tailnet certificate | `:8443-8453` |
| Vaultwarden | Bitwarden-compatible password server | Caddy `:8452` only, no host port |
| CouchDB | Obsidian LiveSync backend | Caddy `:8450` only, no host port |
| Home Assistant | Home automation, HomeKit bridges, Hue scenes, TV picture mode | Caddy `:8443`; LAN `:8123` for phone shortcuts |
| Syncthing | Replicates a 65 GB personal vault to the PC and the MacBook | GUI through Caddy `:8453` |
| Uptime Kuma | Endpoint monitors, alerts through ntfy | Caddy `:8446` only, no host port |
| Dockge | Web UI for the compose stacks. Holds `docker.sock` | Caddy `:8444` only, no host port |
| Watchtower | The only automatic updater, with tiers and a cooldown | none |
| HyperHDR + tv-mood | Hue lamps follow the TV picture | host services, see [docs/tv-ambient-lighting.md](docs/tv-ambient-lighting.md) |
| Claude Code | Always-on operator session | host service, see [docs/ai-operator.md](docs/ai-operator.md) |

Host: Raspberry Pi OS Lite 64-bit (Debian 12), Docker CE with Compose, Tailscale. The root
filesystem is on a USB flash stick. That shapes many decisions below.

## Design decisions

### Tailscale instead of port forwarding
The ISP puts the house behind CGNAT and gives no IPv6, so port forwarding is not an
option. Tailscale gives every device a WireGuard path to the Pi from anywhere. Caddy serves
the tailnet's own certificate (`tailscale cert`, renewed weekly, Caddy reloaded with
`--force` because the config text never changes on renewal).

At home the same links work without Tailscale. AdGuard rewrites the Pi's tailnet name to its
LAN address, and the certificate is valid for that name. One set of bookmarks works
everywhere.

### A small, fixed public surface
Nothing on the router is forwarded. The live Pi publishes exactly one name to the internet
through Tailscale Funnel, for a service that is not part of this copy. The rule is written
down: no new public names, no new open ports.

Plaintext ports were closed when Caddy took over: Vaultwarden `:8222`, Uptime Kuma
`:3001`, Dockge `:5001` and CouchDB `:5984` have no host port at all. AdGuard's and
Syncthing's admin UIs still listen for Caddy but ufw denies them to the LAN.

### Closing Docker's ufw bypass
Docker publishes ports with DNAT in the FORWARD chain, so ufw's INPUT rules never see that
traffic. A port that looks firewalled is open. [`_host/etc/ufw/after.rules`](_host/etc/ufw/after.rules)
fills the `DOCKER-USER` chain at every ufw reload: new connections that arrive on `eth0`
from outside the LAN are dropped. The LAN, the tailnet and container-to-container traffic
are untouched.

Containers reaching the host are limited too. ufw admits only DNS and three host-network
ports (AdGuard UI, Home Assistant, Syncthing GUI) from Docker networks. Anything else a
container tries shows up as a `[UFW BLOCK]` line.

### No fallback DNS, on purpose
The router hands out the Pi as the only resolver and redirects queries for any other
resolver to it. That makes the Pi a single point of failure for house DNS, and it is a
deliberate choice. A second resolver was tried: Apple devices raced both, got NXDOMAIN for
the tailnet name from the public one, and lost every local link.

The risk is managed instead of spread:
- AdGuard uses parallel DoH upstreams with fallback servers given by IP.
- AdGuard and Vaultwarden run with `oom_score_adj: -500`.
- Uptime Kuma queries DNS every 60 s, and the health check sends an urgent push if
  `127.0.0.1:53` stops answering.
- Watchtower recreates one container at a time, so an AdGuard update costs about 2 s of
  DNS.

### Backups are verified before anything is pruned
A backup engine that deletes old archives after writing a broken new one is worse than no
engine. [`homelab-backup`](_host/usr/local/sbin/homelab-backup) reads one list,
[`backups.conf`](_host/etc/homelab/backups.conf). It takes SQLite copies with the online
backup API, runs `PRAGMA quick_check`, checks a row count and checks that the required
members are in the finished archive. Only then does it prune older archives, and it never
prunes the newest three. A failed set keeps everything it had and sends one push.

`forbid` rules fail any set that would carry a `.env` or key file to the laptop. Details:
[docs/backups-and-restore.md](docs/backups-and-restore.md).

### The repo is the source of truth, and drift is checked
Host files live under [`_host/`](_host) at their live paths.
[`MANIFEST`](_host/MANIFEST) lists each one with its mode, owner and what to do after a
change. [`install.sh`](_host/install.sh) has four modes:

- **diff** (default): compares every entry with the live system and ends with
  `RESULT: no drift` or a list of differences.
- **`--apply`**: installs with `install(1)` and keeps the old file. It refuses to run while
  `_host/` has uncommitted changes, so the repo always says what is installed.
- **`--pull`**: copies a file that a tool rewrote (ufw rewrites `user.rules`) back into the repo.
- **`--bootstrap`**: on a rebuilt host, creates the Docker `proxy` network and enables every
  timer in the MANIFEST.

It also reports files in homelab locations that the MANIFEST does not know, and timers that
are installed but not enabled. The daily health check runs the same comparison, so drift
becomes a push instead of a surprise. A pre-commit hook refuses commits that look like they
contain a secret.

### Updates in tiers, after the backup
Watchtower is the only updater. It runs at 05:30, after the verified 05:00 backup, only
for containers labelled for it. It applies an image only once that image is more than
3 days old, one container at a time, waiting for each to become healthy. Image tags track
major lines (`caddy:2`, `couchdb:3.5`), so a new major version never arrives by itself.

Vaultwarden is the exception: it publishes only `:latest`. The health check reads its
GitHub releases and warns the first morning a new major version appears, before the
cooldown ends.

A container can be excluded by name. The live Pi does this for a Tailscale sidecar whose
restart withdraws a public DNS name for up to 18 minutes.

### Written for a flash stick
The root disk is a USB flash stick that loses recent writes on an abrupt reset. So:

- Scratch data and high-frequency state live in RAM: `/run`, `/dev/shm`, zram swap.
- The journal is capped, and chatty units log at `notice`.
- The health check alerts on more than 20 GiB/day of writes and on the USB link
  dropping to USB 2 speed.
- The hardware watchdog is deliberately not armed. A watchdog reset is an abrupt reset,
  and that costs data here.

### One switch for planned work
`sudo touch /run/homelab/maintenance` before stopping containers. While the flag exists,
the AdGuard pin and the network probe skip their runs, alerts do not wake the caretaker,
and the heartbeat gate ignores Uptime Kuma's state. `/run` is emptied at boot, so a
forgotten flag cannot outlive a reboot.

## How a change is made

1. Edit the file in the repo (host files: the copy under `_host/`).
2. `git commit`. The pre-commit hook blocks known secret patterns and prints only
   `file:line` and the rule name.
3. `sudo _host/install.sh` shows the diff against the live system;
   `sudo _host/install.sh --apply` installs it.
4. Verify from a client's point of view, then `sudo homelab-health.sh --dry-run` must end
   with `all healthy`, and `sudo _host/install.sh` with `RESULT: no drift`.

## Repository layout

```
.
├── adguard/                 DNS: compose file, self-healing rewrite pin (pin-update.sh)
├── caddy/                   TLS front door: compose file, Caddyfile
├── couchdb/                 Obsidian LiveSync backend
├── dockge/                  compose UI
├── homeassistant/           compose file, YAML config, Hue scenes, TV picture mode
├── syncthing/               vault replication
├── uptime-kuma/             endpoint monitors
├── vaultwarden/             password server
├── watchtower/              tiered updater
├── _host/                   host files, stored at their live paths
│   ├── MANIFEST             every host file: mode, owner, follow-up after a change
│   ├── install.sh           diff, apply, pull, bootstrap
│   ├── etc/                 docker, ufw, fail2ban, journald, sysctl, tmpfiles,
│   │                        systemd units, the backup list
│   ├── usr/local/           backup engine, health check, notifier, heartbeat gate,
│   │                        netprobe, caretaker scripts, tv-mood
│   ├── backup-restore-test.sh   the weekly restore drill
│   ├── watchdog-tests.sh        stubbed tests for the notifier and netprobe
│   └── git-hooks/pre-commit     refuses secrets
└── docs/
    ├── backups-and-restore.md
    ├── monitoring-and-alerts.md
    ├── ai-operator.md
    └── tv-ambient-lighting.md
```

Each stack keeps its secrets in a `.env` file (mode 600, never tracked); the `.env.example`
next to it lists the variable names. Host scripts read `/etc/homelab/secrets.env`; its
names are in [`secrets.env.example`](_host/etc/homelab/secrets.env.example).

## What this copy leaves out

The live repo is private. This copy differs in three ways:

- **Services removed.** A media stack, its public Funnel endpoint, a watch-history tracker
  and their watchdogs and timers are not here. Neither are scripts that reach into other
  personal machines or data. Where a kept script had checks for those services, the checks
  were removed and the script was re-validated.
- **Values replaced.** LAN addresses use `192.168.1.x` (the Pi is `192.168.1.10`), tailnet
  addresses use `100.64.0.x`, and the tailnet is `example-tailnet.ts.net`. Device IDs, MAC
  addresses and a session ID are placeholders.
- **Private documents rewritten.** The runbooks, the caretaker charter and the journal stay
  private. The files in [`docs/`](docs) are condensed public versions.

Validation of this copy: `bash -n` on every shell script, `py_compile` on every Python file,
a YAML parse of every compose and Home Assistant file, `homelab-backup --check-config` on the
backup list, and the stubbed test suite (43 checks, all passing).

## License

[MIT](LICENSE)
