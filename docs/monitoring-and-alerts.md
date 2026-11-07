# Monitoring and alerts

Everything ends as a push on one phone, through ntfy.sh. The design goal is that one
incident is one push, and that silence means healthy, not broken.

## Layers

| Layer | Watches | Speed |
|---|---|---|
| systemd and Docker restart policies | a process that exits | seconds |
| Uptime Kuma, 13 monitors | does each endpoint answer (HTTP, DNS, TCP, the tailnet TLS path) | 60 s, alerts after 3 failed checks |
| `homelab-health` | what an endpoint check cannot see | daily, 07:30 |
| `homelab-failure@` | any homelab unit that fails | when it fails |
| healthchecks.io | the Pi itself: dead, hung, offline, or its monitors broken | 5 min pings, alerts after 20 min |
| the caretaker session | causes, and the gaps that let a failure through | woken by alerts and a daily tick |

## One notifier, deduplicated

ntfy.sh allows 250 messages a day per public IP, for everything together. A watchdog that
pushed every 10 minutes through a long outage would use that up and silence every other
alert. So every source goes through [`homelab-notify.sh`](../_host/usr/local/bin/homelab-notify.sh):

- `--key K --every H` sends at most one push per key every H hours. `--every 0` sends once
  until resolved.
- `--resolve K` sends the all-clear, but only if an alert for K actually reached the phone.
  Healthy runs call it every time; with no open incident it writes nothing to disk.
- A failed send is retried by a later call after 30 minutes, not on every call.
- A lock per key, so two watchdogs firing in the same second send one push.
- It always exits 0. A notification that cannot be sent must never break the job that was
  reporting.
- Every send is logged with its HTTP code. The topic never is; it lives in a root-only file.

A new alert at default priority or higher also wakes the caretaker session (see
[ai-operator.md](ai-operator.md)).

## The daily health check

[`homelab-health.sh`](../_host/usr/local/bin/homelab-health.sh) runs at 07:30, after the
backup, the PC's pull and Watchtower. It sends one push per category, repeated at most every
20 hours while the problem lasts, and one all-clear when it is gone. `--dry-run` prints what
it would send and writes no state.

| Category | Checks |
|---|---|
| backups | every set in `backups.conf` verified within its limit, its newest archive still there, the timer active |
| mirror | a copy left the flash stick within 36 h (the PC's pull or the MacBook push) |
| containers | every `container_name` in the compose files exists, runs, is not unhealthy, has not crash-restarted; no undeclared container is dead; no container holds a stale `docker.sock` |
| memory | under 800 MB available, naming the biggest process |
| storage | disk and inode use, `/boot/firmware` space, read-only root, ext4 error count, kernel USB and I/O events, the root disk's USB link speed, flash writes per day, an abrupt reset (no clean shutdown record) |
| units | failed units, homelab timers inactive, the TV lighting services down |
| reboot | a pending reboot older than 7 days, a new kernel or firmware waiting |
| tls | the certificate on disk, and the one Caddy actually serves, valid for 14+ days and the same |
| tailscale | backend running, node online, key expiry |
| dns | AdGuard answers on `127.0.0.1:53` (urgent) |
| power | throttling now or earlier this boot, temperature |
| homeassistant | reachable through Caddy (400 means the proxy trust broke), banned IPs, the proxy and ban settings in `.storage/http` |
| updates | a new Vaultwarden major release, a release not applied after 7 days, security updates unattended-upgrades missed, packages waiting 7 days |
| updates-watchtower | Watchtower is still behind its newest release |
| reminders | dated owner tasks from a small config file |
| guards | directories whose mode 700 protects secret-bearing files below them; the network probe still writing samples |
| config-drift | live host files differ from `_host/`, or the repo has uncommitted changes |

The live Pi has 21 categories and 77 alert conditions. This copy has 17 and 62. The rest
check services that are not published here.

Some checks exist because of a specific incident:
- **Stale `docker.sock`.** After a dockerd restart, a container that bind-mounts the socket
  keeps the deleted one. It stays "healthy" but cannot reach Docker. Watchtower missed its
  run two mornings in a row before this check existed.
- **Memory.** A leaking HyperHDR left 55 MB free. The Pi swapped to the flash stick and DNS
  slowed for the whole house.
- **Flash writes.** A bulk vault sync costs several times its size in writes. When the
  Syncthing log shows a sync that explains the writes, the alert drops to low priority
  instead of waking anyone.
- **Home Assistant `.storage/http`.** Restoring an HA backup from before the proxy change
  silently brings back the old trust settings, and the endpoint probe still sees 200.

## Dead-man switch

Uptime Kuma runs on the Pi, so it cannot report the Pi's own death. A healthchecks.io check
does: [`homelab-heartbeat.timer`](../_host/etc/systemd/system/homelab-heartbeat.timer) pings
it every 5 minutes, and the check alerts by push and email after a 10-minute period plus
10 minutes of grace.

The ping URL is a secret, so it never appears in a process list or the journal. systemd reads
it from a root-only file, and curl gets it on stdin as a config line, running as a throwaway
`DynamicUser`.

Before every ping, a gate runs as root ([`homelab-heartbeat-gate`](../_host/usr/local/sbin/homelab-heartbeat-gate))
and withholds the ping when:
1. Uptime Kuma's container is not healthy. Skipped under the maintenance flag, when Kuma
   may be recreated on purpose.
2. The health check has not completed a real run for 29 hours. Each real run touches a
   stamp file; dry runs do not.

So a healthchecks.io alert means one of three things: the Pi is down or offline, Kuma is
broken, or the daily check stopped. The journal names which: a "withholding heartbeat"
line, or no runs at all.

The heartbeat unit has no `OnFailure=` on purpose. healthchecks.io is the alert, and a local
one would only double it.

## Unit failures: one template

Every homelab service has `OnFailure=homelab-failure@%n.service` in its `[Unit]` section
(systemd silently ignores it under `[Service]`). The template
runs [`homelab-failure-notify`](../_host/usr/local/sbin/homelab-failure-notify), which:

- reads the failed run's own log lines through its invocation ID, `FAILED`/`ERROR` lines
  first, otherwise the tail;
- redacts anything that looks like a credential;
- sends one push per unit per 20 hours, at high priority for the backup and the certificate
  renewal.

Each unit's `ExecStartPost=` sends the all-clear on its next success. The template itself has
no `OnFailure=`, because an alert about an alert unit would loop.

## Is it the ISP?

When "the internet is slow", the usual cause here is the ISP's international routes in the
evening, not the Pi. [`homelab-netprobe`](../_host/usr/local/bin/homelab-netprobe) keeps the
evidence ready.

Every 2 minutes it opens 4 TCP connections to each of:
- the router (`lan`);
- 1.1.1.1 and 8.8.8.8 (`near`);
- three single-region AWS endpoints in Frankfurt, Virginia and Tokyo (`far`).

`homelab-netprobe report` prints loss and median connect time per hour, with a reading:
`house network/Pi`, `ISP (all paths)` or `ISP international`. A connect that took 1 s or
more counts as a loss, because the kernel retries a dropped SYN only after 1 s.

The far targets are names, so they depend on the Pi's own DNS. A failed lookup is marked and
never counted as packet loss. Before that rule, a 25-minute AdGuard outage read as
"international 24% loss". The data lives in `/run` (RAM, 7 days). Nothing is written to the
flash stick, and the unit logs only at `notice`.

## Planned work

`sudo touch /run/homelab/maintenance` before stopping containers, `sudo rm` it afterwards.
It does not silence Kuma: 2 retries at 60 s absorb a restart under about 2 minutes. `/run` is
emptied at boot.

## Tests

[`watchdog-tests.sh`](../_host/watchdog-tests.sh) runs the notifier and the network probe
against stubs, in three layers: shell functions for `curl`, `docker` and `logger`; `PATH`
stubs that refuse and record; and a `DOCKER_HOST` pointing at a socket that does not exist.
A run must end with zero `PATH`-stub hits. In this copy: 43 checks, all passing.

The wake-up stub is there because of a real mistake. An earlier run reached the real
caretaker script by its absolute path and typed 22 fake alert lines into the live session.
Every side effect a script under test can reach now has an override, and a test that the
stub was hit.
