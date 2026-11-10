#!/bin/bash
# claude-session-ensure.sh - keep the always-on Claude Code session alive.
#
# The Pi runs one Claude Code session inside the herdr server (claude-session.service)
# so it survives every closed terminal and can be attached to from any SSH login.
# This script is idempotent: it creates the workspace when missing and (re)launches
# Claude Code only when it is not already running. Safe to run by hand.
#
# Called by  claude-session.service (ExecStartPost)  and every 10 min by
#            claude-session-keepalive.timer.
#
# Why this exists instead of herdr's own restore: herdr resumes agent panes with its own
# `claude --resume <id>` command line, WITHOUT the flags below, so after a reboot the session
# would look alive while running without them. Hence resume_agents_on_restore = false in
# ~/.config/herdr/config.toml and this script owns the launch.
set -uo pipefail

HERDR=/home/pi/.local/bin/herdr
HOME_DIR=/home/pi
LABEL=claude-operator
SESSION_NAME="Homelab operator"
# The session is one named conversation. A relaunch RESUMES that exact conversation
# (not "the newest in this folder"). It runs unattended: nobody is there to answer a
# prompt, so its limits come from the charter, systemd, git and the alert path.
SESSION_ID=00000000-0000-0000-0000-000000000000   # placeholder: the conversation id
CMD="claude --resume $SESSION_ID -n '$SESSION_NAME' --dangerously-skip-permissions"
# One-shot fresh start (when a conversation has grown too heavy): if this marker exists at
# launch time, start an EMPTY conversation instead of continuing the most recent one, then
# remove the marker. Normal relaunches continue.
FRESH_MARKER=$HOME_DIR/.claude-session-fresh
CMD_FRESH="claude -n '$SESSION_NAME' --dangerously-skip-permissions"

log() { echo "claude-session-ensure: $*"; }
srv_state() { "$HERDR" status server 2>/dev/null | awk '/^status:/{print $2; exit}'; }

# 1. wait for the herdr server socket (ExecStartPost can beat it by a second or two)
for _ in $(seq 1 30); do
  [ "$(srv_state)" = running ] && break
  sleep 1
done
state=$(srv_state)
if [ "$state" != running ]; then
  # claude-session.service owns the server (Restart=always); nothing for us to do.
  log "herdr server not running (status: ${state:-unknown}) - skipping"
  exit 0
fi

# 2. find, or create, the workspace that holds the session
ws=$("$HERDR" workspace list 2>/dev/null \
     | jq -r --arg l "$LABEL" '.result.workspaces[]? | select(.label==$l) | .workspace_id' | head -1)
if [ -z "$ws" ]; then
  pane=$("$HERDR" workspace create --cwd "$HOME_DIR" --label "$LABEL" --no-focus 2>/dev/null \
         | jq -r '.result.root_pane.pane_id // empty')
  [ -n "$pane" ] || { log "ERROR could not create workspace '$LABEL'"; exit 1; }
  log "created workspace '$LABEL' (pane $pane)"
else
  pane=$("$HERDR" pane list --workspace "$ws" 2>/dev/null | jq -r '.result.panes[0].pane_id // empty')
  [ -n "$pane" ] || { log "ERROR workspace $ws has no pane"; exit 1; }
fi

# 3. Parked on the startup folder-trust dialog?
#    This MUST be checked before the process check below: a parked session is still a
#    live `claude` process, so process-info alone reports green while the session cannot
#    act. Nobody can answer this dialog under systemd, so relaunching would only park
#    again. Fail loudly and let OnFailure notify the owner; this needs a human once, then
#    never again.
if "$HERDR" pane read "$pane" --source visible 2>/dev/null \
   | grep -qiE 'I trust this folder|Quick safety check'; then
  log "ERROR Claude in $pane is parked on the folder-trust dialog - the session cannot act."
  log "      Relaunching cannot help: it would park on the same dialog."
  log "      Fix once as the owner, then restart claude-session:"
  log "      tmp=\$(mktemp) && jq '.projects[\"$HOME_DIR\"].hasTrustDialogAccepted = true' \\"
  log "        ~/.claude.json > \"\$tmp\" && mv \"\$tmp\" ~/.claude.json"
  exit 1
fi

# 4. already running? then say nothing - this is the normal case on every timer tick
if "$HERDR" pane process-info --pane "$pane" 2>/dev/null \
   | jq -e '[(.result.process_info.foreground_processes // [])[] | (.cmdline // "") + " " + (.name // "")]
            | any(test("claude"))' >/dev/null 2>&1; then
  exit 0
fi

# 5. not running -> launch it in that pane (pane run submits the line atomically)
if [ ! -e "$HOME_DIR/.claude/projects/-home-pi/$SESSION_ID.jsonl" ]; then
  CMD=$CMD_FRESH; log "conversation $SESSION_ID not on disk - starting a NEW conversation"
fi
if [ -e "$FRESH_MARKER" ]; then
  CMD=$CMD_FRESH
  rm -f "$FRESH_MARKER"
  log "fresh-start marker found - starting a NEW conversation"
fi
log "Claude Code not running in $pane - starting: $CMD"
"$HERDR" pane run "$pane" "$CMD" >/dev/null 2>&1 || { log "ERROR pane run failed"; exit 1; }
log "started; attach with: herdr   (detach again with ctrl+b q)"
