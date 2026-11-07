#!/bin/bash
# _host/install.sh - keep the Pi's host files in step with this repo.
#
#   _host/install.sh                 diff mode (default): compare every MANIFEST entry
#                                    with the live system; exit 0 = no drift, 1 = drift
#   _host/install.sh --apply [path]  install repo -> live (all drifted entries, or only
#                                    the given _host-relative paths). Copies, never
#                                    symlinks: root must not run files that live in a
#                                    user-writable directory. The previous live file is
#                                    saved under /var/backups/homelab-install/<ts>/.
#                                    Runs `systemctl daemon-reload` when a unit changed
#                                    and systemd-tmpfiles for tmpfiles.d entries.
#                                    Never restarts or reloads any other service: it
#                                    prints the follow-up command instead.
#   _host/install.sh --pull [path]   copy live -> repo (for files changed by a tool,
#                                    e.g. `ufw` rewriting user.rules). Commit afterwards.
#   _host/install.sh --bootstrap     one-time host setup that is not a file copy (for a
#                                    rebuilt Pi, see docs/backups-and-restore.md). Idempotent: it
#                                    changes nothing that is already in place.
#                                    - Docker network 'proxy' (172.30.0.0/24): created if
#                                      missing; if it exists with another subnet it is only
#                                      reported (Home Assistant trusts exactly this /24).
#                                    - `systemctl enable` every .timer in the MANIFEST. It
#                                      does not START them: start them once the stacks run.
#                                    Run it after --apply (the units must be installed).
#
# --apply refuses to run while _host/ has uncommitted changes (commit first, so the
# repo always says what is installed) unless --allow-dirty is given.
# Diffs are shown with obvious secret patterns redacted.
set -uo pipefail

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HOST_DIR")"
MANIFEST="$HOST_DIR/MANIFEST"

if [ "$(id -u)" != 0 ]; then exec sudo "$0" "$@"; fi

mode="diff"; allow_dirty=0; only=()
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) mode=apply ;;
    --pull) mode=pull ;;
    --allow-dirty) allow_dirty=1 ;;
    --bootstrap) mode=bootstrap ;;
    -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) only+=("${1#_host/}") ;;
  esac
  shift
done

redact() {
  sed -E \
    -e 's#(ntfy\.sh/)[A-Za-z0-9_-]{6,}#\1<redacted>#g' \
    -e 's#^([+-]?[[:space:]]*[A-Za-z0-9_]*(PASSWORD|PASSWD|SECRET|TOKEN|API_?KEY|AUTH|NTFY_TOPIC|PING_URL)[A-Za-z0-9_]*[[:space:]]*=[[:space:]]*).+#\1<redacted>#I'
}

git_() { git -c safe.directory="$REPO" -C "$REPO" "$@"; }

wanted() { # wanted <path>: is this entry selected?
  [ ${#only[@]} -eq 0 ] && return 0
  local o; for o in "${only[@]}"; do [ "$o" = "$1" ] && return 0; done; return 1
}

if [ "$mode" = apply ] && [ "$allow_dirty" = 0 ] && [ -n "$(git_ status --porcelain -- _host 2>/dev/null)" ]; then
  echo "REFUSING --apply: _host/ has uncommitted changes. Commit first (or --allow-dirty)." >&2
  git_ status --short -- _host >&2
  exit 2
fi

# ---- --bootstrap: host state that is not a file (idempotent) -----------------
PROXY_NET=proxy
PROXY_SUBNET=172.30.0.0/24
bootstrap() {
  local rc=0 have path t state
  [ ${#only[@]} -eq 0 ] || { echo "--bootstrap takes no paths" >&2; return 2; }
  if have=$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "$PROXY_NET" 2>/dev/null); then
    have=${have% }
    if [ "$have" = "$PROXY_SUBNET" ]; then
      echo "OK      docker network $PROXY_NET ($PROXY_SUBNET)"
    else
      echo "WARN    docker network $PROXY_NET exists with subnet '$have', expected $PROXY_SUBNET - NOT changed"
      rc=1
    fi
  elif docker network create --driver bridge --subnet "$PROXY_SUBNET" \
         --label homelab.purpose=caddy-proxy "$PROXY_NET" >/dev/null; then
    echo "CREATED docker network $PROXY_NET ($PROXY_SUBNET)"
  else
    echo "ERROR   could not create docker network $PROXY_NET"; rc=1
  fi
  while read -r path _; do
    case "$path" in etc/systemd/system/*.timer) ;; *) continue ;; esac
    t=${path##*/}
    if [ ! -e "/$path" ]; then echo "MISSING /$path - run --apply first"; rc=1; continue; fi
    state=$(systemctl is-enabled "$t" 2>/dev/null)
    if [ "$state" = enabled ]; then
      echo "OK      $t enabled"
    elif systemctl enable "$t" >/dev/null 2>&1; then
      echo "ENABLED $t (not started: systemctl start $t once the stacks run)"
    else
      echo "ERROR   systemctl enable $t failed (was: ${state:-unknown})"; rc=1
    fi
  done < "$MANIFEST"
  if [ "$rc" = 0 ]; then echo "RESULT: bootstrap complete"; else echo "RESULT: bootstrap INCOMPLETE (see above)"; fi
  return "$rc"
}
if [ "$mode" = bootstrap ]; then bootstrap; exit $?; fi

TS=$(date +%Y%m%d-%H%M%S)
BK="/var/backups/homelab-install/$TS"
drift=0; reload_units=0; followups=()
declare -A tracked=()

while read -r path fmode owner group after; do
  case "$path" in ''|'#'*) continue ;; esac
  if [ "$path" = ignore ]; then tracked["/$fmode"]=1; continue; fi
  src="$HOST_DIR/$path"
  wanted "$path" || { tracked["/$path"]=1; continue; }

  # ---- crontabs: compared/installed through the crontab command -------------
  if [ "$fmode" = crontab ]; then
    user="$owner"
    live=$(crontab -u "$user" -l 2>/dev/null)
    if [ "$mode" = pull ]; then
      printf '%s\n' "$live" > "$src"; chown --reference="$HOST_DIR" "$src"; echo "PULLED  $path"; continue
    fi
    if [ "$live" = "$(cat "$src" 2>/dev/null)" ]; then
      echo "OK      $path (crontab -u $user)"
    else
      drift=1; echo "DIFF    $path (crontab -u $user)"
      diff -u <(printf '%s\n' "$live") "$src" | redact | sed 's/^/        /'
      if [ "$mode" = apply ]; then
        install -d -m 700 "$BK"; printf '%s\n' "$live" > "$BK/crontab-$user"
        crontab -u "$user" "$src" && echo "        installed (old saved to $BK/crontab-$user)"
      fi
    fi
    continue
  fi

  dest="/$path"; tracked["$dest"]=1

  if [ "$mode" = pull ]; then
    if [ -e "$dest" ]; then
      install -D -m 644 "$dest" "$src"; chown --reference="$HOST_DIR" "$src"; echo "PULLED  $path"
    else
      echo "MISSING $dest (nothing to pull)"
    fi
    continue
  fi

  state=OK; notes=""
  if [ ! -e "$src" ]; then echo "ERROR   $path listed in MANIFEST but missing from the repo"; drift=1; continue; fi
  if [ ! -e "$dest" ]; then
    state=MISSING
  elif [ -L "$dest" ]; then
    state=DIFF; notes=" (live file is a symlink)"
  else
    cmp -s "$src" "$dest" || state=DIFF
    live_meta=$(stat -c '%a %U %G' "$dest")
    want_meta="$(printf '%o' "$((8#$fmode))") $owner $group"
    if [ "$live_meta" != "$want_meta" ]; then
      [ "$state" = OK ] && state=META
      notes=" (live $live_meta, want $want_meta)"
    fi
  fi

  if [ "$state" = OK ]; then echo "OK      $path"; continue; fi
  drift=1
  echo "$state$(printf '%*s' $((8 - ${#state})) '')$path$notes"
  [ "$state" = DIFF ] && [ -e "$dest" ] && diff -u "$dest" "$src" | redact | sed 's/^/        /'

  if [ "$mode" = apply ]; then
    if [ -e "$dest" ]; then install -d -m 700 "$BK/$(dirname "$path")"; cp -a "$dest" "$BK/$path"; fi
    [ -d "$(dirname "$dest")" ] || install -d -m 755 "$(dirname "$dest")"   # never re-mode an existing dir (e.g. a 700 home)
    tmp="$dest.homelab-install.$$"
    install -m "$fmode" -o "$owner" -g "$group" "$src" "$tmp" && mv -f "$tmp" "$dest" \
      && echo "        installed$( [ -e "$BK/$path" ] && echo " (old saved to $BK/$path)")"
    case "$after" in
      daemon-reload) reload_units=1 ;;
      tmpfiles) systemd-tmpfiles --create "$dest" && echo "        systemd-tmpfiles --create done" ;;
      -|'') ;;
      *) followups+=("$path: $after") ;;
    esac
  fi
done < "$MANIFEST"

# ---- files that exist live in homelab locations but are not in the MANIFEST ---
if [ "$mode" = diff ] && [ ${#only[@]} -eq 0 ]; then
  while IFS= read -r f; do
    [ -n "${tracked[$f]:-}" ] && continue
    drift=1; echo "UNTRACKED $f (add it to _host/MANIFEST, or an 'ignore' line)"
  done < <(find /usr/local/bin /usr/local/sbin /etc/systemd/journald.conf.d /etc/systemd/system.conf.d /etc/homelab /etc/tmpfiles.d/homelab.conf \
             -maxdepth 1 \( -type f -o -type l \) 2>/dev/null
           find /etc/systemd/system -maxdepth 1 -type f 2>/dev/null)
fi

if [ "$reload_units" = 1 ]; then systemctl daemon-reload && echo "systemctl daemon-reload done"; fi

# ---- every MANIFEST timer must be enabled (2026-10-21) -----------------------
# Before this, only --bootstrap enabled timers: a timer added later was installed
# but never enabled (homelab-backup-push-mac), and one started by hand without
# enable would have died silently at the next boot - and
# both still showed "no drift". --apply now enables + starts; the check reports.
# Timers that disable themselves when their job is done are listed here
# (space-separated, with a space at each end).
SELF_DISABLING=" "
if [ ${#only[@]} -eq 0 ]; then
  while read -r path _; do
    case "$path" in etc/systemd/system/*.timer) ;; *) continue ;; esac
    t=${path##*/}
    case "$SELF_DISABLING" in *" $t "*) continue ;; esac
    [ -e "/$path" ] || continue        # MISSING was already reported above
    [ "$(systemctl is-enabled "$t" 2>/dev/null)" = enabled ] && continue
    if [ "$mode" = apply ]; then
      if systemctl enable --now "$t" >/dev/null 2>&1; then echo "ENABLED $t (and started)"
      else echo "ERROR   systemctl enable --now $t failed"; fi
    else
      drift=1; echo "DISABLED $t (in the MANIFEST but not enabled: lost at the next boot; --apply enables it)"
    fi
  done < "$MANIFEST"
fi
if [ ${#followups[@]} -gt 0 ]; then
  echo "Follow-up needed (NOT run automatically):"; printf '  %s\n' "${followups[@]}"
fi
if [ "$mode" = diff ]; then
  if [ "$drift" = 0 ]; then echo "RESULT: no drift"; else echo "RESULT: DRIFT (see above)"; fi
  exit "$drift"
fi
exit 0
