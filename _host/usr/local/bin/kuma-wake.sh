#!/bin/bash
# kuma-wake.sh - wake the caretaker when Uptime Kuma marks a monitor DOWN.
#
# Kuma sends its alerts to ntfy itself, past homelab-notify.sh, so on its own it never
# woke the caretaker (2026-10-26: house DNS slow 14:41-14:46, looked at 4 h later when
# the owner asked). Every 2 min (kuma-wake.timer) this reads Kuma's database READ-ONLY
# for new changes to DOWN on monitors that notify the owner, and hands them to
# caretaker-wake.sh alert (its 20-min gap and the maintenance flag apply there).
#
#   kuma-wake.sh             check and wake (the timer)
#   kuma-wake.sh --dry-run   print the line it would send; the cursor is not moved
#
# The cursor (last heartbeat id seen) lives in /run/homelab, a tmpfs: no flash writes.
# Without one (after a boot) it looks back 10 minutes, never further. Only monitor
# names and times leave the database, never URLs or messages (a URL can hold a secret).
# Overrides for tests: KUMA_WAKE_CARETAKER (the wake script), KUMA_WAKE_CURSOR.
set -uo pipefail
DB=/home/pi/docker/uptime-kuma/data/kuma.db
WAKE="${KUMA_WAKE_CARETAKER:-/usr/local/bin/caretaker-wake.sh}"
CURSOR="${KUMA_WAKE_CURSOR:-/run/homelab/kuma-wake-last-id}"

DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
# The unit keeps only notice and worse (LogLevelMax): mark errors as such for the journal.
fail() { if [ -t 2 ]; then echo "kuma-wake: $1" >&2; else echo "<3>kuma-wake: $1" >&2; fi; exit 1; }
q() { sqlite3 -readonly -cmd ".timeout 5000" "file:$DB?mode=ro" "$1"; }

top=$(q "SELECT coalesce(max(id), 0) FROM heartbeat;") || fail "cannot read $DB"
case "$top" in ''|*[!0-9]*) fail "unexpected answer from $DB" ;; esac
last=$(cat "$CURSOR" 2>/dev/null); case "$last" in ''|*[!0-9]*) last="" ;; esac
# No cursor, or ids went backwards (Kuma's DB restored from a backup): last 10 minutes.
# 13 monitors at 60 s write ~130 beats in that time, so 2000 ids back is plenty.
if [ -z "$last" ] || [ "$last" -gt "$top" ]; then
  last=""
  since="h.id > $((top - 2000)) AND h.time > datetime('now', '-10 minutes')"
else
  since="h.id > $last"
fi

# status 0 = DOWN; important = a change of state (Kuma notifies on these).
down=$(q "SELECT strftime('%H:%M', h.time, 'localtime') || ' ' || m.name
  FROM heartbeat h JOIN monitor m ON m.id = h.monitor_id
  WHERE $since AND h.id <= $top AND h.status = 0 AND h.important = 1 AND m.active = 1
    AND EXISTS (SELECT 1 FROM monitor_notification mn JOIN notification n ON n.id = mn.notification_id
                WHERE mn.monitor_id = m.id AND n.active = 1)
  ORDER BY h.id;") || fail "cannot read $DB"

if [ -n "$down" ]; then
  title="Kuma DOWN $(printf '%s\n' "$down" | awk 'NR > 1 { printf " / " } { printf "%s", $0 }')"
  if [ "$DRY" = 1 ]; then "$WAKE" --dry-run alert kuma-down "$title"; else "$WAKE" alert kuma-down "$title"; fi
fi
[ "$DRY" = 1 ] && { [ -n "$down" ] || echo "kuma-wake: no new DOWN since ${last:-the last 10 minutes}"; exit 0; }
mkdir -p "$(dirname "$CURSOR")" && echo "$top" > "$CURSOR"
