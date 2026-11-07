#!/bin/bash
# homelab-notify - one place that knows how to reach the human (ntfy.sh).
#
# Usage:
#   homelab-notify.sh [--key KEY [--every HOURS]] <priority> <title> <message...>
#   homelab-notify.sh --resolve KEY <priority> <title> <message...>
#
#   priority   min | low | default | high | urgent
#   --key      dedupe. An alert with the same KEY is sent at most once every
#              HOURS (default 6; 0 = only once until resolved). State lives in
#              /var/lib/homelab/notify/<KEY>. A failed send is retried by the
#              next call after 30 minutes, not every call.
#   --resolve  close incident KEY. If an alert for KEY actually reached ntfy,
#              this message is sent as the all-clear; if there is no open
#              incident, nothing is sent and nothing is logged. Safe to call on
#              every healthy run.
#
# Why dedupe: ntfy.sh allows 250 messages/day per public IP (anonymous). A
# watchdog pushing every 10 minutes during a long outage would exhaust that and
# silence EVERY other alert (backups, health, Kuma). See the 2026-09-17 audit.
#
# Deliberately failure-tolerant: a notification that cannot be sent must never
# break or block the thing that was trying to report, so this ALWAYS exits 0.
# Every real send attempt is logged with its HTTP code (never the topic):
#   journalctl -t homelab-notify
#
# Topic: NTFY_TOPIC in /etc/homelab/secrets.env (root 600). Falls back to
# ~pi/.ntfy-topic when run by a non-root user (adguard-pin and
# claude-session-keepalive run as pi): keep that file.
set -uo pipefail

SECRETS="${HOMELAB_SECRETS:-/etc/homelab/secrets.env}"
FALLBACK_TOPIC_FILE="${HOMELAB_TOPIC_FALLBACK:-/home/pi/.ntfy-topic}"
STATE_DIR="${HOMELAB_NOTIFY_STATE:-/var/lib/homelab/notify}"
# Overridden only by watchdog-tests.sh: run unstubbed, the suite's fake alerts typed
# 22 wake-up lines into the caretaker session (2026-10-23).
CARETAKER_WAKE="${HOMELAB_CARETAKER_WAKE:-/usr/local/bin/caretaker-wake.sh}"
RETRY_FAILED_AFTER=1800   # seconds before a never-delivered alert is re-attempted

log() { # log <level> <text>
  logger -t homelab-notify -p "user.$1" -- "$2" 2>/dev/null || true
  echo "homelab-notify: $2" >&2
}

read_state() { # read_state <file>  -> sets opened last_ok last_try
  opened=0; last_ok=0; last_try=0
  [ -r "$1" ] || return 0
  local k v
  while IFS='=' read -r k v; do
    case "$v" in ''|*[!0-9]*) continue ;; esac
    case "$k" in
      opened) opened=$v ;; last_ok) last_ok=$v ;; last_try) last_try=$v ;;
    esac
  done < "$1"
}

write_state() { # write_state <file>
  local tmp="$1.tmp.$$"
  printf 'opened=%s\nlast_ok=%s\nlast_try=%s\n' "$opened" "$last_ok" "$last_try" > "$tmp" \
    && mv -f "$tmp" "$1"
}

load_topic() {
  TOPIC=""
  if [ -r "$SECRETS" ]; then
    TOPIC=$(sed -n 's/^NTFY_TOPIC=//p' "$SECRETS" | tail -n 1 | tr -d "\"' \t\r\n")
  fi
  if [ -z "$TOPIC" ] && [ -r "$FALLBACK_TOPIC_FILE" ]; then
    TOPIC=$(tr -d " \t\r\n" < "$FALLBACK_TOPIC_FILE")
  fi
  case "$TOPIC" in
    '') log err "no ntfy topic available (checked $SECRETS and the fallback file) - NOT sent: $TITLE"; return 1 ;;
    *[!A-Za-z0-9_-]*) log err "ntfy topic has unexpected characters - NOT sent: $TITLE"; return 1 ;;
  esac
  return 0
}

send() { # sets HTTP_CODE and ATTEMPTS; returns 0 on 2xx
  local code attempt
  HTTP_CODE=000; ATTEMPTS=0
  for attempt in 1 2 3; do
    ATTEMPTS=$attempt
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 20 \
      -H "Title: ${TITLE}" \
      -H "Priority: ${PRIO}" \
      -H "Tags: ${TAGS}" \
      --data-raw "${MSG}" \
      "https://ntfy.sh/${TOPIC}" 2>/dev/null)
    HTTP_CODE=${code:-000}
    case "$HTTP_CODE" in
      2??) return 0 ;;
      4??) return 1 ;;          # 429 rate limit / bad request: retrying will not help
    esac
    [ "$attempt" -lt 3 ] && sleep 10
  done
  return 1
}

main() {
  local key="" every=6 resolve=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --key)       shift; key="${1:-}";     [ $# -gt 0 ] && shift ;;
      --key=*)     key="${1#--key=}";       shift ;;
      --every)     shift; every="${1:-6}";  [ $# -gt 0 ] && shift ;;
      --every=*)   every="${1#--every=}";   shift ;;
      --resolve)   shift; resolve="${1:-}"; [ $# -gt 0 ] && shift ;;
      --resolve=*) resolve="${1#--resolve=}"; shift ;;
      --)          shift; break ;;
      *)           break ;;
    esac
  done

  PRIO="${1:-default}"
  TITLE="${2:-Homelab}"
  if [ $# -ge 2 ]; then shift 2; else shift $#; fi
  MSG="${*:-(no message)}"
  TITLE=$(printf '%s' "$TITLE" | tr -d '\r\n')
  case "$PRIO" in min|low|default|high|urgent) ;; *) PRIO=default ;; esac
  case "$every" in ''|*[!0-9]*) every=6 ;; esac
  case "$PRIO" in
    urgent|high) TAGS="rotating_light" ;;
    low|min)     TAGS="information_source" ;;
    *)           TAGS="warning" ;;
  esac

  # KEY names a file: allow only a safe character set.
  [ -n "$resolve" ] && key="$resolve"
  if [ -n "$key" ]; then
    key=$(printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '_' | sed 's/^\.*//')
    [ -n "$key" ] || key="_invalid_key"
  fi

  # ---- no dedupe requested: plain send (original behaviour) ----------------
  if [ -z "$key" ]; then
    load_topic || exit 0
    if send; then
      log info "sent prio=$PRIO title=\"$TITLE\" http=$HTTP_CODE attempts=$ATTEMPTS"
    else
      log err "FAILED prio=$PRIO title=\"$TITLE\" http=$HTTP_CODE attempts=$ATTEMPTS"
    fi
    exit 0
  fi

  # ---- dedupe / resolve: needs a writable state dir ------------------------
  if ! mkdir -p "$STATE_DIR" 2>/dev/null || [ ! -w "$STATE_DIR" ]; then
    if [ -n "$resolve" ]; then exit 0; fi   # cannot know about an incident; stay quiet
    log warning "state dir $STATE_DIR not writable (not root?) - sending key=$key without dedupe"
    load_topic || exit 0
    if send; then
      log info "sent prio=$PRIO key=$key title=\"$TITLE\" http=$HTTP_CODE attempts=$ATTEMPTS (no dedupe)"
    else
      log err "FAILED prio=$PRIO key=$key title=\"$TITLE\" http=$HTTP_CODE attempts=$ATTEMPTS (no dedupe)"
    fi
    exit 0
  fi

  local sf="$STATE_DIR/$key" now
  now=$(date +%s)
  # Resolve with no open incident is the common case (every healthy watchdog run):
  # leave before touching the lock so a healthy run writes nothing to disk.
  if [ -n "$resolve" ] && [ ! -e "$sf" ]; then exit 0; fi
  # One sender per key at a time (two watchdogs can fire in the same second).
  mkdir -p "$STATE_DIR/.locks" 2>/dev/null
  exec 9>"$STATE_DIR/.locks/$key"
  flock -w 90 9 2>/dev/null || true

  if [ -n "$resolve" ]; then
    [ -e "$sf" ] || exit 0                         # no open incident: silent no-op
    read_state "$sf"
    if [ "$last_ok" -eq 0 ]; then
      rm -f "$sf"
      log info "closed key=$key (its alert had never been delivered, so no all-clear sent)"
      exit 0
    fi
    # Do not hammer ntfy with a failing all-clear on every healthy run.
    if [ "$last_try" -gt "$last_ok" ] && [ $((now - last_try)) -lt "$RETRY_FAILED_AFTER" ]; then
      exit 0
    fi
    load_topic || exit 0
    if send; then
      rm -f "$sf"
      log info "resolved key=$key prio=$PRIO title=\"$TITLE\" http=$HTTP_CODE attempts=$ATTEMPTS"
    else
      last_try=$now; write_state "$sf"
      log err "FAILED all-clear key=$key title=\"$TITLE\" http=$HTTP_CODE attempts=$ATTEMPTS (will retry)"
    fi
    exit 0
  fi

  read_state "$sf"
  if [ -e "$sf" ]; then
    if [ "$last_ok" -gt 0 ]; then
      if [ "$every" -eq 0 ] || [ $((now - last_ok)) -lt $((every * 3600)) ]; then
        log info "suppressed key=$key title=\"$TITLE\" (already sent $(( (now - last_ok) / 60 )) min ago; repeat every ${every}h)"
        exit 0
      fi
    elif [ $((now - last_try)) -lt "$RETRY_FAILED_AFTER" ]; then
      log info "suppressed key=$key title=\"$TITLE\" (last attempt failed $(( (now - last_try) / 60 )) min ago; retry after 30 min)"
      exit 0
    fi
  fi
  [ "$opened" -gt 0 ] || opened=$now

  # A new (not deduped) alert also wakes the caretaker session, whether or not the push
  # reaches ntfy. Reminders (low/min) wait for its daily tick. Never blocks, never fails.
  case "$PRIO" in default|high|urgent)
    [ -x "$CARETAKER_WAKE" ] && "$CARETAKER_WAKE" alert "$key" "$TITLE" >/dev/null 2>&1 9>&- & ;;
  esac

  load_topic || { last_try=$now; write_state "$sf"; exit 0; }
  last_try=$now
  if send; then
    last_ok=$now
    log info "sent prio=$PRIO key=$key title=\"$TITLE\" http=$HTTP_CODE attempts=$ATTEMPTS"
  else
    log err "FAILED prio=$PRIO key=$key title=\"$TITLE\" http=$HTTP_CODE attempts=$ATTEMPTS"
  fi
  write_state "$sf"
  exit 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
