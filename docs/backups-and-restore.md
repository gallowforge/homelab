# Backups and restore

One engine, one list. [`homelab-backup`](../_host/usr/local/sbin/homelab-backup) writes the
archives and reads [`backups.conf`](../_host/etc/homelab/backups.conf). The health check reads
the same list to confirm every set is fresh, so adding a set in one place covers both.

## What is backed up

The live Pi has 12 sets. This copy keeps 9; the other three belong to services that are not
published.

| Set | Type | Contents | Kept (days) | Leaves the PC for the laptop |
|---|---|---|---|---|
| adguard | dir | `AdGuardHome.yaml`: settings, rewrites, admin hash | 14 | yes |
| couchdb | dir | CouchDB data and config: every LiveSync note | 14 | yes |
| kuma | sqlite | `kuma.db`: monitors, notification, 30 days of history | 7 | yes |
| vaultwarden | sqlite | `db.sqlite3` and `rsa_key.pem` (required) | 14 | yes |
| dockge | sqlite | `dockge.db`: admin user, JWT secret | 14 | no |
| syncthing | dir | identity only: keys, `config.xml`; no index, no lock | 14 | no |
| homeassistant | ha-link | hardlinks of Home Assistant's own encrypted backups | 7 | yes |
| platform | files | git bundle of the repo, host config, package lists, image digests | 30 | yes |
| secrets | files | every `.env`, `/etc/homelab/secrets.env`, HA's backup key, network secrets | 14 | no |

Not backed up, rebuilt instead: Docker images, Caddy's volumes, AdGuard's filter cache and
query log, the host's Tailscale identity, the TLS certificate (`tailscale cert` again).

The personal file vault is not in any set. It lives on the Pi, the PC and the
MacBook through Syncthing, with daily hardlink snapshots on the PC. Replication is not a
backup, and the PC snapshots are what make it one.

## How a set is verified

Sets are independent: a failure in one never stops the others.

- **SQLite sets**: online `.backup` with a 30 s busy timeout, `PRAGMA quick_check` on the
  copy, and a row count above zero in a named table (`ciphers` for Vaultwarden, `monitor`
  for Kuma).
- **Every set**: the finished archive is listed, and each `require` pattern must match a
  member. Any `forbid` pattern that matches fails the set. That is how a `.env` file is
  kept out of anything that travels to the laptop.
- **Pruning**: only after this run's archive passed. The newest 3 archives of a set are
  never pruned.
- **Failure**: the set keeps all its old archives and logs `FAILED <set>: <reason>`. The
  run exits 1, and `homelab-failure@` sends one push quoting those lines.

Two rules in the engine came from testing the failure path, not from reading the code:

1. `set -e` is disabled inside a compound command on the left of `||`. A failed `sqlite3`
   once still produced a valid-looking archive with no database in it. Every critical
   command now ends in `|| exit 1` or `|| fail`.
2. `tar -t | grep -q` under `pipefail` reports failure on success: grep exits on the
   first match and tar dies of SIGPIPE. The listing is captured first, then searched.

Each verified set writes `/var/lib/homelab/backup-status/<set>`. The health check alerts
when a set is older than its `max_age_h` (48 h by default) or its newest archive is gone.

## Where the copies live

1. **The Pi**, `~/backups`, on the flash stick. It dies with the Pi.
2. **The desktop PC** pulls everything at about 06:30 with `rsync` and no `--delete`, so a
   wiped Pi can never delete these copies. They sit on a LUKS disk, mode 600. The PC keeps
   rotating archives for 90 days and hand-made snapshots for 180.
3. **The MacBook** gets a copy two ways. The Pi pushes to it directly every 20 minutes
   whenever it is reachable ([`homelab-backup-push-mac`](../_host/usr/local/sbin/homelab-backup-push-mac)),
   so a copy leaves the stick even when the PC is off for days. The PC also forwards its
   copy over Syncthing.

The `secrets`, `syncthing`, `dockge` and hand-made sets never go to the laptop. The PC's
Syncthing ignore file holds them back, and the push script refuses to run if one of them
appears in its list.

The health check raises `mirror` when neither the PC's pull nor the MacBook push has
happened for 36 hours. It finds the PC's pull in the journal: sudo logs it as
`rsync --server --sender`.

## The weekly restore drill

A backup nobody restores is a guess. Every Sunday at 05:45
[`backup-restore-test.sh`](../_host/backup-restore-test.sh) unpacks the newest archive of
every set into `/dev/shm`, so the flash stick takes no writes, and checks that it is
usable:

| Type | What must hold |
|---|---|
| sqlite | `PRAGMA integrity_check` is `ok`; the count table has rows (compared with live); Vaultwarden's `rsa_key.pem` is identical to live |
| dir | AdGuard's YAML parses; the number of CouchDB `.couch` files equals live; Syncthing's cert parses and no index or lock was included |
| ha-link | the tar opens and `backup.json` parses |
| platform | the git bundle clones, and its HEAD is live HEAD or an ancestor of it; crontabs and `backups.conf` are present |
| secrets | every file is byte-identical to live (contents never printed); for HA's backup key, only the key itself must match |

With `--start`, it also starts a throwaway CouchDB on the restored files with
`--network none` and a one-off admin, then compares every database's `doc_count` with live.
The first run gave `obsidiannotes` 10287 restored, 10287 live.

A failing set sends one push. The whole drill takes about 10 seconds.

One false alarm shaped the rules. Home Assistant rewrites the history part of its backup
file at a random time near 05:00, sometimes after our archive was taken, so the drill now
compares only the encryption key in that file. Live files written after the archive are
noted, not failed.

## Restoring one set on a running Pi

1. `sudo touch /run/homelab/maintenance`, then `docker compose stop <service>`.
2. Move the current files aside into `~/backups/adhoc/<date>-restore-<set>/`. Never delete first.
3. Extract the newest archive from `~/backups/<set>/` with `sudo tar`.
4. Check a row count, start the service, test it from a client, remove the flag.

Rules for every SQLite restore:
- The container is stopped, or not created yet, while its database is replaced.
- Stale `-wal` and `-shm` files next to the database are deleted first. An old WAL
  replayed onto a restored database corrupts it.
- Always `sudo tar`. The archives are root 600, a non-root `tar` fails with an error that
  is easy to miss, and `sqlite3` then creates an empty database and reports `ok`.
- Check a row count before the app starts. Zero or "no such table" means the extract did
  not happen.

Rolling back an image: Watchtower deletes replaced images, but the `platform` set records
every container's image digest in `generated/docker-images.txt`. Pin
`image: <repo>@sha256:<digest>`, and restore the data set from before the update if the new
version migrated the database.

## Rebuilding a dead Pi

Target: about 2-3 hours of work, plus the vault re-sync in the background. Data loss: up to
about 26 hours for the backup sets (05:00 run, PC pull at about 06:30). The vault loses
nothing; its other copies refill the new Pi.

Every step can be re-run.

1. **First aid.** The house has no DNS while the Pi is down. In the router, point DHCP at
   a public resolver and turn the DNS redirect off. Undo this after AdGuard is back.
2. **OS.** Raspberry Pi OS Lite 64-bit, same hostname and first user (uid 1000, which the
   archives and the Syncthing container expect), SSH keys only. Set the static address with
   NetworkManager. Install Docker CE and Tailscale from their own repositories.
3. **Archives.** Copy the newest archive of each set from the PC to `~/restore`.
4. **Platform.** Clone the git bundle from the `platform` set; its HEAD must match
   `git-head.txt`. Extract the `secrets` set to `/`, leaving out the network connection and
   the HA key. Then `install.sh` (expect every file to show as missing), `install.sh --apply`,
   enable ufw, check that `DOCKER-USER` has its rules, and run `install.sh --bootstrap`. It
   must end with `RESULT: no drift`.
5. **Tailscale.** Remove the old machine in the admin console first so the new one gets the
   same name. Otherwise every link and the certificate name break. Then issue the
   certificate.
6. **Data, in this order:**
   - **AdGuard first**, because it is the house's DNS. Check a lookup and the LAN rewrite.
   - **Vaultwarden**: database and `rsa_key.pem` from the same archive. Without the key
     every Bitwarden client has to log in again.
   - **Caddy**: nothing to restore. Check `/alive` through it with a valid certificate.
   - **CouchDB**: compare `doc_count` with the reference.
   - **Syncthing**: the identity comes back, so the PC and the MacBook see the same device
     and refill the empty vault. Never copy an old vault into the folder by hand.
   - **Home Assistant**: upload its own encrypted backup on the onboarding screen and enter
     the key from the secrets set. Then check `.storage/http`. A backup older than
     2026-09-17 brings back the old proxy trust, and the health check would report it.
   - **Dockge and Watchtower.**
   - **Uptime Kuma last.** It pushes alerts for everything that is not up yet, from its
     first minute.
7. **Automation on.** Remove the maintenance flag. `install.sh --apply` enables and starts
   every timer in the MANIFEST. Run one backup by hand, then `homelab-health.sh --dry-run`
   must say `all healthy`.
8. **Verify like a user**, not with `docker ps`: a LAN device resolves and loads a page;
   every HTTPS link loads with a valid certificate, at home and on the tailnet; a Bitwarden
   client syncs without a new login; an Obsidian edit syncs; an Apple Home accessory
   responds; the PC's next pull succeeds.
9. **Clean up.** `shred` the `~/restore` copies, since they held the secrets set.

### Rehearsal

The data sets were rehearsed on the desktop PC on 2026-09-18, in a throwaway compose
project with every port bound to `127.0.0.1`. About 10 minutes, nothing failed. Uptime Kuma
went on an `--internal` Docker network: two minutes after start it tried to push its
first real alert, and that network is what stopped it.

### If the PC is gone too

The MacBook's copy has every set except `secrets`, `syncthing` and `dockge`:
- Vaultwarden comes back fully; only a new `.env` is needed.
- CouchDB's data is there; its admin password can be read from a LiveSync client's
  settings.
- Syncthing gets a new device ID, so the Pi is re-added on the other devices. The vault
  comes back from them.
- Dockge starts empty.
