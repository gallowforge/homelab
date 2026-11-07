#!/bin/bash
# claude-login-check - warn the owner before the Pi's Claude Code login runs out.
#
# The login (OAuth refresh token in ~pi/.claude/.credentials.json) lives 30 days.
# When it ends, the caretaker session and Remote Control stop until someone types /login
# (happened 2026-10-18 09:25). This reads ONLY refreshTokenExpiresAt (never a token) and
# sends one ntfy alert 3 days before and one on the last day. The keys include the expiry
# date, so a fresh login re-arms both automatically.
#
#   claude-login-check.sh          daily check (timer claude-login-check.timer, 10:00)
#   claude-login-check.sh --test   send the 3-day message now, marked TEST (proves the path)
set -uo pipefail

CREDS="${CLAUDE_CREDS:-/home/pi/.claude/.credentials.json}"
NOTIFY="${HOMELAB_NOTIFY_BIN:-/usr/local/bin/homelab-notify.sh}"

exp_ms=$(python3 -c 'import json,sys
print(json.load(open(sys.argv[1]))["claudeAiOauth"]["refreshTokenExpiresAt"])' "$CREDS" 2>/dev/null)
if [[ ! "$exp_ms" =~ ^[0-9]+$ ]]; then
  "$NOTIFY" --key claude-login-unreadable --every 24 default "Pi: can't read Claude login date" \
    "The Pi could not read when its Claude login ends. If Claude stopped answering on the Pi, open it (ssh pi, then claude) and type /login."
  exit 0
fi

exp=$(( exp_ms / 1000 )); now=$(date +%s); left=$(( exp - now ))
when=$(TZ=Asia/Kuwait date -d "@$exp" '+%a %-d %b, %H:%M')
stamp=$(date -d "@$exp" +%F)
echo "claude login ends $when Kuwait ($(( left / 86400 )) days left)"

how="Fix (1 minute): open Claude on the Pi (ssh pi, then claude, or Remote Control) and type /login. Until then the caretaker and Remote Control stop working."

if [[ "${1:-}" == "--test" ]]; then
  "$NOTIFY" low "TEST - Pi Claude login ends in $(( left / 86400 )) days" \
    "This is a test of the login reminder. The Pi's Claude login ends $when. $how"
elif (( left <= 0 )); then
  "$NOTIFY" --key "claude-login-last-$stamp" --every 0 high "Pi's Claude login has ended" \
    "The Pi's Claude login ended $when. $how"
elif (( left <= 86400 )); then
  "$NOTIFY" --key "claude-login-last-$stamp" --every 0 high "Pi needs a new Claude login today" \
    "The Pi's Claude login ends $when (today). $how"
elif (( left <= 3 * 86400 )); then
  "$NOTIFY" --key "claude-login-3d-$stamp" --every 0 default "Pi needs a new Claude login in 3 days" \
    "The Pi's Claude login ends $when. $how"
fi
exit 0
