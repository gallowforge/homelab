# Design decisions

Why the Pi is built the way it is. Each section names the constraint, the choice and what it costs. The goals these choices serve, in priority order, are in the [README](../README.md#goals-in-priority-order).

## Tailscale instead of port forwarding
The ISP puts the house behind CGNAT and gives no IPv6, so port forwarding is not an
option. Tailscale gives every device a WireGuard path to the Pi from anywhere. Caddy serves
the tailnet's own certificate (`tailscale cert`, renewed weekly, Caddy reloaded with
`--force` because the config text never changes on renewal).

At home the same links work without Tailscale. AdGuard rewrites the Pi's tailnet name to its
LAN address, and the certificate is valid for that name. One set of bookmarks works
everywhere.

## A small, fixed public surface
Nothing on the router is forwarded. The live Pi publishes exactly one name to the internet
through Tailscale Funnel, for a service that is not part of this copy. The rule is written
down: no new public names, no new open ports.

Plaintext ports were closed when Caddy took over: Vaultwarden `:8222`, Uptime Kuma
`:3001`, Dockge `:5001` and CouchDB `:5984` have no host port at all. AdGuard's and
Syncthing's admin UIs still listen for Caddy but ufw denies them to the LAN.

## Closing Docker's ufw bypass
Docker publishes ports with DNAT in the FORWARD chain, so ufw's INPUT rules never see that
traffic. A port that looks firewalled is open. [`_host/etc/ufw/after.rules`](../_host/etc/ufw/after.rules)
fills the `DOCKER-USER` chain at every ufw reload: new connections that arrive on `eth0`
from outside the LAN are dropped. The LAN, the tailnet and container-to-container traffic
are untouched.

Containers reaching the host are limited too. ufw admits only DNS and three host-network
ports (AdGuard UI, Home Assistant, Syncthing GUI) from Docker networks. Anything else a
container tries shows up as a `[UFW BLOCK]` line.

## No fallback DNS, on purpose
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

## Backups are verified before anything is pruned
A backup engine that deletes old archives after writing a broken new one is worse than no
engine. [`homelab-backup`](../_host/usr/local/sbin/homelab-backup) reads one list,
[`backups.conf`](../_host/etc/homelab/backups.conf). It takes SQLite copies with the online
backup API, runs `PRAGMA quick_check`, checks a row count and checks that the required
members are in the finished archive. Only then does it prune older archives, and it never
prunes the newest three. A failed set keeps everything it had and sends one push.

`forbid` rules fail any set that would carry a `.env` or key file to the laptop. Details:
[docs/backups-and-restore.md](backups-and-restore.md).

## The repo is the source of truth, and drift is checked
Host files live under [`_host/`](../_host) at their live paths.
[`MANIFEST`](../_host/MANIFEST) lists each one with its mode, owner and what to do after a
change. [`install.sh`](../_host/install.sh) has four modes:

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

## Updates in tiers, after the backup
Watchtower is the only updater. It runs at 05:30, after the verified 05:00 backup, only
for containers labelled for it. It applies an image only once that image is more than
3 days old, one container at a time, waiting for each to become healthy. Image tags track
major lines (`caddy:2`, `couchdb:3.5`), so a new major version never arrives by itself.

Vaultwarden is the exception: it publishes only `:latest`. The health check reads its
GitHub releases and warns the first morning a new major version appears, before the
cooldown ends.

A container can be excluded by name. The live Pi does this for a Tailscale sidecar whose
restart withdraws a public DNS name for up to 18 minutes.

## Written for a flash stick
The root disk is a USB flash stick that loses recent writes on an abrupt reset. So:

- Scratch data and high-frequency state live in RAM: `/run`, `/dev/shm`, zram swap.
- The journal is capped, and chatty units log at `notice`.
- The health check alerts on more than 20 GiB/day of writes and on the USB link
  dropping to USB 2 speed.
- The hardware watchdog is deliberately not armed. A watchdog reset is an abrupt reset,
  and that costs data here.

## One switch for planned work
`sudo touch /run/homelab/maintenance` before stopping containers. While the flag exists,
the AdGuard pin and the network probe skip their runs, alerts do not wake the caretaker,
and the heartbeat gate ignores Uptime Kuma's state. `/run` is emptied at boot, so a
forgotten flag cannot outlive a reboot.
