#!/bin/bash
# caretaker-wake.sh - put one line into the always-on Claude Code session so the
# caretaker (see ~/docker/CARETAKER.md) acts without the owner opening a terminal.
#
#   caretaker-wake.sh tick                    daily wake-up (caretaker-tick.timer)
#   caretaker-wake.sh alert <key> <title>     called by homelab-notify.sh when an alert goes out
#   caretaker-wake.sh --dry-run ...           print the line instead of sending it
#
# The line is deliberately short and fixed-form: the instructions live in
# CARETAKER.md (versioned), not in this script, and an alert passes only its key
# and title, reduced to a safe character set - never log text, never secrets.
# Wake-ups are not the owner speaking; CARETAKER.md says how to treat them.
#
# Failure-tolerant like homelab-notify: a wake-up that cannot be delivered must never
# break the thing that asked for it, so this ALWAYS exits 0 (the ntfy push to the owner
# is the alert path that matters; this one is extra).
set -uo pipefail
HERDR=/home/pi/.local/bin/herdr
LABEL=claude-operator              # workspace that holds the session (same label as claude-session-ensure.sh)
RUN_USER=pi
STAMP_DIR=/run/homelab            # tmpfs: no flash writes
ALERT_MIN_GAP=1200                # at most one alert wake-up per 20 min (a storm is one event)

DRY=0; [ "${1:-}" = "--dry-run" ] && { DRY=1; shift; }
kind=${1:-}
clean() { printf '%s' "$1" | tr -c 'A-Za-z0-9 ._:@/-' ' ' | tr -s ' ' | cut -c1-120; }
log() { logger -t caretaker-wake -- "$1" 2>/dev/null || true; echo "caretaker-wake: $1" >&2; }

case "$kind" in
  tick)  line="[caretaker tick $(date +%F)] Automated daily wake-up, not a message from the owner. Follow ~/docker/CARETAKER.md." ;;
  alert) line="[caretaker alert $(date '+%F %H:%M')] Automated, not from the owner. An alert just went to the owner: key=$(clean "${2:-none}") title=$(clean "${3:-}"). Investigate per ~/docker/CARETAKER.md." ;;
  *)     echo "usage: caretaker-wake.sh [--dry-run] tick | alert <key> <title>" >&2; exit 0 ;;
esac

[ "$DRY" = 1 ] && { echo "$line"; exit 0; }
[ -e "$STAMP_DIR/maintenance" ] && [ "$kind" = alert ] && { log "maintenance flag present - alert wake-up skipped"; exit 0; }
if [ "$kind" = alert ]; then
  s="$STAMP_DIR/caretaker-last-alert-wake"; now=$(date +%s)
  last=$(cat "$s" 2>/dev/null || echo 0); case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $((now - last)) -lt "$ALERT_MIN_GAP" ] && { log "alert wake-up suppressed (last one $(( (now - last) / 60 )) min ago)"; exit 0; }
  mkdir -p "$STAMP_DIR" 2>/dev/null; echo "$now" > "$s" 2>/dev/null || true
fi

as_user() { if [ "$(id -un)" = "$RUN_USER" ]; then "$@"; else runuser -u "$RUN_USER" -- env HOME=/home/$RUN_USER "$@"; fi; }
PANE=$(as_user "$HERDR" workspace list 2>/dev/null | jq -r --arg l "$LABEL" '.result.workspaces[]? | select(.label==$l) | .workspace_id' | head -1)
[ -n "$PANE" ] && PANE=$(as_user "$HERDR" pane list --workspace "$PANE" 2>/dev/null | jq -r '.result.panes[0].pane_id // empty')
[ -n "$PANE" ] || { log "no workspace '$LABEL' - $kind wake-up not delivered"; exit 0; }
# Only type into the pane when Claude Code is really the foreground program there:
# otherwise the line would be executed by the shell.
if ! as_user "$HERDR" pane process-info --pane "$PANE" 2>/dev/null \
     | jq -e '[(.result.process_info.foreground_processes // [])[] | (.cmdline // "") + " " + (.name // "")] | any(test("claude"))' >/dev/null 2>&1; then
  log "Claude Code is not running in $PANE - $kind wake-up not delivered (keepalive restarts it within 10 min)"
  exit 0
fi
if as_user "$HERDR" pane run "$PANE" "$line" >/dev/null 2>&1; then log "delivered: $kind"; else log "herdr pane run failed - $kind wake-up not delivered"; fi
exit 0
