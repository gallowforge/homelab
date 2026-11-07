<picture>
  <source media="(max-width: 700px)" srcset="docs/readme/hero-mobile.webp" />
  <img src="docs/readme/hero.webp" width="100%" alt="homelab: a household platform, run like production. A diagram of one Raspberry Pi 5: phones, laptops and the TV reach Caddy and AdGuard at home, devices away come in over Tailscale, and inside the Pi run Vaultwarden, CouchDB, Syncthing, Home Assistant, Uptime Kuma and Watchtower, with nightly timers and an AI operator. Backups leave for a desktop PC and a MacBook; alerts reach a phone and a dead-man switch." />
</picture>

<p align="center">
  <a href="#quickstart"><b>Quickstart</b></a>
  &nbsp;·&nbsp;
  <a href="#how-it-works">How it works</a>
  &nbsp;·&nbsp;
  <a href="docs/design-decisions.md">Design decisions</a>
  &nbsp;·&nbsp;
  <a href="docs/past-failures.md">Past failures</a>
  &nbsp;·&nbsp;
  <a href="docs/README.md">Docs</a>
  &nbsp;·&nbsp;
  <a href="SECURITY.md">Security</a>
</p>

<p align="center">
  <a href="https://github.com/gallowforge/homelab/actions/workflows/validate.yml"><img alt="validate" src="https://github.com/gallowforge/homelab/actions/workflows/validate.yml/badge.svg" /></a>
  <img alt="43 stubbed tests passing" src="https://img.shields.io/badge/tests-43_passing-e2915a?labelColor=0f1217" />
  <img alt="0 port forwards" src="https://img.shields.io/badge/port_forwards-0-e2915a?labelColor=0f1217" />
  <img alt="Runs on a Raspberry Pi 5" src="https://img.shields.io/badge/runs_on-Raspberry_Pi_5-e2915a?labelColor=0f1217" />
  <a href="LICENSE"><img alt="MIT licence" src="https://img.shields.io/badge/licence-MIT-9aa1ad?labelColor=0f1217" /></a>
</p>

<br />

A house quietly depends on a handful of services: DNS, the password vault, notes, the smart home. Most homelabs keep them alive by memory and luck. A config gets edited on the live machine, a backup is copied but never restored, and an alert either fires forty times or not at all.

**This repo runs one Raspberry Pi 5 like a small production platform.** Every hand-written file, host configuration included, lives in git at its live path, and a tool proves the machine still matches. Every night a backup engine writes, verifies and only then prunes, and every week a drill restores the result. Failures reach one phone as one push, and an always-on Claude Code session investigates them under a written charter.

<picture>
  <source media="(max-width: 700px)" srcset="docs/readme/numbers-mobile.webp" />
  <img src="docs/readme/numbers.webp" width="100%" alt="15 services on one Pi 5, 12 backup sets verified every night, a 10-second weekly restore drill in RAM, 77 alert conditions checked every day, 20 systemd timers and zero cron jobs, and 0 port forwards." />
</picture>

<sub>Figures from the live Pi. This public copy carries 9 of the 15 containers, 9 of the 12 backup sets, 62 of the 77 alert conditions and 13 of the 20 timers; see <a href="#what-this-copy-leaves-out">what it leaves out</a>.</sub>

<br />

## How it works

AdGuard answers DNS for every device in the house. Caddy is the only TLS front door, one port per app, with the tailnet's own certificate. Behind it, each service is a Docker Compose stack. Host jobs are systemd timers, and the important ones report failures through one alert template. The [full diagram and service list](#architecture) are further down.

## One front door, nothing open to the internet

- **No forwarded ports.** The ISP uses CGNAT, so nothing inbound could reach the house anyway. Devices away from home come in over Tailscale (WireGuard); port forwarding and UPnP are off.
- **One set of links.** At home, AdGuard answers the tailnet name with the Pi's LAN address, and the certificate is valid for that name. The same HTTPS bookmarks work on the sofa and abroad.
- **Docker cannot punch through.** Docker publishes ports with DNAT, which skips ufw's INPUT rules. [`after.rules`](_host/etc/ufw/after.rules) fills `DOCKER-USER`, so a published port stays closed to anything outside the LAN.
- **Probed like a client.** 13 Uptime Kuma monitors check DNS, HTTP, TCP and the tailnet TLS path every 60 seconds.

<picture>
  <source media="(max-width: 700px)" srcset="docs/readme/frontdoor-mobile.webp" />
  <img src="docs/readme/frontdoor.webp" width="100%" alt="A status board for raspberrypi.example-tailnet.ts.net: AdGuard DNS on port 53 and Vaultwarden, Home Assistant, CouchDB, Syncthing, the AdGuard admin and Dockge on HTTPS ports 8443 to 8453 through Caddy, all up. 13 monitors, every 60 seconds, 0 ports forwarded." />
</picture>

## Every backup is proven before an old one is deleted

- **One engine, one list.** [`homelab-backup`](_host/usr/local/sbin/homelab-backup) reads [`backups.conf`](_host/etc/homelab/backups.conf). The health check reads the same list to confirm every set is fresh, so a new set is covered in one place.
- **Verify, then prune.** SQLite copies use the online backup API, then `PRAGMA quick_check` and a row count. Every archive must contain its required members. Only then are older archives pruned, and the newest three never are.
- **A failure keeps everything.** A failed set keeps all its old archives and sends one push. `forbid` rules fail any set that would carry a `.env` or key file to the laptop.
- **Copies on three machines.** The desktop PC pulls nightly onto a LUKS disk, without `--delete`, so a wiped Pi can never delete them. The MacBook gets a push every 20 minutes whenever it is reachable.

<picture>
  <source media="(max-width: 700px)" srcset="docs/readme/backups-mobile.webp" />
  <img src="docs/readme/backups.webp" width="100%" alt="Terminal: sudo homelab-backup writes nine sets, each verified (quick_check ok, row counts, members) and pruned. Then Vaultwarden's rsa_key.pem is moved away, and the next run fails that set with 'required file is missing - nothing pruned' and keeps the older archives." />
</picture>

## A backup only counts once it has been restored

- **Every Sunday at 05:45,** [`backup-restore-test.sh`](_host/backup-restore-test.sh) unpacks the newest archive of every set into `/dev/shm`, so the flash stick takes no writes. About 10 seconds.
- **Checked against live data, not just opened.** SQLite `integrity_check` and row counts compared with live, Vaultwarden's signing key byte for byte, the git bundle cloned and compared with live HEAD, secrets compared without ever printing them.
- **A drill that cries wolf gets fixed, not re-run.** When Home Assistant rewrote its own key file after the archive was taken, the drill learned to compare only the key, and a tampered key still fails.

<picture>
  <source media="(max-width: 700px)" srcset="docs/readme/drill-mobile.webp" />
  <img src="docs/readme/drill.webp" width="100%" alt="Restore drill report: 9 of 9 sets passed, 0 failed. Each row shows the set, its type and its checks, such as integrity_check ok, ciphers=412 (live now 412), rsa_key.pem present and identical to live, bundle clones, and all files identical to live." />
</picture>

## One incident, one push

- **Every source goes through one notifier.** [`homelab-notify.sh`](_host/usr/local/bin/homelab-notify.sh) sends at most one push per key per interval, and an all-clear only if the alert really reached the phone. ntfy.sh allows 250 messages a day per IP, and one noisy watchdog would otherwise silence every other alert.
- **Failures quote their own logs.** [`homelab-failure@`](_host/usr/local/sbin/homelab-failure-notify) reads the failed run's lines by invocation ID, redacts anything that looks like a credential, and sends them.
- **Layers that cover each other.** systemd restarts, Uptime Kuma, a daily health check for what an HTTP probe cannot see, and an external dead-man switch that raises the alarm when the Pi itself goes quiet.
- **Silence means healthy.** With no open incident, the all-clear call is a no-op: no push, no write to the flash stick.

<picture>
  <source media="(max-width: 700px)" srcset="docs/readme/alerts-mobile.webp" />
  <img src="docs/readme/alerts.webp" width="100%" alt="A phone lock screen with two ntfy notifications: 'homelab-backup.service failed on raspberrypi' quoting the FAILED line, and 41 minutes later 'homelab-backup.service OK again'. Beside it the notifier's log: sent, suppressed (already sent 14 min ago), resolved, and the wake-up line typed into the operator's session." />
</picture>

## The repo is the machine

- **Host files at their live paths.** [`_host/`](_host) mirrors `/etc` and `/usr/local`, and [`MANIFEST`](_host/MANIFEST) gives each file its mode, owner and the follow-up a change needs.
- **Drift is a diff, not a surprise.** [`install.sh`](_host/install.sh) compares every entry with the live system and ends with `RESULT: no drift` or the difference. It also reports untracked files and timers that are installed but not enabled. The daily health check runs the same comparison.
- **Committed, or refused.** `--apply` will not run while `_host/` has uncommitted changes. It keeps the old file and prints follow-ups instead of restarting services itself.
- **Rebuildable.** `--bootstrap` recreates the Docker network and enables every timer on a fresh host. The target is 2-3 hours from bare hardware.

<picture>
  <source media="(max-width: 700px)" srcset="docs/readme/drift-mobile.webp" />
  <img src="docs/readme/drift.webp" width="100%" alt="Terminal: sudo _host/install.sh finds a hand edit in /etc/fail2ban/jail.local (maxretry 3 instead of 5) and ends with RESULT: DRIFT. --apply installs the repo's version, saves the old file and prints the follow-up. The next run ends with RESULT: no drift." />
</picture>

## An AI operator on call, bound by a charter

- **Woken by events.** A new alert at default priority or higher types one fixed-form line into an always-on Claude Code session. A daily tick at 08:10 runs the round. The every-minute layer stays plain machinery.
- **Bounded in writing.** A priority order, and lines a blanket "yes" does not move: reversible first, no growing the public surface, no widening its own powers.
- **Reviewable.** Every change is a commit with a reason and every day gets a journal entry. Alerts it causes reach the owner's phone like any other.
- **One command stops it:** `sudo systemctl stop claude-session caretaker-tick.timer`. More in [docs/ai-operator.md](docs/ai-operator.md).

<picture>
  <source media="(max-width: 700px)" srcset="docs/readme/operator-mobile.webp" />
  <img src="docs/readme/operator.webp" width="100%" alt="The operator's charter as a document: five priorities in order (nothing precious is lost, nothing private is exposed, the owner is never locked out, the house keeps working, everything else) and the lines it does not cross. Beside it, what wakes the operator, its daily round, and the one command that stops it." />
</picture>

## Why it is different

|                | This repo                                                   | The usual homelab                    |
| -------------- | ----------------------------------------------------------- | ------------------------------------ |
| Configuration  | Every hand-written file in git, host files included         | Edited on the live machine           |
| Drift          | `install.sh` diff before and after each change, and daily   | Found when something breaks          |
| Backups        | Verified before pruning, restored into RAM every week       | Copied, never restored               |
| Alerts         | One deduplicated push per incident, then one all-clear      | Every check pushes, or nothing does  |
| Remote access  | Tailscale, 0 port forwards                                  | Forwarded ports or a public tunnel   |
| Updates        | After the verified backup, 3-day cooldown, one at a time    | Whenever the updater wakes up        |
| On call        | An AI operator under a written charter, stoppable at once   | Whoever notices first                |

## Goals, in priority order

When two goals conflict, the lower number wins.

1. **Never lose data.** The password vault, notes, personal vault, Home Assistant config and the backups themselves come before uptime and before convenience. A backup counts only once a restore has read it back.
2. **Private by default.** Nothing is reachable from the internet unless that was a deliberate, written decision. No forwarded ports, no new public names, no secret in git.
3. **The house keeps working.** DNS first, then the vault and Home Assistant. Risky work happens after the backup, one container at a time, and fails loudly instead of quietly falling back to something that half works.
4. **Every change is visible, reproducible and reversible.** Git holds every hand-written file, the install tool refuses to apply uncommitted host files, and the operator's actions are in the git log and a journal. One command stops the operator.
5. **Low maintenance.** Automated checks over manual care. A manual step that has to be remembered is treated as a bug in the tooling.

Two examples of the order at work: the hardware watchdog stays off, because on this flash stick an abrupt reset costs data (1 beats 3). Updates wait for the verified nightly backup and a 3-day cooldown, even though that leaves known fixes uninstalled for a few days (1 beats 5).

## Quickstart

Run the same checks CI runs. Nothing here touches a live system:

```bash
git clone https://github.com/gallowforge/homelab.git && cd homelab

# parse and validate the backup list
HOMELAB_BACKUP_CONF=_host/etc/homelab/backups.conf bash _host/usr/local/sbin/homelab-backup --check-config

# the stubbed tests for the notifier and the network probe (they reach no Docker, curl or ntfy)
d=$(mktemp -d) && mkdir -p "$d/bin" && cp _host/watchdog-tests.sh "$d/run-tests.sh"
cp _host/usr/local/bin/*.sh _host/usr/local/bin/homelab-netprobe "$d/bin/"
TEST_TMP="$d/tmp" bash "$d/run-tests.sh"          # RESULT: 43 passed, 0 failed

# replay the README demos: the real scripts in a bubblewrap sandbox on synthetic data
scripts/readme-demo.sh
```

To adapt it to your own Pi (Raspberry Pi OS Lite 64-bit, Docker CE with Compose, Tailscale), clone it to `~/docker` and replace the placeholders: `192.168.1.x`, `100.64.0.x`, `example-tailnet.ts.net` and the user `pi`. Then:

```bash
for f in */.env.example; do install -m 600 "$f" "${f%.example}"; done   # then fill in each .env
sudo install -D -m 600 _host/etc/homelab/secrets.env.example /etc/homelab/secrets.env

sudo _host/install.sh               # diff: on a fresh host every entry shows as MISSING
sudo _host/install.sh --apply       # install the host files (commit first: it refuses a dirty _host/)
sudo _host/install.sh --bootstrap   # Docker network 'proxy', enable every timer

(cd adguard && docker compose up -d)   # DNS first, then the other stacks, Uptime Kuma last
sudo homelab-backup && sudo homelab-health.sh --dry-run   # must end with 'all healthy'
```

### How a change is made

1. Edit the file in the repo (host files: the copy under `_host/`).
2. `git commit`. The [pre-commit hook](_host/git-hooks/pre-commit) blocks known secret patterns and prints only `file:line` and the rule name.
3. `sudo _host/install.sh` shows the diff against the live system; `sudo _host/install.sh --apply` installs it.
4. Verify from a client's point of view, then `sudo homelab-health.sh --dry-run` must end with `all healthy`, and `sudo _host/install.sh` with `RESULT: no drift`.

## Under the hood

| Question | Method |
| --- | --- |
| How do devices away from home get in? | Tailscale (WireGuard). CGNAT and no IPv6 rule out port forwarding. Caddy serves the tailnet certificate from `tailscale cert`, renewed weekly and reloaded with `--force`. [More](docs/design-decisions.md#tailscale-instead-of-port-forwarding) |
| How do the same links work at home? | AdGuard rewrites the Pi's tailnet name to its LAN address, and the certificate is valid for that name. |
| What stops Docker from bypassing the firewall? | `DOCKER-USER` drops new connections on `eth0` from outside the LAN. Containers may reach only DNS and three host-network ports. [More](docs/design-decisions.md#closing-dockers-ufw-bypass) |
| What if the Pi's DNS stops? | No fallback resolver, on purpose (Apple devices raced it and lost local names). Parallel DoH upstreams, `oom_score_adj: -500`, a Kuma DNS probe every 60 s and an urgent push. [More](docs/design-decisions.md#no-fallback-dns-on-purpose) |
| When is a backup trusted? | Online SQLite backup, `quick_check`, a row count, required members, `forbid` rules. Prune only afterwards, never the newest 3. A weekly restore into RAM. [More](docs/backups-and-restore.md) |
| How are updates applied? | Watchtower at 05:30, after the verified 05:00 backup, labelled containers only, images at least 3 days old, one container at a time. Tags track major lines. [More](docs/design-decisions.md#updates-in-tiers-after-the-backup) |
| How is drift found? | `install.sh` diffs every MANIFEST entry, scans homelab paths for untracked files and checks every timer is enabled. The daily health check repeats the diff. [More](docs/design-decisions.md#the-repo-is-the-source-of-truth-and-drift-is-checked) |
| How is the flash stick protected? | Scratch data in RAM (`/run`, `/dev/shm`, zram), a capped journal, alerts above 20 GiB/day of writes or on a USB 2 link, and no hardware watchdog. [More](docs/design-decisions.md#written-for-a-flash-stick) |
| How is the Pi's own death noticed? | A healthchecks.io heartbeat every 5 minutes, withheld when Kuma is unhealthy or the health check has not run for 29 hours. [More](docs/monitoring-and-alerts.md#dead-man-switch) |
| How does planned work stay quiet? | `sudo touch /run/homelab/maintenance` pauses the probes, the operator's alert wake-ups and the heartbeat gate's Kuma check. `/run` is emptied at boot. [More](docs/design-decisions.md#one-switch-for-planned-work) |

### Past failures and what changed

Each cost an outage, data, or a morning of diagnosis, and each ended in a change to the configuration, a new check or a written rule. The full stories, with root causes, are in [docs/past-failures.md](docs/past-failures.md).

| What broke | What changed |
| --- | --- |
| About 17 services on a public domain, and a WireGuard server that never connected through CGNAT | Tailscale only, the domain and tunnel gone, written rule: no new public names or open ports |
| A fallback DNS server broke every local link on Apple devices | The Pi is the only resolver; the risk is managed in place |
| Arming the hardware watchdog reset the Pi and truncated `cmdline.txt` | Watchdog off by design; boot-level work only with someone at the Pi |
| A leaking HyperHDR left 55 MB free, and DNS crawled for the whole house | One kept-open connection, a memory guard, zram, a memory alert that names the process |
| Watchtower stayed "healthy" while its `docker.sock` was stale | The health check compares the socket inode inside every container that mounts it |
| A partial upstream fault became a 25-minute whole-house DNS outage | Browsing security off; the network probe tells DNS failures from packet loss |
| The restore drill failed a backup that was fine | The drill compares Home Assistant's key, not its rewritten history |

<details>
<summary><b id="architecture">Architecture diagram and services</b></summary>
<br />

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

Host: Raspberry Pi OS Lite 64-bit (Debian 12), Docker CE with Compose, Tailscale. The root filesystem is on a USB flash stick, and that shapes many of the [design decisions](docs/design-decisions.md).

More figures from the live Pi: 12 backup sets in about 2.5 minutes at 05:00; 13 Uptime Kuma monitors; a dead-man switch that alerts after 20 minutes of silence; 376 commits since the repo started; about 1,900 lines of runbooks and charter, 1,900 lines of per-stack notes and a 1,000-line operating journal. The data sets were rehearsed end to end on another machine in about 10 minutes.

</details>

<details>
<summary><b>Repository layout</b></summary>
<br />

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
├── docs/                    the deeper write-ups, indexed in docs/README.md
│   ├── design-decisions.md
│   ├── past-failures.md
│   ├── backups-and-restore.md
│   ├── monitoring-and-alerts.md
│   ├── ai-operator.md
│   ├── tv-ambient-lighting.md
│   └── readme/              README images, their HTML sources and captured demo output
├── scripts/                 readme-demo.sh (sandboxed demo runs), readme-visuals.sh (renders)
├── .github/workflows/       CI: validate.yml
├── SECURITY.md              threat model, secret handling, how to report
└── CHANGELOG.md
```

Each stack keeps its secrets in a `.env` file (mode 600, never tracked); the `.env.example` next to it lists the variable names. Host scripts read `/etc/homelab/secrets.env`; its names are in [`secrets.env.example`](_host/etc/homelab/secrets.env.example).

</details>

## What this copy leaves out

The live repo is private. This copy differs in three ways:

- **Services removed.** A few services, a public Funnel endpoint, and their watchdogs and timers are not here. Neither are scripts that reach into other personal machines or data. Where a kept script had checks for those services, the checks were removed and the script was re-validated.
- **Values replaced.** LAN addresses use `192.168.1.x` (the Pi is `192.168.1.10`), tailnet addresses use `100.64.0.x`, the tailnet is `example-tailnet.ts.net`, and the account is `pi`. Device IDs, MAC addresses and a session ID are placeholders.
- **Private documents rewritten.** The runbooks, the caretaker charter and the journal stay private. The files in [`docs/`](docs) are condensed public versions.

## Quality

Every push and pull request runs [`validate.yml`](.github/workflows/validate.yml). Each step also runs on a workstation.

| Check | What it covers |
| --- | --- |
| `bash -n` and `shellcheck --severity=error` | All 19 shell scripts, found by shebang, since most host scripts have no extension |
| `python -m py_compile` | All 5 Python files |
| YAML parse | All 14 compose and Home Assistant files; HA's `!include` and `!secret` tags are accepted as opaque values |
| `homelab-backup --check-config` | The backup list: 9 sets, every key and path validated |
| Stubbed tests | 43 checks of the notifier and the network probe, behind three layers of stubs; a run must end with zero real calls |
| gitleaks | The full git history, on every push |
| README demos | [`scripts/readme-demo.sh`](scripts/readme-demo.sh) runs the backup engine, the restore drill, `install.sh` and the alert path in a sandbox; the images show that output |

See [SECURITY.md](SECURITY.md) for how secrets are kept out of the repo and how to report one that got in.

## FAQ

<details>
<summary><b>Can I run this on my own Pi?</b></summary>
<br />
Yes, as a starting point. It is a working configuration rather than an installer: replace the placeholders, fill in the <code>.env</code> files and follow the <a href="#quickstart">Quickstart</a>. The rebuild steps in <a href="docs/backups-and-restore.md#rebuilding-a-dead-pi">docs/backups-and-restore.md</a> are the same path from bare hardware.
</details>

<details>
<summary><b>Why give an AI session root on the house server?</b></summary>
<br />
Because nobody is awake to answer a prompt at 3 a.m., and the failures worth an agent are the ones no rule predicted. The limits come from elsewhere: a written charter with lines it does not cross, systemd, git for every change, and the same alert path the owner sees. The every-minute layer stays plain machinery, and one command stops the agent. See <a href="docs/ai-operator.md">docs/ai-operator.md</a>.
</details>

<details>
<summary><b>Why is there no fallback DNS server?</b></summary>
<br />
One was tried. Apple devices race every configured resolver, the public one answered "no such name" for the Pi, and that answer often won, so every local link broke. The single point of failure is managed in place instead. See <a href="docs/design-decisions.md#no-fallback-dns-on-purpose">No fallback DNS, on purpose</a>.
</details>

<details>
<summary><b>What happens when the Pi dies?</b></summary>
<br />
First aid is to point the router's DHCP at a public resolver until AdGuard is back. The Pi is then rebuilt from the newest archives on the PC: about 2-3 hours of work. The backup sets can lose up to about 26 hours; the personal vault loses nothing, because its other copies refill the new Pi. If the PC is gone too, the MacBook holds every set except <code>secrets</code>, <code>syncthing</code> and <code>dockge</code>.
</details>

<details>
<summary><b>Why a USB flash stick, and no hardware watchdog?</b></summary>
<br />
The Pi boots from one, so the design works around it: scratch data in RAM, a capped journal and alerts on heavy writes. Arming the hardware watchdog once reset the Pi mid-write and truncated its boot command line, so it stays off. See <a href="docs/past-failures.md">past failures</a>, number 3.
</details>

<details>
<summary><b>Why systemd timers and no cron?</b></summary>
<br />
A unit can carry <code>OnFailure=homelab-failure@%n.service</code>, so a failed job becomes one push quoting its own log lines, and its next success sends the all-clear. Each run gets its own journal entry, and the daily jobs catch up after downtime with <code>Persistent=true</code>. The heartbeat has no local alert on purpose: healthchecks.io is its alert.
</details>

## Contributing

Issues and pull requests are welcome, especially a safer default or a check that would have caught one of the [past failures](docs/past-failures.md) earlier. Run the [Quickstart](#quickstart) checks before opening one; CI runs the same steps plus gitleaks. Never commit real values: addresses, names and keys stay placeholders. A committed secret goes to the email in [SECURITY.md](SECURITY.md), not to a public issue.

The images in this README come from `scripts/readme-demo.sh`, which captures the real output, and `scripts/readme-visuals.sh`, which renders the pages in `docs/readme/src/`.

## Licence

[MIT](LICENSE). Built and run by Ali Husain.
