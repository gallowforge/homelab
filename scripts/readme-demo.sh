#!/bin/bash
# scripts/readme-demo.sh - capture the terminal output shown in the README by
# running the real scripts from _host/ against synthetic data.
#
# Nothing touches the host. bubblewrap gives the scripts a fake root (uid 0 in a
# user namespace): this repo's host files installed at their live paths from the
# MANIFEST, a clone of the repo at /home/pi/docker, made-up app data (SQLite
# databases, a CouchDB tree, Home Assistant backups, throwaway keys) and stubs
# for systemctl, docker, dpkg and runuser. Every value is fake.
#
#   scripts/readme-demo.sh        writes docs/readme/src/demo/*.txt
#
# Needs bwrap, sqlite3, openssl, git, python3, tar and gzip. The archive names
# use today's date at 05:00, the time the nightly timer runs.
# shellcheck disable=SC2016  # stub bodies are written out literally, expanded when they run
set -euo pipefail
export TZ=UTC LC_ALL=C

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=$REPO/docs/readme/src/demo
for t in bwrap sqlite3 openssl git python3 tar gzip; do
  command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 2; }
done

W=$(mktemp -d "${TMPDIR:-/tmp}/readme-demo.XXXXXX")
trap 'chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"' EXIT
R=$W/root                       # the fake Pi's /
D=$R/home/pi/docker
STUBS=$R/usr/local/demo-stubs
DAY=$(date +%Y%m%d)
NOW=$(date +%s)
mkdir -p "$R"/{etc,boot/firmware,var/lib,var/backups,run/lock,usr/local,home/pi/backups} "$OUT"

# ---- the host: accounts, the files the platform set expects, every MANIFEST entry
printf 'root:x:0:0:root:/root:/bin/bash\npi:x:1000:1000::/home/pi:/bin/bash\n' > "$R/etc/passwd"
printf 'root:x:0:\npi:x:1000:\n' > "$R/etc/group"
echo raspberrypi > "$R/etc/hostname"
printf '127.0.0.1 localhost\n127.0.1.1 raspberrypi\n' > "$R/etc/hosts"
printf 'PARTUUID=00000000-01 /boot/firmware vfat defaults 0 2\nPARTUUID=00000000-02 / ext4 defaults,noatime 0 1\n' > "$R/etc/fstab"
echo 'console=tty1 root=PARTUUID=00000000-02 rootfstype=ext4 rootwait' > "$R/boot/firmware/cmdline.txt"
printf 'arm_64bit=1\ndtparam=audio=off\n' > "$R/boot/firmware/config.txt"
install -D -m 600 /dev/null "$R/etc/homelab/secrets.env"
printf 'NTFY_TOPIC=demo_topic\nHC_PING_URL=https://hc-ping.example.com/demo\n' > "$R/etc/homelab/secrets.env"
while read -r path mode _owner _group _after; do
  case "$path" in ''|'#'*|ignore) continue ;; esac
  install -D -m "$mode" "$REPO/_host/$path" "$R/$path"
done < "$REPO/_host/MANIFEST"

# ---- /home/pi/docker: the repo as committed, plus any uncommitted edits ----------
git clone -q "$REPO" "$D"
(cd "$REPO" && git ls-files -z | tar --null -T - -cf -) | tar -xf - -C "$D"
if [ -n "$(git -C "$D" status --porcelain)" ]; then
  git -C "$D" -c user.name=demo -c user.email=demo@example.com commit -qam "demo: working tree"
fi

# ---- made-up app data (all of it ignored by the repo's whitelist .gitignore) ------
blob() { # blob <file> <KiB>: compressible filler that looks like data
  head -c $(( $2 * 768 )) /dev/urandom | base64 -w 120 > "$1"
}
mkdir -p "$D/adguard/conf"
cat > "$D/adguard/conf/AdGuardHome.yaml" <<'EOF'
http:
  address: 0.0.0.0:3000
dns:
  bind_hosts: [0.0.0.0]
  port: 53
  upstream_dns: [https://dns.example.net/dns-query]
filtering:
  rewrites:
    - domain: raspberrypi.example-tailnet.ts.net
      answer: 192.168.1.10
EOF
cp "$D/adguard/conf/AdGuardHome.yaml" "$D/adguard/conf/AdGuardHome.yaml.bak-1"

mkdir -p "$D/couchdb/couchdb-data/.shards" "$D/couchdb/couchdb-etc"
for db in _users _replicator notes notes-attachments; do blob "$D/couchdb/couchdb-data/$db.couch" 900; done
for s in 00000000-7fffffff 80000000-ffffffff; do
  mkdir -p "$D/couchdb/couchdb-data/shards/$s"
  for db in notes notes-attachments; do blob "$D/couchdb/couchdb-data/shards/$s/$db.1730000000.couch" 2400; done
done
printf '[couchdb]\nsingle_node = true\n[chttpd]\nrequire_valid_user = true\n' > "$D/couchdb/couchdb-etc/docker.ini"

mkdir -p "$D/uptime-kuma/data"
sqlite3 "$D/uptime-kuma/data/kuma.db" <<'EOF'
CREATE TABLE monitor(id INTEGER PRIMARY KEY, name TEXT, type TEXT, interval INTEGER);
CREATE TABLE heartbeat(id INTEGER PRIMARY KEY, monitor_id INTEGER, status INTEGER, msg TEXT, time TEXT, ping INTEGER);
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 13)
  INSERT INTO monitor(name, type, interval) SELECT 'monitor ' || i, 'http', 60 FROM n;
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 13 * 2880)
  INSERT INTO heartbeat(monitor_id, status, msg, time, ping)
  SELECT 1 + i % 13, 1, '', datetime('now', '-' || (i / 13) || ' minutes'), 20 + abs(random() % 40) FROM n;
EOF

mkdir -p "$D/vaultwarden/data/attachments/demo" "$D/vaultwarden/data/sends"
sqlite3 "$D/vaultwarden/data/db.sqlite3" <<'EOF'
CREATE TABLE ciphers(uuid TEXT PRIMARY KEY, atype INTEGER, name TEXT, data TEXT);
CREATE TABLE users(uuid TEXT PRIMARY KEY, email TEXT);
INSERT INTO users VALUES ('u1', 'alex@example.com');
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 412)
  INSERT INTO ciphers SELECT 'c' || i, 1, '2.' || hex(randomblob(24)), '2.' || hex(randomblob(600)) FROM n;
EOF
openssl genrsa -out "$D/vaultwarden/data/rsa_key.pem" 2048 2>/dev/null
blob "$D/vaultwarden/data/attachments/demo/receipt.bin" 40
echo '{}' > "$D/vaultwarden/data/config.json"

mkdir -p "$D/dockge/data"
sqlite3 "$D/dockge/data/dockge.db" "CREATE TABLE user(id INTEGER PRIMARY KEY, username TEXT); INSERT INTO user(username) VALUES ('admin');"

mkdir -p "$D/syncthing/config/index-v2"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-384 -nodes -days 3650 -subj /CN=syncthing \
  -keyout "$D/syncthing/config/key.pem" -out "$D/syncthing/config/cert.pem" 2>/dev/null
echo '<configuration version="37"><device id="DEMO" name="raspberrypi"/></configuration>' > "$D/syncthing/config/config.xml"
blob "$D/syncthing/config/index-v2/000001.log" 300
: > "$D/syncthing/config/syncthing.lock"

for s in vaultwarden couchdb watchtower; do printf 'DEMO_ONLY=1\n' > "$D/$s/.env"; done
mkdir -p "$D/homeassistant/config/.storage" "$D/homeassistant/config/backups"
echo '{"version":1,"data":{"config":{"create_backup":{"password":"demo"}}}}' > "$D/homeassistant/config/.storage/backup"
echo demo_topic > "$R/home/pi/.ntfy-topic"

# ---- history: last nights' archives, so the run has something to prune ------------
# Names use the night they were taken; mtimes put them that many days back.
old_day() { date -d "$DAY -$1 days" +%Y%m%d; }
ago()     { touch -d "@$(( NOW - $1 * 86400 - 3600 ))" "$2"; }
while IFS=$'\t' read -r set type keep; do
  [ "$type" = ha-link ] && continue
  mkdir -p "$R/home/pi/backups/$set"
  for (( k = 1; k <= keep + 1; k++ )); do
    f="$R/home/pi/backups/$set/${set}_$(old_day "$k")_050002.tar.gz"
    echo old > "$f"; ago "$k" "$f"
  done
done < <(awk '/^\[/{gsub(/[][]/,""); s=$0} /^type/{t[s]=$3} /^keep/{k[s]=$3} END{for (x in t) printf "%s\t%s\t%s\n", x, t[x], k[x]}' "$R/etc/homelab/backups.conf")

# Home Assistant keeps its own 3 newest backups; two are already hardlinked here.
ha_backup() { # ha_backup <days ago>
  local t name tmp
  t=$(date -d "$DAY -$1 days 04:51:07" +%s)
  name="Automatic_backup_2026.11.1_$(date -d "@$t" +%Y-%m-%d_%H.%M)_$(( 51073412 + $1 * 7919 )).tar"
  tmp=$(mktemp -d "$W/ha.XXXXXX")
  printf '{"slug":"demo%04d","name":"Automatic backup 2026.11.1","date":"%s","protected":true}\n' "$1" \
    "$(date -u -d "@$t" +%Y-%m-%dT%H:%M:%S+00:00)" > "$tmp/backup.json"
  blob "$tmp/homeassistant.tar.gz" 1800
  tar -cf "$D/homeassistant/config/backups/$name" -C "$tmp" ./backup.json ./homeassistant.tar.gz
  rm -rf "$tmp"
  if [ "$1" -eq 0 ]; then ago 0 "$D/homeassistant/config/backups/$name"; else ago "$1" "$D/homeassistant/config/backups/$name"; fi
  echo "$name"
}
mkdir -p "$R/home/pi/backups/homeassistant"
for k in 2 1; do ln "$D/homeassistant/config/backups/$(ha_backup "$k")" "$R/home/pi/backups/homeassistant/"; done
ha_backup 0 >/dev/null
for k in 3 4 5 6 7 8; do
  f="$R/home/pi/backups/homeassistant/Automatic_backup_2026.11.1_$(date -d "$DAY -$k days" +%Y-%m-%d)_04.51_$(( 51073412 + k * 7919 )).tar"
  echo old > "$f"; ago "$k" "$f"
done

# ---- a hand edit on the live machine, for the drift demo ---------------------------
sed -i 's/^maxretry = 5$/maxretry = 3/' "$R/etc/fail2ban/jail.local"
touch -d "$(date -d "$DAY" +%F) 08:57:31" "$R/etc/fail2ban/jail.local"
touch -d "$(date -d "$DAY -9 days" +%F) 14:20:05" "$D/_host/etc/fail2ban/jail.local"

# ---- stubs: the sandbox has one uid, no systemd, no Docker, no dpkg ---------------
mkdir -p "$STUBS"
stub() { printf '#!/bin/sh\n%s\n' "$2" > "$STUBS/$1"; chmod 755 "$STUBS/$1"; }
stub date 'case "$*" in
  "+%Y%m%d_%H%M%S") echo "${DEMO_DAY}_050002" ;;
  "+%Y%m%d-%H%M%S") echo "${DEMO_DAY}-091204" ;;
  "+%F %H:%M") echo "$(/usr/bin/date -d "$DEMO_DAY" +%F) 05:00" ;;
  *) exec /usr/bin/date "$@" ;;
esac'
stub runuser 'while [ $# -gt 0 ]; do case "$1" in --) shift; break ;; -u) shift 2 ;; *) shift ;; esac; done; exec "$@"'
stub systemctl 'case "$1 $3" in
  is-enabled*) echo enabled ;;
  "show InvocationID") echo demo ;;
  "show Result") echo exit-code ;;
  "show ExecMainStatus") echo 1 ;;
esac; exit 0'
stub hostname 'echo raspberrypi'
stub crontab 'exit 1'
stub dpkg 'for p in bash ca-certificates curl docker-ce git openssl sqlite3 tailscale ufw; do printf "%s\tinstall\n" "$p"; done'
stub dpkg-query 'for p in bash ca-certificates curl docker-ce git openssl sqlite3 tailscale ufw; do printf "%s\t1.0\tarm64\n" "$p"; done'
stub apt-mark 'echo docker-ce; echo tailscale'
stub docker 'case "$*" in
  "ps -aq"|"image ls -q --no-trunc") for i in 1 2 3 4 5 6 7 8 9; do echo "sha256:000000000000000$i"; done ;;
  *) printf "demo\texample/image:1\tsha256:0000\trunning\tdemo\n" ;;
esac'

# The alert path: ntfy is a stub that records each POST (never the topic), the
# failed unit's journal is the failed run's real output, and the caretaker wake-up
# prints the line it would type instead of typing it.
stub curl 'while [ $# -gt 0 ]; do case "$1" in
  -H) echo "$2" >> /run/demo-ntfy.txt; shift 2 ;;
  --data-raw) printf "Body: %s\n----\n" "$2" >> /run/demo-ntfy.txt; shift 2 ;;
  *) shift ;;
esac; done; printf 200'
stub journalctl 'cat /run/demo-journal.txt'
stub wake '/usr/local/bin/caretaker-wake.sh --dry-run "$@" >> /run/demo-wake.txt'

run() { # run <command line>: inside the fake Pi, as root
  bwrap --unshare-user --uid 0 --gid 0 --unshare-pid --unshare-uts --hostname raspberrypi \
    --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/bin /sbin \
    --symlink usr/lib /lib --symlink usr/lib /lib64 \
    --bind "$R/usr/local" /usr/local --bind "$R/etc" /etc --bind "$R/home" /home \
    --bind "$R/boot" /boot --bind "$R/var" /var --bind "$R/run" /run \
    --proc /proc --dev /dev --tmpfs /dev/shm --tmpfs /tmp --chdir /home/pi/docker \
    --clearenv --setenv PATH /usr/local/demo-stubs:/usr/local/sbin:/usr/local/bin:/usr/bin \
    --setenv HOME /home/pi --setenv LANG C.UTF-8 --setenv DEMO_DAY "$DAY" \
    /bin/bash -c "$1"
}

run 'homelab-backup' > "$OUT/backup.txt" 2>&1 || true
run '_host/backup-restore-test.sh' > "$OUT/restore-drill.txt" 2>&1 || true
run '_host/install.sh' > "$OUT/install-drift.txt" 2>&1 || true
run '_host/install.sh --apply etc/fail2ban/jail.local' > "$OUT/install-apply.txt" 2>&1 || true
run '_host/install.sh' > "$OUT/install-clean.txt" 2>&1 || true
run 'homelab-backup --check-config' > "$OUT/check-config.txt" 2>&1 || true

# ---- a bad night: Vaultwarden's signing key is missing -----------------------------
K=/home/pi/docker/vaultwarden/data/rsa_key.pem
U=homelab-backup.service
run "mv $K /home/pi/rsa_key.pem.aside && homelab-backup --only vaultwarden" > "$OUT/backup-fail.txt" 2>&1 || true
run 'homelab-backup' > "$R/run/demo-journal.txt" 2>&1 || true
export_wake='HOMELAB_CARETAKER_WAKE=/usr/local/demo-stubs/wake'
run "$export_wake homelab-failure-notify $U" > "$W/notify.txt" 2>&1 || true
# a second failure 14 minutes later (someone re-ran the unit by hand)
sf=$R/var/lib/homelab/notify/unit-failed-$U
sed -i -E "s/^(opened|last_ok|last_try)=.*/\1=$(( $(date +%s) - 14 * 60 ))/" "$sf"
run "$export_wake homelab-failure-notify $U" >> "$W/notify.txt" 2>&1 || true
run "mv /home/pi/rsa_key.pem.aside $K && homelab-backup >/dev/null && homelab-notify.sh --resolve unit-failed-$U default '$U OK again' 'The latest run of $U succeeded.'" >> "$W/notify.txt" 2>&1 || true
sed -n 's/^homelab-notify: //p' "$W/notify.txt" > "$OUT/notify-journal.txt"
cp "$R/run/demo-ntfy.txt" "$OUT/ntfy-posts.txt"
cp "$R/run/demo-wake.txt" "$OUT/caretaker-wake.txt"

wc -l "$OUT"/*.txt
