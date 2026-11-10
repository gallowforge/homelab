#!/bin/bash
# homelab-health - the daily check for what Uptime Kuma structurally cannot see.
#
# Kuma answers "does this HTTP endpoint respond". It cannot tell that last
# night's backup was never verified, a container is crash-looping, the USB
# flash root disk just reset, the served TLS cert is stale, a Tailscale node
# key is about to expire, AdGuard stopped answering, or the Pi is throttling.
#
#   homelab-health.sh              check, alert through homelab-notify.sh
#   homelab-health.sh --dry-run    check and print what WOULD be sent; sends
#                                  nothing and writes no state
#
# Runs daily (homelab-health.timer, 07:30, after the 05:00 backups and the
# PC's 06:30 pull). Log: journalctl -u homelab-health
#
# Alerts: one push per CATEGORY (backups, mirror, containers, memory, storage,
# units, reboot, tls, tailscale, dns, power, homeassistant, updates,
# updates-watchtower, reminders, guards, config-drift), deduped by
# homelab-notify.sh (key health-<category>, repeated at most every 20 h while it
# persists - reboot and updates-* weekly, reminders only in the last 3
# days before their date - one all-clear when it clears). Exit 0 = the check ran (problems are
# reported by push, not by exit code); non-zero = the checker itself broke,
# which OnFailure=homelab-failure@ reports.
#
# State (only on real runs): /var/lib/homelab/health/ - time of the last kernel
# log scan (its mtime also tells homelab-heartbeat-gate that a real run
# happened), container restart counts, first-seen times of reboot-required, of
# waiting apt upgrades and of a waiting kernel, the boot already checked for an
# abrupt reset, and the flash stick's lifetime write counter.
set -uo pipefail
export LC_ALL=C

NOTIFY=${HOMELAB_NOTIFY:-/usr/local/bin/homelab-notify.sh}
BACKUP_ENGINE=${HOMELAB_BACKUP_ENGINE:-/usr/local/sbin/homelab-backup}
BACKUP_STATUS=${HOMELAB_BACKUP_STATUS:-/var/lib/homelab/backup-status}
STATE=${HOMELAB_HEALTH_STATE:-/var/lib/homelab/health}
REPO=${HOMELAB_HEALTH_REPO:-/home/pi/docker}
REPO_USER=pi
DOMAIN=raspberrypi.example-tailnet.ts.net
CERT_FILE=/etc/tailscale-certs/$DOMAIN.crt
SERVED_PORT=8452          # Vaultwarden via Caddy - the port that matters most
TIMERS="homelab-backup.timer homelab-health.timer homelab-heartbeat.timer tailscale-cert-renew.timer"
DRY=0
[ "${1:-}" = --dry-run ] && DRY=1
[ "${HOMELAB_HEALTH_DRY_RUN:-0}" = 1 ] && DRY=1

NOW=$(date +%s)
declare -A PROB=()        # PROB[category] = newline-separated problem lines
declare -A PRIO=()        # highest priority seen per category
TOTAL=0
CATEGORIES="backups mirror containers memory storage units reboot tls tailscale dns power homeassistant updates updates-watchtower reminders guards config-drift"
HA_CONFIG=${HOMELAB_HEALTH_HA_CONFIG:-$REPO/homeassistant/config}
HA_PORT=${HOMELAB_HEALTH_HA_PORT:-8443}   # Home Assistant via Caddy
HA_HTTP_STORAGE=${HOMELAB_HEALTH_HA_HTTP:-$HA_CONFIG/.storage/http}
MIRROR_MAX_H=${HOMELAB_HEALTH_MIRROR_MAX_H:-36}      # the PC pulls daily ~06:30: 36 h = a pull was missed
MIRROR_SINCE=${HOMELAB_HEALTH_MIRROR_SINCE:--8d}     # how far back the journal is searched
WRITES_MAX_GIB_DAY=${HOMELAB_HEALTH_WRITES_MAX_GIB_DAY:-20}
GH_API=${HOMELAB_HEALTH_GH_API:-https://api.github.com}
RELEASE_WAIT_DAYS=7       # a newer release must be this old before a notice (hotfixes, image publishing)
REMINDERS=${HOMELAB_HEALTH_REMINDERS:-/etc/homelab/reminders.conf}
VW_RELEASES_API=${HOMELAB_HEALTH_VW_API:-https://api.github.com/repos/dani-garcia/vaultwarden/releases/latest}
VW_BEHIND_DAYS=7          # cooldown is 3 days; a release still missing after 7 = Watchtower is not applying it
WT_CONTAINER=${HOMELAB_HEALTH_WT_CONTAINER:-watchtower}
# Directories whose mode 700 is load-bearing: below them many secret-bearing files
# (HA secrets.yaml, kuma.db, vaultwarden db, ...) are 644 by the apps' own
# choice, so the parent directory is the only thing keeping other accounts out.
# /opt/filebrowser is the parent of the live vault (/opt/filebrowser/data, which is
# never chmod-ed itself): its 700 keeps other accounts out of the personal files.
PRIVATE_DIRS=${HOMELAB_HEALTH_PRIVATE_DIRS:-/home/pi /etc/homelab /opt/filebrowser}

log() { echo "$*"; }
rank() { case "$1" in urgent) echo 5 ;; high) echo 4 ;; default) echo 3 ;; low) echo 2 ;; *) echo 1 ;; esac; }
problem() { # problem <category> <priority> <text>
  local c=$1 p=$2 t=$3
  PROB[$c]+="${t}"$'\n'
  TOTAL=$((TOTAL + 1))
  if [ -z "${PRIO[$c]:-}" ] || [ "$(rank "$p")" -gt "$(rank "${PRIO[$c]}")" ]; then PRIO[$c]=$p; fi
  log "PROBLEM [$c/$p] $t"
}
save_state() { # save_state <file> <content>: real runs only, and only when it changed
  [ "$DRY" = 1 ] && return 0
  install -d -m 700 "$STATE" 2>/dev/null || return 0
  [ -f "$STATE/$1" ] && [ "$(cat "$STATE/$1")" = "$2" ] && return 0
  printf '%s\n' "$2" > "$STATE/$1.tmp" && mv -f "$STATE/$1.tmp" "$STATE/$1"
}
days_until() { # days_until <date string> -> whole days (negative if past)
  local e; e=$(date -d "$1" +%s 2>/dev/null) || return 1
  echo $(( (e - NOW) / 86400 ))
}

# ---- 1. backups: every set in the ONE list, verified recently --------------
if [ -x "$BACKUP_ENGINE" ] && sets=$("$BACKUP_ENGINE" --list-sets 2>&1); then
  n=0
  while IFS=$'\t' read -r name _type _keep maxh; do
    [ -n "$name" ] || continue
    n=$((n + 1))
    sf="$BACKUP_STATUS/$name"
    if [ ! -f "$sf" ]; then
      problem backups high "Backup set '$name' has never been verified (no $sf)"
      continue
    fi
    ep=$(sed -n 's/^epoch=//p' "$sf"); file=$(sed -n 's/^file=//p' "$sf")
    case "$ep" in ''|*[!0-9]*) problem backups high "Backup set '$name': unreadable status file"; continue ;; esac
    age_h=$(( (NOW - ep) / 3600 ))
    if [ "$age_h" -ge "$maxh" ]; then
      problem backups high "Backup set '$name': last verified run ${age_h}h ago (limit ${maxh}h)"
    elif [ ! -s "$file" ]; then
      problem backups high "Backup set '$name': its newest archive $(basename "$file") is gone"
    fi
  done <<< "$sets"
  log "backups: $n sets checked"
else
  problem backups high "homelab-backup --list-sets failed: $(head -c 200 <<< "${sets:-engine missing}")"
fi
if ! systemctl -q is-active homelab-backup.timer; then
  problem backups high "homelab-backup.timer is not active - no nightly backups"
fi

# ---- 1b. mirror: the backups left this flash stick recently ------------------
# ~/backups lives on this flash stick. Two independent copies leave it:
#  - the desktop PC's pi-backup-sync pulls everything daily ~06:30 as
#    `sudo rsync --server --sender`, which sudo logs in the persistent journal;
#  - homelab-backup-push-mac (since 2026-10-21) pushes the travelling sets
#    (not secrets/adhoc/syncthing/dockge) to the MacBook whenever it is
#    reachable and stamps /var/lib/homelab/mirror-mac.
# Either one fresh = fine. Neither = every recent backup exists only here.
last_pull=$(journalctl _COMM=sudo --since "$MIRROR_SINCE" --no-pager -o short-unix 2>/dev/null \
  | grep -F "sudo[" | grep -F " $REPO_USER : " | grep -F 'COMMAND=/usr/bin/rsync --server --sender' | tail -n 1 | cut -d. -f1)
last_mac=$(cat /var/lib/homelab/mirror-mac 2>/dev/null)
case "$last_pull" in ''|*[!0-9]*) pull_h=never ;; *) pull_h="$(( (NOW - last_pull) / 3600 ))h ago" ;; esac
case "$last_mac"  in ''|*[!0-9]*) mac_h=never  ;; *) mac_h="$(( (NOW - last_mac) / 3600 ))h ago" ;; esac
fresh() { [ "$1" != never ] && [ "${1%%h*}" -lt "$MIRROR_MAX_H" ]; }
if ! fresh "$pull_h" && ! fresh "$mac_h"; then
  problem mirror default "No copy of the Pi backups left this flash stick in ${MIRROR_MAX_H}h: the desktop PC last pulled: ${pull_h}; the MacBook last received: ${mac_h}. Both are off or away; it heals by itself when either is on (PC: systemctl --user list-timers pi-backup-sync.timer; Pi: journalctl -u homelab-backup-push-mac)"
fi
log "mirror: last PC pull ${pull_h}, last MacBook push ${mac_h}"

# ---- 2. containers: every container_name declared in ~/docker/*/docker-compose.yml
expected=$(grep -hE '^[[:space:]]*container_name:' "$REPO"/*/docker-compose.yml 2>/dev/null \
  | sed -E 's/^[[:space:]]*container_name:[[:space:]]*["'\'']?([A-Za-z0-9_.-]+).*/\1/' | sort -u)
declare -A RC_OLD=()
if [ -f "$STATE/restart-counts" ]; then
  while read -r c v; do [ -n "$c" ] && RC_OLD[$c]=$v; done < "$STATE/restart-counts"
fi
rc_new=""
if ! timeout 20 docker info >/dev/null 2>&1; then
  problem containers urgent "Docker is not answering (docker info failed)"
else
  n=0
  for c in $expected; do
    n=$((n + 1))
    info=$(timeout 20 docker inspect -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{.RestartCount}}' "$c" 2>/dev/null)
    if [ -z "$info" ]; then problem containers high "Container $c is MISSING (declared in a compose file, does not exist)"; continue; fi
    IFS='|' read -r st hs rcount <<< "$info"
    [ "$st" = running ] || problem containers high "Container $c is $st"
    [ "$hs" = unhealthy ] && problem containers high "Container $c is unhealthy"
    old=${RC_OLD[$c]:-}
    if [ -n "$old" ] && [ "${rcount:-0}" -gt "$old" ]; then
      problem containers default "Container $c crashed and was auto-restarted $(( rcount - old ))x since the last check"
    fi
    rc_new+="$c ${rcount:-0}"$'\n'
  done
  for c in $(timeout 20 docker ps -a --filter status=restarting --filter status=dead --format '{{.Names}}' 2>/dev/null); do
    grep -qxF -- "$c" <<< "$expected" || problem containers default "Undeclared container $c is restarting or dead"
  done
  save_state restart-counts "${rc_new%$'\n'}"
  log "containers: $n declared, checked"
  # A bind-mounted docker.sock goes stale when dockerd is restarted: the container keeps the
  # old deleted socket and "Cannot connect to the Docker daemon" while looking healthy
  # (Watchtower failed its 05:30 run two mornings in a row, 2026-10-03/04). Fix: docker restart <it>.
  host_sock=$(stat -c %i /var/run/docker.sock 2>/dev/null)
  for c in $(timeout 20 docker ps --format '{{.Names}}' 2>/dev/null); do
    timeout 20 docker inspect -f '{{range .Mounts}}{{.Source}} {{end}}' "$c" 2>/dev/null | grep -qw /var/run/docker.sock || continue
    cpid=$(timeout 20 docker inspect -f '{{.State.Pid}}' "$c" 2>/dev/null)
    seen=$(stat -c %i "/proc/$cpid/root/var/run/docker.sock" 2>/dev/null)
    if [ -n "$host_sock" ] && [ -n "$seen" ] && [ "$seen" != "$host_sock" ]; then
      problem containers default "Container $c holds a stale docker.sock (dockerd was restarted since it started); it cannot reach Docker. Fix: docker restart $c"
    fi
  done
fi

# ---- 2b. memory (2026-10-20: a leaking HyperHDR left 55 MB free, the Pi swapped to the stick
# and DNS crawled for the whole house; nothing here noticed). Names the biggest process.
avail=$(( $(awk '/^MemAvailable/{print $2}' /proc/meminfo) / 1024 ))
if [ "$avail" -lt 800 ]; then
  top_proc=$(ps -eo rss=,comm= --sort=-rss | head -1 | awk '{printf "%s %d MB", $2, $1/1024}')
  problem memory high "Only ${avail} MB of memory available (biggest: ${top_proc}); the Pi will start swapping and DNS slows for the house"
fi

# ---- 3. storage: space, inodes, ext4 errors, read-only, kernel log, USB link
read -r used iused <<< "$(df --output=pcent,ipcent / | tail -1 | tr -d '%')"
free=$(df -h --output=avail / | tail -1 | tr -d ' ')
[ "${used:-0}" -ge 85 ] && problem storage high "Root disk ${used}% full (${free} free)"
[ "${iused:-0}" -ge 85 ] && problem storage high "Root disk inodes ${iused}% used"
bused=$(df --output=pcent /boot/firmware 2>/dev/null | tail -1 | tr -dc '0-9')
[ "${bused:-0}" -ge 90 ] && problem storage default "/boot/firmware ${bused}% full (kernel updates will fail)"
rootdev=$(findmnt -n -o SOURCE /); rootname=${rootdev##*/}
if findmnt -n -o OPTIONS / | grep -qE '(^|,)ro(,|$)'; then
  problem storage urgent "Root filesystem is mounted READ-ONLY"
fi
errs=$(cat "/sys/fs/ext4/$rootname/errors_count" 2>/dev/null || echo 0)
[ "${errs:-0}" -gt 0 ] && problem storage high "ext4 on $rootdev has recorded $errs errors (errors_count; see tune2fs -l)"
last_scan=$(cat "$STATE/kernel-scan" 2>/dev/null)
case "$last_scan" in ''|*[!0-9]*) last_scan=$(( NOW - 86400 )) ;; esac
klines=$(journalctl _TRANSPORT=kernel --since "@$last_scan" --until "@$NOW" -o short-iso --no-pager 2>/dev/null \
  | grep -iE 'reset (high|super|full|low)[+-]?speed usb device|usb [0-9-]+: device descriptor read|I/O error|EXT4-fs (error|warning)|blk_update_request|critical medium error|Undervoltage detected|over-current')
if [ -n "$klines" ]; then
  problem storage high "Kernel reported $(grep -c . <<< "$klines") disk/USB/power event(s) since $(date -d "@$last_scan" '+%F %H:%M'):
$(tail -n 5 <<< "$klines" | cut -c1-160)"
fi
save_state kernel-scan "$NOW"
dev=$(readlink -f "/sys/class/block/${rootname%%[0-9]*}/device" 2>/dev/null)
speed=""
while [ -n "$dev" ] && [ "$dev" != / ]; do
  if [ -f "$dev/speed" ] && [ -f "$dev/devnum" ]; then speed=$(cat "$dev/speed"); break; fi
  dev=$(dirname "$dev")
done
if [ -n "$speed" ] && [ "${speed%%.*}" -lt 5000 ]; then
  problem storage default "Root disk USB link is ${speed} Mbit/s instead of 5000 (USB 3). The stick got nudged or sits in a black port: about 10x slower, nothing is broken. Fix when the owner is home: clean poweroff, wait for the red LED, push the stick firmly into a BLUE port, power on"
fi
log "storage: ${used}% used, inodes ${iused}%, ext4 errors ${errs}, root disk link ${speed:-?}M, kernel events since last scan: $(grep -c . <<< "$klines")"
# Write volume on the flash stick: ext4's lifetime counter (KiB). State is
# '<epoch> <KiB>', refreshed at most every 20 h, so the rate covers about a day.
wk=$(cat "/sys/fs/ext4/$rootname/lifetime_write_kbytes" 2>/dev/null)
case "$wk" in ''|*[!0-9]*) wk="" ;; esac
if [ -n "$wk" ]; then
  wprev=$(cat "$STATE/writes-last" 2>/dev/null)
  wprev_t=${wprev%% *}; wprev_k=${wprev##* }
  case "$wprev_t" in ''|*[!0-9]*) wprev_t="" ;; esac
  case "$wprev_k" in ''|*[!0-9]*) wprev_t="" ;; esac
  if [ -z "$wprev_t" ] || [ "$wk" -lt "$wprev_k" ] || [ "$wprev_t" -gt "$NOW" ]; then
    wrate="no usable baseline yet (recorded now on a real run)"
    save_state writes-last "$NOW $wk"
  else
    wdt=$(( NOW - wprev_t ))
    if [ "$wdt" -ge 72000 ]; then
      wgib=$(( (wk - wprev_k) * 86400 / wdt / 1048576 ))
      wrate="${wgib} GiB/day over the last $(( wdt / 3600 ))h"
      # A bulk vault sync (100+ files in the window) explains the writes when
      # they stay within the usual limit plus 5x the synced content (Syncthing
      # writes a temp copy, renames, updates its index: 1.8x-4x seen) and clears
      # alone: say so at low priority. 2026-11-05: 249 large files = 23 GiB/day;
      # 2026-11-07: 13,669 files / 70.7 GiB = 130 GiB/day, both alerted at
      # default priority for nothing.
      wsync=$(docker logs syncthing --since "${wdt}s" 2>&1 | grep 'Synced file' | grep -oP 'file\.size=\K[0-9]+' | awk '{n++; s+=$1} END {printf "%d %d", n, s/1073741824}')
      wsync_n=${wsync% *}; wsync_g=${wsync#* }
      wwin=$(( (wk - wprev_k) / 1048576 ))
      if [ "$wgib" -ge "$WRITES_MAX_GIB_DAY" ] && [ "${wsync_n:-0}" -ge 100 ] && [ "$wwin" -le $(( WRITES_MAX_GIB_DAY * wdt / 86400 + 5 * ${wsync_g:-0} )) ]; then
        problem storage low "The flash stick took ${wgib} GiB/day of writes over the last $(( wdt / 3600 ))h (limit ${WRITES_MAX_GIB_DAY}), explained by a bulk Syncthing vault sync (${wsync_n} files, ${wsync_g} GiB of content synced in that window; it costs up to several times the content in writes and clears by itself). Nothing to do unless it repeats without a sync."
      elif [ "$wgib" -ge "$WRITES_MAX_GIB_DAY" ]; then
        problem storage default "The root flash stick took ${wgib} GiB/day of writes over the last $(( wdt / 3600 ))h (limit ${WRITES_MAX_GIB_DAY}). It is a USB flash stick that wears out and loses recent writes on an abrupt reset. Check the BENIGN cause first: a bulk Syncthing vault sync, which clears by itself - Syncthing writes a temp copy then renames and updates its index, so adding N GiB to the vault costs several times N in flash writes (2026-09-22: 3,624 files / 5.7 GiB of content = ~23 GiB of writes). Count it with: docker logs syncthing --since 24h 2>&1 | grep -c 'Synced file'. Per process: sudo sh -c 'grep -H write_bytes /proc/[0-9]*/io' | sort -t' ' -k2 -n | tail"
      fi
      save_state writes-last "$NOW $wk"
    else
      wrate="$(( (wk - wprev_k) / 1048576 )) GiB in $(( wdt / 3600 ))h (judged once 20h have passed)"
    fi
  fi
  log "storage: lifetime writes $(( wk / 1048576 )) GiB, ${wrate}"
fi

# ---- 3b. boot: did the Pi come back from an ABRUPT reset? --------------------
# Checked once per boot (boot_id). In wtmp the newest two reboot/shutdown records
# read "reboot reboot" when the previous boot never wrote a shutdown record, i.e.
# a power cut, a watchdog or a hang. The flash stick loses writes from up to ~2
# minutes before such a reset, so it needs the README damage checks.
bid=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
if [ -n "$bid" ] && [ "$(cat "$STATE/boot-checked" 2>/dev/null)" != "$bid" ]; then
  recs=$(last -xF 2>/dev/null | awk '$1=="reboot"||$1=="shutdown"{print $1}' | head -n 2 | tr '\n' ' ')
  if [ "$recs" = "reboot reboot " ]; then
    problem storage high "The Pi came back from an ABRUPT reset or power cut at $(uptime -s) (no clean shutdown record). The USB flash stick loses writes from up to ~2 minutes before a reset: run the README checks from the 2026-09-17 R2 entry (docker log NUL grep, git -C ~/docker fsck --full, cmp /boot/firmware/cmdline.txt /boot/firmware/cmdline.txt.pre-fsck-2026-09-17, ext4 errors) and look for the cause (under-voltage, kernel log of the previous boot: journalctl -b -1 -k | tail)"
  fi
  log "boot: first check of this boot (up since $(uptime -s)); newest wtmp records [${recs% }]"
  save_state boot-checked "$bid"
else
  log "boot: this boot (up since $(uptime -s)) was already checked"
fi

# ---- 4. systemd: failed units, homelab timers ------------------------------
failed=$(systemctl list-units --failed --plain --no-legend --no-pager 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
[ -n "${failed// /}" ] && problem units default "Failed systemd units: $failed"
for t in $TIMERS; do
  systemctl -q is-active "$t" || problem units high "Timer $t is not active"
done
# Hue screen sync (2026-10-18): the lamps follow the TV only while both run (low: comfort, not data)
for u in hyperhdr@hyperhdr.service tv-mood.service; do
  systemctl -q is-active "$u" || problem units low "$u is not running: the Hue lamps no longer follow the TV picture (sudo systemctl restart $u; docs/tv-ambient-lighting.md)"
done
log "units: failed=[${failed% }]"

# ---- 5. pending reboot older than 7 days -----------------------------------
if [ -f /var/run/reboot-required ]; then
  first=$(cat "$STATE/reboot-required-since" 2>/dev/null)
  case "$first" in ''|*[!0-9]*) first=$(stat -c %Y /var/run/reboot-required); save_state reboot-required-since "$first" ;; esac
  if [ $(( (NOW - first) / 86400 )) -ge 7 ]; then
    pk=$(tr '\n' ' ' < /var/run/reboot-required.pkgs 2>/dev/null)
    problem reboot low "A reboot has been pending for $(( (NOW - first) / 86400 )) days (${pk:-packages unknown}). Needs the owner at home: no SD-card recovery."
  fi
else
  [ -f "$STATE/reboot-required-since" ] && [ "$DRY" = 0 ] && rm -f "$STATE/reboot-required-since"
fi

# ---- 6. TLS: the cert on disk AND the cert Caddy actually serves -----------
file_end=""; served_end=""
if [ -r "$CERT_FILE" ]; then
  file_end=$(openssl x509 -enddate -noout -in "$CERT_FILE" 2>/dev/null | cut -d= -f2)
fi
served_end=$(echo | timeout 15 openssl s_client -connect "127.0.0.1:$SERVED_PORT" -servername "$DOMAIN" 2>/dev/null \
  | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
if [ -z "$served_end" ]; then
  problem tls high "Caddy is not serving TLS for $DOMAIN on :$SERVED_PORT"
else
  sd=$(days_until "$served_end")
  [ "${sd:-0}" -lt 14 ] && problem tls high "The TLS cert Caddy serves on :$SERVED_PORT expires in ${sd} days"
  if [ -n "$file_end" ]; then
    fe=$(date -d "$file_end" +%s 2>/dev/null || echo 0); se=$(date -d "$served_end" +%s 2>/dev/null || echo 0)
    [ $(( fe - se )) -gt 86400 ] && problem tls high "Caddy serves an OLDER cert (until $served_end) than the renewed one on disk (until $file_end): reload with --force"
  fi
fi
[ -n "$file_end" ] || problem tls default "Cert file $CERT_FILE unreadable"
log "tls: file until [${file_end}], served on :$SERVED_PORT until [${served_end}]"

# ---- 7. Tailscale: host node (read-only) ------------------------------------
ts_parse='import json,sys,datetime
try:
    d=json.load(sys.stdin); s=d.get("Self") or {}
    k=s.get("KeyExpiry") or ""
    days=""
    if k and not k.startswith("0001"):
        e=datetime.datetime.fromisoformat(k.replace("Z","+00:00"))
        days=str(int((e-datetime.datetime.now(datetime.timezone.utc)).total_seconds()//86400))
    print("%s|%s|%s" % (d.get("BackendState",""), s.get("Online",""), days))
except Exception:
    print("||")'
check_ts() { # check_ts <label> <json>
  local label=$1 st on days
  IFS='|' read -r st on days <<< "$(python3 -c "$ts_parse" <<< "$2")"
  [ "$st" = Running ] || { problem tailscale high "Tailscale ($label) backend state is '${st:-unknown}'"; return; }
  [ "$on" = True ] || problem tailscale high "Tailscale ($label) is not online"
  if [ -n "$days" ] && [ "$days" -lt 21 ]; then
    problem tailscale high "Tailscale node key ($label) expires in $days days - disable key expiry in the admin console"
  fi
  log "tailscale ($label): $st, online=$on, key expires in ${days:-never (expiry disabled)} days"
}
check_ts "raspberrypi host" "$(timeout 20 tailscale status --json 2>/dev/null)"

# ---- 8. DNS: AdGuard is the whole house's resolver --------------------------
dns_ok=0
for name in example.com cloudflare.com; do
  out=$(dig +time=3 +tries=2 +noall +comments +answer @127.0.0.1 "$name" A 2>/dev/null)
  if grep -q 'status: NOERROR' <<< "$out" && grep -qE '[[:space:]]IN[[:space:]]+A[[:space:]]' <<< "$out"; then dns_ok=1; break; fi
done
[ "$dns_ok" = 1 ] || problem dns urgent "AdGuard is not answering DNS on 127.0.0.1:53 - the whole house has no DNS"
log "dns: 127.0.0.1:53 answering=$dns_ok"

# ---- 9. power / thermal ------------------------------------------------------
thr=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2)
temp=$(( $(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0) / 1000 ))
if [ -n "$thr" ]; then
  v=$(( thr ))
  (( v & 0xF )) && problem power high "Pi is throttled NOW (get_throttled=$thr: bit0 under-voltage, bit1 freq capped, bit2 throttled, bit3 soft temp limit)"
  (( (v & 0xF) == 0 && (v & 0xF0000) )) && problem power default "Pi was throttled or under-voltage earlier this boot (get_throttled=$thr) - check the PSU/cable"
fi
[ "$temp" -ge 80 ] && problem power high "SoC temperature ${temp}C"
log "power: throttled=${thr:-?} temp=${temp}C"

# ---- 11b. Home Assistant behind Caddy: proxy trust and IP bans --------------
# HA trusts X-Forwarded-For only from the docker 'proxy' network (set in
# config/.storage/http, NOT configuration.yaml) and bans a client IP after 10
# failed logins or bad tokens. Kuma checks HA on the LAN only; a broken proxy
# trust (every Caddy request 400) or a ban (403 for that device, forever) would
# otherwise go unnoticed. Public /manifest.json only: an unauthenticated /api
# request is itself a failed login (this check counts as client 172.30.0.1).
ha_code=$(curl -s -o /dev/null -m 20 -w '%{http_code}' --resolve "$DOMAIN:$HA_PORT:127.0.0.1" \
  "https://$DOMAIN:$HA_PORT/manifest.json" 2>/dev/null)
case "$ha_code" in
  200) ;;
  400) problem homeassistant high "Home Assistant via Caddy :$HA_PORT answers 400: HA no longer trusts Caddy as a proxy. trusted_proxies in $HA_CONFIG/.storage/http must cover the docker 'proxy' network (docs/backups-and-restore.md, Home Assistant)" ;;
  403) problem homeassistant high "Home Assistant via Caddy :$HA_PORT answers 403: this Pi's Caddy path (client 172.30.0.1) is banned in $HA_CONFIG/ip_bans.yaml" ;;
  000|'') problem homeassistant high "Home Assistant via Caddy :$HA_PORT does not answer at all (Caddy down?)" ;;
  *) problem homeassistant high "Home Assistant via Caddy :$HA_PORT answers HTTP $ha_code (502 = HA itself is down)" ;;
esac
ha_bans=""
if [ -s "$HA_CONFIG/ip_bans.yaml" ]; then
  ha_bans=$(sed -nE "s/^'?([0-9A-Fa-f.:]+)'?:[[:space:]]*$/\1/p" "$HA_CONFIG/ip_bans.yaml" | sort -u | tr '\n' ' ')
  ha_bans=${ha_bans% }
  [ -n "$ha_bans" ] && problem homeassistant default "Home Assistant has banned: $ha_bans (10 failed logins or bad tokens; that device now gets 403). If it is yours: delete its lines from $HA_CONFIG/ip_bans.yaml (sudo), then docker restart homeassistant"
fi
log "homeassistant: via Caddy :$HA_PORT -> ${ha_code:-none}, banned=[${ha_bans}]"
# The trust and ban settings themselves. Restoring an HA backup from before
# 2026-09-17 silently brings back trusted_proxies 172.16.0.0/12 and no ban
# threshold; Caddy still gets 200 then, so the probe above cannot see it.
# 'pending' (applied at HA's next restart) is checked too when HA has one.
ha_http=$(python3 - "$HA_HTTP_STORAGE" <<'PY' 2>/dev/null
import json, sys
try:
    data = json.load(open(sys.argv[1]))["data"]
    stable = data["stable"]
except Exception as e:
    print("ERR|%s" % type(e).__name__); sys.exit(0)
for name, part in (("stable", stable), ("pending", data.get("pending"))):
    if isinstance(part, dict):
        print("%s|%s|%s" % (name, ",".join(part.get("trusted_proxies") or []), part.get("login_attempts_threshold")))
PY
)
ha_http_log=""
if [ -z "$ha_http" ] || [ "${ha_http%%|*}" = ERR ]; then
  problem homeassistant default "Cannot read Home Assistant's $HA_HTTP_STORAGE (${ha_http#ERR|}): proxy trust and ban threshold not verified"
else
  while IFS='|' read -r ha_part ha_tp ha_thr; do
    ha_http_log+="${ha_http_log:+; }$ha_part: trusted_proxies=[$ha_tp] threshold=$ha_thr"
    if [ "$ha_tp" != "172.30.0.0/24" ] || [ "$ha_thr" != 10 ]; then
      problem homeassistant high "Home Assistant .storage/http ($ha_part) has trusted_proxies [$ha_tp] and login_attempts_threshold $ha_thr; expected [172.30.0.0/24] and 10 (an HA backup from before 2026-09-17 restored?). Re-apply with HA stopped (Settings > System > Network, or .storage/http)"
    fi
  done <<< "$ha_http"
fi
log "homeassistant: .storage/http ${ha_http_log:-not readable}"

# ---- 12. updates: Vaultwarden follows :latest (Watchtower auto, 3-day cooldown) --
# Two things would otherwise stay silent: a new MAJOR release on its way in (applied
# ~3 days after its image is built unless held), and a release that Watchtower never
# applies (deferred/failed sessions only produce low-priority notices). One GitHub
# API read (no pull, no registry call); an unreachable API is logged, never alerted.
vw_img=$(timeout 20 docker inspect -f '{{.Image}}' vaultwarden 2>/dev/null)
vw_run=${HOMELAB_HEALTH_VW_RUNNING:-}
[ -z "$vw_run" ] && [ -n "$vw_img" ] && \
  vw_run=$(timeout 20 docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$vw_img" 2>/dev/null)
if [ -z "$vw_run" ]; then
  log "updates: vaultwarden version unknown (container missing?) - release check skipped"
else
  IFS='|' read -r vw_state vw_latest vw_age <<< "$(curl -s -m 20 -H 'Accept: application/vnd.github+json' "$VW_RELEASES_API" 2>/dev/null \
    | python3 -c 'import datetime,json,re,sys
def ver(s):
    m = re.match(r"^v?(\d+)\.(\d+)\.(\d+)", s or "")
    return tuple(int(x) for x in m.groups()) if m else None
try:
    d = json.load(sys.stdin)
    tag = str(d["tag_name"])
    pub = datetime.datetime.fromisoformat(str(d["published_at"]).replace("Z", "+00:00"))
    age = int((datetime.datetime.now(datetime.timezone.utc) - pub).total_seconds() // 86400)
except Exception:
    print("unknown||"); sys.exit(0)
run, new = ver(sys.argv[1]), ver(tag)
if not run or not new or d.get("draft") or d.get("prerelease"):
    state = "unknown"
elif new[0] > run[0]:
    state = "major"
elif new > run:
    state = "behind"
else:
    state = "ok"
print("%s|%s|%d" % (state, tag, age))' "$vw_run" 2>/dev/null)"
  case "$vw_state" in
    major) problem updates high "Vaultwarden $vw_latest is a new MAJOR version (running $vw_run), released $vw_age day(s) ago. Watchtower applies it by itself at 05:30 once its image is 3 days old. Read https://github.com/dani-garcia/vaultwarden/releases first. To hold: in vaultwarden/docker-compose.yml set image: vaultwarden/server:$vw_run, commit, docker compose up -d vaultwarden" ;;
    behind)
      if [ "${vw_age:-0}" -ge "$VW_BEHIND_DAYS" ]; then
        problem updates default "Vaultwarden runs $vw_run but $vw_latest was released $vw_age days ago and is still not applied (cooldown is 3 days). Check: docker logs watchtower --since 72h | grep -i vaultwarden"
      fi ;;
  esac
  log "updates: vaultwarden running $vw_run, latest release ${vw_latest:-?} (${vw_age:-?} days old) -> ${vw_state:-unknown}"
fi

# ---- 12b. packages that only a human installs ---------------------------------
# unattended-upgrades installs Debian-Security only (docker-ce is blacklisted
# there) and the docker, tailscale and archive.raspberrypi.com repos are not
# allowed at all, so dockerd, tailscaled and the Raspberry Pi kernel/firmware never
# update by themselves and nothing else mentions them. Reads the apt lists that
# apt-daily refreshes; installs nothing.
upg_all=$(apt list --upgradable 2>/dev/null | awk -F/ 'NF>1{print $1}' | sort -u)
# Pi firmware (raspi-firmware writes /boot/firmware, rpi-eeprom stages a bootloader
# update for the next boot) is installed only with the owner at the Pi, like the
# kernel, so it does not belong in the "waiting for a manual upgrade" nag (2026-10-02).
upg=$(grep -vE '^(linux-(image|headers)-|raspi-firmware$|rpi-eeprom$)' <<< "$upg_all" | grep . | tr '\n' ' '); upg=${upg% }
fw=$(grep -E '^(raspi-firmware|rpi-eeprom)$' <<< "$upg_all" | tr '\n' ' '); fw=${fw% }
kern=$(grep -E '^linux-image-rpi-(2712|v8)$' <<< "$upg_all" | tr '\n' ' '); kern=${kern% }
if [ -n "$upg" ]; then
  since=$(cat "$STATE/apt-upgradable-since" 2>/dev/null)
  case "$since" in ''|*[!0-9]*) since=$NOW; save_state apt-upgradable-since "$since" ;; esac
  age=$(( (NOW - since) / 86400 ))
  # Security updates are supposed to install themselves (unattended-upgrades).
  # On 2026-09-18 two Debian-Security packages (xz-utils, liblzma5) sat pending for
  # ~14 h and had to be installed by hand, with the origin patterns verified correct,
  # so the silent-miss case gets its own, much tighter alert.
  sec=$(apt list --upgradable 2>/dev/null | awk -F/ 'NR>1 && $2 ~ /security/ {print $1}' | sort -u | tr '\n' ' ')
  sec=${sec% }
  if [ -n "$sec" ]; then
    ss=$(cat "$STATE/apt-security-since" 2>/dev/null)
    case "$ss" in ''|*[!0-9]*) ss=$NOW; save_state apt-security-since "$ss" ;; esac
    sh=$(( (NOW - ss) / 3600 ))
    if [ "$sh" -ge 26 ]; then
      problem updates high "SECURITY update(s) pending for ${sh}h and unattended-upgrades has not applied them: $(cut -c1-200 <<< "$sec"). It normally installs these by itself within a day. Install now: sudo apt-get -y -o Dpkg::Options::=--force-confold install $sec ; then check why: sudo unattended-upgrade --dry-run --debug 2>&1 | tail -20 and journalctl -u apt-daily-upgrade --since -3d"
    fi
  else
    [ "$DRY" = 0 ] && rm -f "$STATE/apt-security-since"
  fi
  if [ "$age" -ge 7 ]; then
    problem updates low "$(wc -w <<< "$upg") package(s) have waited ${age} days for a manual upgrade: $(cut -c1-300 <<< "$upg"). Install at a quiet hour: sudo apt-get --with-new-pkgs upgrade. docker-ce restarts dockerd (live-restore keeps the containers running; container DNS pauses for seconds); a kernel/firmware reboot needs the owner at home"
  fi
else
  [ "$DRY" = 0 ] && rm -f "$STATE/apt-upgradable-since"
fi
if [ -n "$kern" ]; then
  ks=$(cat "$STATE/kernel-pending-since" 2>/dev/null)
  case "$ks" in ''|*[!0-9]*) ks=$NOW; save_state kernel-pending-since "$ks" ;; esac
  kd=$(( (NOW - ks) / 86400 ))
  if [ "$kd" -ge 7 ]; then
    problem reboot default "A new Raspberry Pi kernel ($kern) has waited ${kd} days. It installs only by hand (sudo apt-get --with-new-pkgs upgrade) and takes effect at a clean reboot with the owner at home: the root flash stick loses writes on an abrupt reset. Combine it with a forced fsck of the root filesystem"
  fi
else
  [ "$DRY" = 0 ] && rm -f "$STATE/kernel-pending-since"
fi
if [ -n "$fw" ]; then
  fs=$(cat "$STATE/firmware-pending-since" 2>/dev/null)
  case "$fs" in ''|*[!0-9]*) fs=$NOW; save_state firmware-pending-since "$fs" ;; esac
  fd=$(( (NOW - fs) / 86400 ))
  if [ "$fd" -ge 30 ]; then
    problem reboot low "Raspberry Pi firmware update(s) ($fw) have waited ${fd} days. Install only with the owner at the Pi (it writes /boot/firmware / stages a bootloader update): sudo apt-get install --only-upgrade $fw, then a clean reboot (sudo systemctl poweroff/reboot), combined with any pending kernel"
  fi
else
  [ "$DRY" = 0 ] && rm -f "$STATE/firmware-pending-since"
fi
log "updates: apt upgradable=[$upg] kernel=[$kern] firmware=[$fw]"

# ---- 12c. release watch for images whose tag says nothing -----------------------
# Watchtower runs on :latest and updates itself; this confirms it really does.
# One GitHub API read each (no pull, no registry call, nothing recreated). A notice
# only once the first release newer than the running one is RELEASE_WAIT_DAYS
# old (hotfixes land, images get published); an unreachable API is logged only.
release_watch() { # release_watch <category> <label> <owner/repo> <running x.y.z> <even-minor 0|1> <how to update>
  local rcat=$1 label=$2 repo=$3 run=$4 even=$5 how=$6 state newest first age
  if [ -z "$run" ]; then log "$rcat: $label running version unknown - release check skipped"; return 0; fi
  IFS='|' read -r state newest first age <<< "$(curl -s -m 20 -H 'Accept: application/vnd.github+json' \
      "$GH_API/repos/$repo/releases?per_page=30" 2>/dev/null | python3 -c 'import datetime, json, re, sys
def ver(s):
    m = re.match(r"^v?(\d+)\.(\d+)\.(\d+)$", s or "")
    return tuple(int(x) for x in m.groups()) if m else None
run, wait, even = ver(sys.argv[1]), int(sys.argv[2]), sys.argv[3] == "1"
try:
    rels = json.load(sys.stdin)
    assert isinstance(rels, list) and run
except Exception:
    print("unknown|||"); sys.exit(0)
now = datetime.datetime.now(datetime.timezone.utc)
newest, newer = None, []
for r in rels:
    v = ver(str(r.get("tag_name", "")))
    if not v or r.get("draft") or r.get("prerelease") or (even and v[1] % 2):
        continue
    try:
        pub = datetime.datetime.fromisoformat(str(r["published_at"]).replace("Z", "+00:00"))
    except Exception:
        continue
    if newest is None or v > newest:
        newest = v
    if v > run:
        newer.append((pub, v))
if newest is None:
    print("unknown|||"); sys.exit(0)
fmt = lambda v: "%d.%d.%d" % v
if not newer:
    print("ok|%s||" % fmt(newest)); sys.exit(0)
pub, v = min(newer)
age = int((now - pub).total_seconds() // 86400)
print("%s|%s|%s|%d" % ("due" if age >= wait else "waiting", fmt(newest), fmt(v), age))' "$run" "$RELEASE_WAIT_DAYS" "$even" 2>/dev/null)"
  if [ "$state" = due ]; then
    problem "$rcat" low "$label $newest is available (running $run; the first newer release, $first, came out $age days ago). $how"
  fi
  log "$rcat: $label running $run, newest stable ${newest:-?} -> ${state:-unknown}${first:+ (first newer $first, $age days old)}"
}
# :latest says nothing about the version; Watchtower's image carries it as a label.
wt_run=${HOMELAB_HEALTH_WT_RUNNING:-$(timeout 20 docker inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$WT_CONTAINER" 2>/dev/null)}
release_watch updates-watchtower Watchtower nicholas-fedor/watchtower "$wt_run" 0 \
  "Watchtower updates itself (:latest, label enable=true) after the cooldown; if it is still behind after a few days check its 05:30 log (docker logs watchtower)."

# ---- 12d. reminders: dated owner actions that nothing else watches -----------
# /etc/homelab/reminders.conf, one per line: name|YYYY-MM-DD|what happens then.
# silent until 3 days before the date (renewals are done by hand), then high priority daily until the date is moved.
if [ -r "$REMINDERS" ]; then
  while IFS='|' read -r rname rdate rtext; do
    case "$rname" in ''|'#'*) continue ;; esac
    if ! rdays=$(days_until "$rdate 00:00"); then
      problem reminders default "reminders.conf: '$rname' has an unreadable date '$rdate'"
      continue
    fi
    if [ "$rdays" -lt 0 ]; then rwhen="was due $(( -rdays )) day(s) ago ($rdate)"; else rwhen="due in $rdays day(s) ($rdate)"; fi
    rhint="Once handled, put the next date in ~/docker/_host/etc/homelab/reminders.conf, commit, _host/install.sh --apply."
    if [ "$rdays" -le 3 ]; then
      problem reminders high "$rname $rwhen: $rtext. $rhint"
    fi
    log "reminders: $rname in $rdays days ($rdate)"
  done < "$REMINDERS"
else
  log "reminders: no $REMINDERS"
fi

# ---- 13. guards: invariants whose loss is silent until it hurts --------------
# Private parent directories (see PRIVATE_DIRS above).
for d in $PRIVATE_DIRS; do
  if [ ! -d "$d" ]; then
    problem guards default "Private directory $d is missing"
    continue
  fi
  m=$(stat -c '%a' "$d" 2>/dev/null)
  if [ -n "$m" ] && [ $(( 8#$m & 8#077 )) -ne 0 ]; then
    problem guards high "$d is mode $m: it must stay 700 - the secret-bearing files below it (app DBs, HA secrets.yaml, kuma.db) are 644 and only this directory keeps other accounts out. Fix: sudo chmod 700 $d"
  fi
done
log "guards: private dirs $(for d in $PRIVATE_DIRS; do printf '%s=%s ' "$d" "$(stat -c %a "$d" 2>/dev/null || echo missing)"; done)"

# ---- 11. config drift: live host files vs ~/docker/_host, uncommitted edits --
# Reads _host/MANIFEST as data; never executes anything from the user-owned repo.
drift=""
while read -r path fmode owner _group _after; do
  case "$path" in ''|'#'*|ignore) continue ;; esac
  if [ "$fmode" = crontab ]; then
    [ "$(crontab -u "$owner" -l 2>/dev/null)" = "$(cat "$REPO/_host/$path" 2>/dev/null)" ] || drift+="$path "
    continue
  fi
  cmp -s "$REPO/_host/$path" "/$path" 2>/dev/null || drift+="/$path "
done < "$REPO/_host/MANIFEST"
[ -n "$drift" ] && problem config-drift low "Live host files differ from ~/docker/_host (run _host/install.sh): $drift"
dirty=$(timeout 30 runuser -u "$REPO_USER" -- git -C "$REPO" status --porcelain 2>/dev/null | grep -c .)
[ "${dirty:-0}" -gt 0 ] && problem config-drift low "$REPO has $dirty uncommitted change(s) (git status)"
log "config: drifted=[${drift% }] uncommitted=${dirty:-?}"

# ---- 14. netprobe: evidence for "is it the ISP?" (homelab-netprobe.timer, RAM) ----
# The reading is printed, never pushed: the ISP is not ours to fix. Only a sampler
# that stopped is a (low) problem, because then the evidence is gone when it is needed.
NP=/run/homelab/netprobe.tsv
if [ -s "$NP" ] && [ $(( $(date +%s) - $(stat -c %Y "$NP") )) -lt 1800 ]; then
  log "$(timeout 20 /usr/local/bin/homelab-netprobe summary 2>&1 | head -c 400)"
elif [ "$(cut -d. -f1 /proc/uptime)" -gt 1800 ] && [ ! -e /run/homelab/maintenance ]; then
  problem guards low "homelab-netprobe has written no sample to $NP for 30 min (systemctl status homelab-netprobe.timer): the evidence for 'is it the ISP?' is not being kept."
else
  log "netprobe: no fresh samples yet (just booted or maintenance)"
fi

# ---- report ------------------------------------------------------------------
for c in $CATEGORIES; do
  if [ -n "${PROB[$c]:-}" ]; then
    case "$c" in
      reboot|updates-*) every=168 ;;
      reminders) every=72; [ "${PRIO[$c]}" = high ] && every=20 ;;
      *) every=20 ;;
    esac
    title="Homelab: $c needs attention"
    if [ "$DRY" = 1 ]; then
      log "DRY-RUN would send: key=health-$c prio=${PRIO[$c]} every=${every}h title=\"$title\""
      printf '%s' "${PROB[$c]}" | sed 's/^/          | /'
    else
      "$NOTIFY" --key "health-$c" --every "$every" "${PRIO[$c]}" "$title" "${PROB[$c]%$'\n'}"
    fi
  elif [ "$DRY" = 0 ]; then
    "$NOTIFY" --resolve "health-$c" default "Homelab: $c OK again" "homelab-health found no $c problems any more."
  fi
done

if [ "$TOTAL" -eq 0 ]; then
  log "all healthy - staying quiet"
else
  log "$TOTAL problem(s) found$([ "$DRY" = 1 ] && echo ' (dry run: nothing sent, no state written)')"
fi
exit 0
