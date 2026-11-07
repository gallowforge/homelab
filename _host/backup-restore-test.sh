#!/bin/bash
# backup-restore-test.sh - restore the NEWEST archive of every backup set into
# RAM (/dev/shm, so the USB flash root disk takes no writes) and prove it is
# usable - not just that a file exists:
#   sqlite  : PRAGMA integrity_check = ok, the set's `count` table has rows
#             (compared with live), vaultwarden rsa_key.pem identical to live
#   dir     : key files present and parse (AdGuard yaml, CouchDB .couch count,
#             Syncthing cert/key, no live index or lock)
#   ha-link : tar opens, backup.json parses, hardlink count
#   platform: git bundle clones and matches the live HEAD, crontabs and
#             backups.conf present
#   secrets : required files present and byte-identical to live (never printed);
#             HA's .storage/backup: only its encryption key must match; a live
#             file written after the archive is noted, not failed
#   --start : couchdb only, on top of the above: start a throwaway CouchDB (same
#             image, --network none, a random one-off admin in the copy) on the
#             restored files and compare each database's doc_count with live
# Everything restored is deleted at the end (also on Ctrl+C).
#
#   sudo ~/docker/_host/backup-restore-test.sh [--start] [set ...]
# Not installed on the host on purpose; run it by hand after changing the
# engine or backups.conf, and as a periodic drill.
set -uo pipefail
umask 077
export LC_ALL=C
[ "$(id -u)" = 0 ] || exec sudo "$0" "$@"

CONF=/etc/homelab/backups.conf
ENGINE=/usr/local/sbin/homelab-backup
R=/dev/shm/restore-test
pass=0; failn=0

ini() { # ini <section> <key>: joined values
  awk -v s="[$1]" -v k="$2" '
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*\[/ {gsub(/[[:space:]]/,""); in_s = ($0 == s); next}
    in_s { line=$0; sub(/^[[:space:]]+/,"",line); if (index(line, k) == 1) { rest=substr(line, length(k)+1); if (rest ~ /^[[:space:]]*=/) { sub(/^[[:space:]]*=[[:space:]]*/,"",rest); out = out (out==""?"":" ") rest } } }
    END {print out}' "$CONF"
}
ok()  { echo "PASS $1: $2"; pass=$((pass + 1)); }
bad() { echo "FAIL $1: $2"; failn=$((failn + 1)); }
newest() { find "$1" -maxdepth 1 -type f -name "$2" -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-; }

START=0
if [ "${1:-}" = --start ]; then START=1; shift; fi
COUCH_TEST=couch-restoretest
cleanup() { docker stop "$COUCH_TEST" >/dev/null 2>&1; rm -rf "$R"; }
trap cleanup EXIT INT TERM

# couch_start_test <restored dir>: prints "OK <details>" or "FAIL <reason>". No
# secret is printed: the one-off admin password never leaves this process and
# curl reads credentials from stdin (-K -), never from argv.
couch_start_test() {
  local d=$1 img pw c _try db r l fails=0 details=""
  img=$(docker inspect -f '{{.Image}}' couchdb 2>/dev/null) || { echo "FAIL live couchdb container not found (image unknown)"; return; }
  pw=$(head -c 18 /dev/urandom | base64 | tr -dc A-Za-z0-9)
  printf '[admins]\nrestoretest = %s\n' "$pw" > "$d/couchdb-etc/zz-restoretest.ini"
  docker run -d --rm --name "$COUCH_TEST" --network none \
    -v "$d/couchdb-data:/opt/couchdb/data" -v "$d/couchdb-etc:/opt/couchdb/etc/local.d" "$img" >/dev/null \
    || { echo "FAIL docker run of the restored copy failed"; return; }
  for _try in $(seq 1 60); do
    c=$(docker exec "$COUCH_TEST" curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:5984/_up 2>/dev/null)
    case "$c" in 200|401) break ;; esac   # 401 = up, require_valid_user (as live)
    sleep 2
  done
  case "$c" in 200|401) ;; *) docker stop "$COUCH_TEST" >/dev/null 2>&1; echo "FAIL restored CouchDB did not come up in 120 s"; return ;; esac
  for db in $(printf 'user = "restoretest:%s"\n' "$pw" | docker exec -i "$COUCH_TEST" curl -s -K - http://127.0.0.1:5984/_all_dbs \
                | python3 -c 'import json,sys; print(" ".join(x for x in json.load(sys.stdin) if not x.startswith("_")))' 2>/dev/null); do
    r=$(printf 'user = "restoretest:%s"\n' "$pw" | docker exec -i "$COUCH_TEST" curl -s -K - "http://127.0.0.1:5984/$db" \
          | python3 -c 'import json,sys; print(json.load(sys.stdin).get("doc_count",""))' 2>/dev/null)
    l=$(docker exec couchdb sh -c 'printf "user = \"%s:%s\"\n" "$COUCHDB_USER" "$COUCHDB_PASSWORD" | curl -s -K - "http://127.0.0.1:5984/$1"' _ "$db" \
          | python3 -c 'import json,sys; print(json.load(sys.stdin).get("doc_count",""))' 2>/dev/null)
    details+="$db restored=${r:-?} live=${l:-?}; "
    # live may be a little ahead (LiveSync writes after the archive was taken)
    if [ -z "$r" ] || [ "$r" -le 0 ] 2>/dev/null || { [ -n "$l" ] && [ "$r" -gt "$l" ]; }; then fails=$((fails + 1)); fi
  done
  docker stop "$COUCH_TEST" >/dev/null 2>&1
  pw=""
  if [ -z "$details" ]; then echo "FAIL no user database found in the restored instance"
  elif [ "$fails" -gt 0 ]; then echo "FAIL ${details% }"
  else echo "OK started instance: ${details% }"; fi
}
rm -rf "$R"; mkdir -m 700 "$R" || exit 2
BASE=$(ini defaults base)

mapfile -t sets < <("$ENGINE" --list-sets | cut -f1)
[ $# -gt 0 ] && sets=("$@")

for set in "${sets[@]}"; do
  type=$(ini "$set" type); d="$R/$set"; mkdir -m 700 "$d"
  case "$type" in
    sqlite)
      a=$(newest "$BASE/$set" "${set}_[0-9]*.tar.gz")
      [ -n "$a" ] || { bad "$set" "no archive"; continue; }
      if ! tar -xzf "$a" -C "$d" 2>/dev/null; then bad "$set" "$(basename "$a") does not extract"; rm -rf "$d"; continue; fi
      db=$(ini "$set" db); dbf="$d/$(basename "$db")"; table=$(ini "$set" count)
      [ -s "$dbf" ] || { bad "$set" "no database in $(basename "$a")"; rm -rf "$d"; continue; }
      ic=$(sqlite3 "$dbf" "PRAGMA integrity_check;" 2>&1 | head -3 | tr '\n' ' ')
      rows=$(sqlite3 "$dbf" "SELECT count(*) FROM \"$table\";" 2>/dev/null)
      live=$(sqlite3 "file:$db?mode=ro" "SELECT count(*) FROM \"$table\";" 2>/dev/null)
      extra=""
      if [ "$set" = vaultwarden ]; then
        if [ -s "$d/rsa_key.pem" ] && cmp -s "$d/rsa_key.pem" /home/pi/docker/vaultwarden/data/rsa_key.pem; then
          extra=", rsa_key.pem present and identical to live"
        else
          bad "$set" "rsa_key.pem missing or different from live"; rm -rf "$d"; continue
        fi
      fi
      if [ "${ic% }" = ok ] && [ "${rows:-0}" -gt 0 ] 2>/dev/null; then
        ok "$set" "$(basename "$a"): integrity_check ok, $table=$rows (live now $live)$extra"
      else
        bad "$set" "$(basename "$a"): integrity_check='${ic}' $table='${rows}'"
      fi
      ;;
    dir)
      a=$(newest "$BASE/$set" "${set}_[0-9]*.tar.gz")
      [ -n "$a" ] || { bad "$set" "no archive"; continue; }
      if ! tar -xzf "$a" -C "$d" 2>/dev/null; then bad "$set" "$(basename "$a") does not extract"; rm -rf "$d"; continue; fi
      case "$set" in
        adguard)
          if grep -qE '^(http|dns):' "$d/conf/AdGuardHome.yaml" 2>/dev/null && ! ls "$d"/conf/*.bak* >/dev/null 2>&1; then
            ok "$set" "$(basename "$a"): AdGuardHome.yaml present with http/dns sections, no .bak copies"
          else bad "$set" "AdGuardHome.yaml missing/unparseable or .bak copies included"; fi ;;
        couchdb)
          n=$(find "$d/couchdb-data" -name '*.couch' | wc -l)
          l=$(find /home/pi/docker/couchdb/couchdb-data -name '*.couch' | wc -l)
          if [ "$n" -gt 0 ] && [ "$n" -eq "$l" ] && [ -s "$d/couchdb-etc/docker.ini" ]; then
            ok "$set" "$(basename "$a"): $n .couch files (live $l), docker.ini present"
            if [ "$START" = 1 ]; then
              st=$(couch_start_test "$d")
              case "$st" in OK*) ok "$set" "$(basename "$a"): ${st#OK }" ;; *) bad "$set" "$(basename "$a"): ${st#FAIL }" ;; esac
            fi
          else bad "$set" "$n .couch files (live $l) or docker.ini missing"; fi ;;
        syncthing)
          if [ -s "$d/config/key.pem" ] && openssl x509 -noout -in "$d/config/cert.pem" 2>/dev/null \
             && grep -q '<configuration' "$d/config/config.xml" && [ ! -e "$d/config/index-v2" ] && [ ! -e "$d/config/syncthing.lock" ]; then
            ok "$set" "$(basename "$a"): key.pem + parseable cert.pem + config.xml, no index/lock, $(du -sh "$a" | cut -f1)"
          else bad "$set" "identity files missing or index/lock included"; fi ;;
        *)
          if tar -tzf "$a" >/dev/null 2>&1; then ok "$set" "$(basename "$a") extracts"; else bad "$set" "does not list"; fi ;;
      esac
      ;;
    ha-link)
      a=$(newest "$BASE/$set" "$(ini "$set" pattern)")
      [ -n "$a" ] || { bad "$set" "no backup"; continue; }
      if tar -tf "$a" >/dev/null 2>&1 && info=$(tar -xOf "$a" ./backup.json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("name"), d.get("date"), "protected=%s" % d.get("protected"))' 2>/dev/null); then
        ok "$set" "$(basename "$a"): tar opens, backup.json: $info, link count $(stat -c %h "$a"), mode $(stat -c %a "$a")"
      else bad "$set" "$(basename "$a") does not open or has no backup.json"; fi
      ;;
    files)
      a=$(newest "$BASE/$set" "${set}_[0-9]*.tar.gz")
      [ -n "$a" ] || { bad "$set" "no archive"; continue; }
      if ! tar -xzf "$a" -C "$d" 2>/dev/null; then bad "$set" "$(basename "$a") does not extract"; rm -rf "$d"; continue; fi
      if [ "$set" = platform ]; then
        repo=$(ini "$set" repo); user=$(ini "$set" repo_user)
        if git clone -q "$d/generated/docker.bundle" "$d/clone" 2>/dev/null; then
          head_b=$(git -C "$d/clone" rev-parse HEAD 2>/dev/null)
          head_l=$(runuser -u "$user" -- git -C "$repo" rev-parse HEAD 2>/dev/null)
          files=$(git -C "$d/clone" ls-files | wc -l)
          # Commits made after 05:00 are not in last night's bundle: the bundle
          # HEAD must be live HEAD or one of its ancestors (2026-10-21).
          if [ -n "$head_b" ] && runuser -u "$user" -- git -C "$repo" merge-base --is-ancestor "$head_b" "$head_l" 2>/dev/null \
             && [ -s "$d/generated/crontab-root.txt" ] && [ -s "$d/etc/homelab/backups.conf" ]; then
            behind=$(runuser -u "$user" -- git -C "$repo" rev-list --count "$head_b..$head_l" 2>/dev/null)
            ok "$set" "$(basename "$a"): bundle clones ($files files, HEAD ${head_b:0:7} = live or ${behind} commits behind it), crontabs + backups.conf present, $(find "$d/etc/systemd/system" -type f | wc -l) units"
          else
            bad "$set" "bundle HEAD ${head_b:0:7} vs live ${head_l:0:7}, or crontab/backups.conf missing"
          fi
        else bad "$set" "git bundle does not clone"; fi
      else
        n=0; diff=0; later=0
        while IFS= read -r f; do
          [ -f "$d/$f" ] || continue
          n=$((n + 1)); cmp -s "$d/$f" "/$f" && continue
          # HA's .storage/backup also holds its backup history, rewritten by HA's
          # own nightly backup (a random time around 05:00, often after ours):
          # only the encryption key in it has to match live (2026-10-25).
          if [[ "$f" == */homeassistant/config/.storage/backup ]]; then
            python3 -I -c '
import json,sys
k=[json.load(open(p))["data"]["config"]["create_backup"]["password"] for p in sys.argv[1:]]
sys.exit(0 if k[0] and k[0]==k[1] else 1)' "$d/$f" "/$f" 2>/dev/null || diff=$((diff + 1))
            continue
          fi
          # a live file written after the archive cannot be compared with it
          if [ -s "$d/$f" ] && [ "/$f" -nt "$a" ]; then later=$((later + 1)); continue; fi
          diff=$((diff + 1))
        done < <(tar -tzf "$a" | grep -v '/$')
        if [ "$n" -gt 0 ] && [ "$diff" -eq 0 ]; then
          ok "$set" "$(basename "$a"): $n files, all identical to live$([ "$later" -gt 0 ] && echo " except $later changed after the backup ran") (contents not shown)"
        else
          bad "$set" "$n files, $diff differ from live (a live file changed since the run, or a bad copy)"
        fi
      fi
      ;;
    *) bad "$set" "unknown type $type" ;;
  esac
  rm -rf "$d"
done

echo "restore test: $pass passed, $failn failed (restored copies in $R deleted)"
[ "$failn" -eq 0 ]
