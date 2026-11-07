#!/bin/bash
# Stubbed tests for homelab-notify.sh and homelab-netprobe.
# NOTHING here may touch real docker, curl or ntfy:
#   layer 1: docker/curl/logger/sleep are shell functions (exported to children)
#   layer 2: PATH stubs for docker/curl/tailscale/logger that refuse and record
#   layer 3: DOCKER_HOST points at a socket that does not exist
# Run as a normal user (not root).
set -uo pipefail
[ "$(id -u)" = 0 ] && { echo "refusing to run tests as root"; exit 1; }

T=$(cd "$(dirname "$0")" && pwd)
# Layout: <dir>/run-tests.sh (this file) + <dir>/bin/{homelab-notify.sh,homelab-netprobe}
#   mkdir -p /tmp/wdtest/bin && cp _host/watchdog-tests.sh /tmp/wdtest/run-tests.sh \
#     && cp _host/usr/local/bin/*.sh _host/usr/local/bin/homelab-netprobe /tmp/wdtest/bin/ \
#     && bash /tmp/wdtest/run-tests.sh
BIN="$T/bin"
chmod 755 "$BIN"/*.sh
mkdir -p "${TEST_TMP:-/tmp/fix-a2/test}"
W=$(mktemp -d "${TEST_TMP:-/tmp/fix-a2/test}/work.XXXXXX")
export DOCKER_HOST="unix://$W/no-such-docker.sock"
mkdir -p "$W/stubs"
for s in docker curl tailscale logger; do
  printf '#!/bin/sh\necho "PATH-STUB %s $*" >> "%s/path-stub-hits"\nexit 97\n' "$s" "$W" > "$W/stubs/$s"
  chmod +x "$W/stubs/$s"
done
export PATH="$W/stubs:$PATH"

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  PASS  $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL  $*"; }
check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1: expected [$2] got [$3]"; fi
}
count() { grep -c -- "$1" "$2" 2>/dev/null || true; }

# ---------------------------------------------------------------- common stubs
export CALLS="$W/calls"          # every stubbed external action is appended here
export CURL_SEQ_FILE="$W/curl-seq"
sleep()  { echo "sleep $*" >> "$CALLS"; }
logger() { local last; for last in "$@"; do :; done; echo "[journal] $last" >> "$CALLS"; }
# ntfy curl stub: pops the next HTTP code from CURL_SEQ_FILE (default 200)
curl() {
  local code=200 title=""
  local a; for a in "$@"; do case "$a" in Title:*) title="${a#Title: }" ;; esac; done
  if [ -s "$CURL_SEQ_FILE" ]; then code=$(head -n 1 "$CURL_SEQ_FILE"); sed -i 1d "$CURL_SEQ_FILE"; fi
  echo "ntfy-post title=[$title] -> $code" >> "$CALLS"
  printf '%s' "$code"
}
export -f sleep logger curl
# homelab-notify wakes the caretaker session on every new alert (caretaker-wake.sh types
# into the live Claude pane): always the stub, which only records the call.
export WAKES="$W/wakes" HOMELAB_CARETAKER_WAKE="$W/stubs/caretaker-wake"
printf '#!/bin/sh\necho "WAKE $*" >> "$WAKES"\n' > "$HOMELAB_CARETAKER_WAKE"; chmod +x "$HOMELAB_CARETAKER_WAKE"

new_case() {
  echo; echo "=== $1"
  CASE="$W/$(echo "$1" | tr -c 'A-Za-z0-9' '_')"; mkdir -p "$CASE"
  : > "$CALLS"; : > "$CURL_SEQ_FILE"; : > "$WAKES"
  export HOMELAB_SECRETS="$CASE/secrets.env"
  export HOMELAB_TOPIC_FALLBACK="$CASE/no-fallback-topic"
  export HOMELAB_NOTIFY_STATE="$CASE/notify-state"
  printf 'NTFY_TOPIC=%s\n' test_topic_not_real > "$HOMELAB_SECRETS"
}
show() { sed 's/^/    | /' "$CALLS"; }

N="$BIN/homelab-notify.sh"
notify_run() { bash "$N" "$@"; }   # child process: inherits exported stubs

########################################################################## notify
echo "##### homelab-notify.sh"

new_case "N1 plain send, 200"
notify_run high "Title one" "body" 2>/dev/null; rc=$?
show; check "exit code" 0 "$rc"; check "posts" 1 "$(count ntfy-post "$CALLS")"
check "journal line has http=200" 1 "$(count 'sent prio=high title="Title one" http=200 attempts=1' "$CALLS")"

new_case "N2 plain send, 503 503 200 -> retried"
printf '503\n503\n200\n' > "$CURL_SEQ_FILE"
notify_run default "Retry me" "body" 2>/dev/null
show; check "posts" 3 "$(count ntfy-post "$CALLS")"; check "attempts=3 logged" 1 "$(count 'http=200 attempts=3' "$CALLS")"

new_case "N3 plain send, 429 -> no retry, logged as FAILED"
printf '429\n' > "$CURL_SEQ_FILE"
notify_run urgent "Rate limited" "body" 2>/dev/null; rc=$?
show; check "exit code still 0" 0 "$rc"; check "posts" 1 "$(count ntfy-post "$CALLS")"; check "FAILED http=429" 1 "$(count 'FAILED prio=urgent title="Rate limited" http=429' "$CALLS")"

new_case "N4 network down (000 x3) -> 3 attempts, exit 0"
printf '000\n000\n000\n' > "$CURL_SEQ_FILE"
notify_run high "No network" "body" 2>/dev/null; rc=$?
show; check "exit code" 0 "$rc"; check "posts" 3 "$(count ntfy-post "$CALLS")"

new_case "N5 dedupe: same key twice -> one post, one suppressed"
notify_run --key wd.test urgent "Down" "first" 2>/dev/null
notify_run --key wd.test urgent "Down" "second" 2>/dev/null
show; check "posts" 1 "$(count ntfy-post "$CALLS")"; check "suppressed" 1 "$(count 'suppressed key=wd.test' "$CALLS")"
command sleep 0.5   # the wake-up runs in the background
check "caretaker woken once, through the stub" 1 "$(count 'WAKE alert wd.test Down' "$WAKES")"

new_case "N6 dedupe window expired (last sent 7h ago, every 6h) -> sent again"
notify_run --key wd.test urgent "Down" "first" 2>/dev/null
sf="$HOMELAB_NOTIFY_STATE/wd.test"; old=$(( $(date +%s) - 7*3600 ))
printf 'opened=%s\nlast_ok=%s\nlast_try=%s\n' "$old" "$old" "$old" > "$sf"
notify_run --key wd.test urgent "Down" "reminder" 2>/dev/null
show; check "posts" 2 "$(count ntfy-post "$CALLS")"

new_case "N7 --every 0: never repeats while open (last sent 30h ago)"
old=$(( $(date +%s) - 30*3600 )); mkdir -p "$HOMELAB_NOTIFY_STATE"
printf 'opened=%s\nlast_ok=%s\nlast_try=%s\n' "$old" "$old" "$old" > "$HOMELAB_NOTIFY_STATE/k0"
notify_run --key k0 --every 0 high "Once" "body" 2>/dev/null
show; check "posts" 0 "$(count ntfy-post "$CALLS")"

new_case "N8 failed alert is retried after 30 min, not on every call"
printf '000\n000\n000\n' > "$CURL_SEQ_FILE"
notify_run --key kf urgent "Down" "try 1" 2>/dev/null
notify_run --key kf urgent "Down" "try 2 (too soon)" 2>/dev/null
sf="$HOMELAB_NOTIFY_STATE/kf"; t=$(( $(date +%s) - 31*60 ))
sed -i "s/^last_try=.*/last_try=$t/" "$sf"
notify_run --key kf urgent "Down" "try 3 (after 31 min)" 2>/dev/null
show; check "posts (3 failed + 1 ok)" 4 "$(count ntfy-post "$CALLS")"; check "state marks delivered" 1 "$(grep -c '^last_ok=[1-9]' "$sf")"

new_case "N9 resolve with no open incident -> silent no-op"
notify_run --resolve nothing-open default "OK" "body" 2>/dev/null
show; check "posts" 0 "$(count ntfy-post "$CALLS")"; check "journal lines" 0 "$(count '\[journal\]' "$CALLS")"

new_case "N9b resolve with no open incident creates no lock/state files"
notify_run --resolve nothing-open default "OK" "body" 2>/dev/null
check "files created" 0 "$(find "$CASE" -path "$HOMELAB_NOTIFY_STATE/*" | wc -l)"

new_case "N10 resolve after a delivered alert -> all-clear sent, incident closed"
notify_run --key inc urgent "Down" "body" 2>/dev/null
notify_run --resolve inc default "Up again" "body" 2>/dev/null
notify_run --resolve inc default "Up again" "body" 2>/dev/null
show; check "posts (alert + one all-clear)" 2 "$(count ntfy-post "$CALLS")"; check "state removed" no "$([ -e "$HOMELAB_NOTIFY_STATE/inc" ] && echo yes || echo no)"

new_case "N11 resolve when the alert was never delivered -> closed, no all-clear"
printf '429\n' > "$CURL_SEQ_FILE"
notify_run --key inc2 urgent "Down" "body" 2>/dev/null
notify_run --resolve inc2 default "Up again" "body" 2>/dev/null
show; check "posts (only the failed alert)" 1 "$(count ntfy-post "$CALLS")"; check "closed line" 1 "$(count 'closed key=inc2' "$CALLS")"

new_case "N12 no topic anywhere -> error logged, no post, exit 0"
rm -f "$HOMELAB_SECRETS"
notify_run high "Nowhere" "body" 2>/dev/null; rc=$?
show; check "exit code" 0 "$rc"; check "posts" 0 "$(count ntfy-post "$CALLS")"; check "error logged" 1 "$(count 'no ntfy topic available' "$CALLS")"

new_case "N13 hostile key is sanitised (no path traversal)"
notify_run --key "../../evil/../x" high "Key" "body" 2>/dev/null
show; check "state file stays inside state dir" 1 "$(find "$HOMELAB_NOTIFY_STATE" -maxdepth 1 -type f | wc -l)"
check "nothing written outside" 0 "$(find "$W" \( -name x -o -name evil \) | wc -l)"

new_case "N14 state dir not writable -> sends without dedupe; resolve stays silent"
export HOMELAB_NOTIFY_STATE="/proc/no-such-dir/notify"
notify_run --key k high "No state" "body" 2>/dev/null
notify_run --resolve k default "OK" "body" 2>/dev/null
show; check "posts" 1 "$(count ntfy-post "$CALLS")"

new_case "N15 message starting with @ is sent literally (no file read)"
notify_run high "At" "@/etc/passwd" 2>/dev/null
show; check "posts" 1 "$(count ntfy-post "$CALLS")"

# ---------------------------------------------------------------- homelab-netprobe
# Offline only: a synthetic history file; report/summary/trim never open a socket.
NP="$BIN/homelab-netprobe"
new_case "P1 netprobe reading: far loss = ISP international, router loss = house, clean hour = ok"
export NETPROBE_DATA="$CASE/np.tsv"
python3 - "$NETPROBE_DATA" <<'EOF'
import sys, time
now = int(time.time()); now -= now % 3600
base = {"router": ("lan", 1), "cloudflare": ("near", 17), "google": ("near", 37),
        "frankfurt": ("far", 146), "virginia": ("far", 220), "tokyo": ("far", 355)}
with open(sys.argv[1], "w") as f:
    for t in range(now - 8 * 86400, now, 120):
        for n, (g, ms) in base.items():
            lost, m = 0, ms
            if now - 3 * 3600 <= t < now - 2 * 3600 and g == "far":   # 3 h ago: far lossy, tokyo slow
                lost, m = 1, (ms * 2 + 50 if n == "tokyo" else ms)
            if now - 2 * 3600 <= t < now - 3600 and g == "lan":       # 2 h ago: the router drops
                lost = 2
            f.write(f"{t}\t{n}\t{g}\t4\t{lost}\t{m}\t\n")
EOF
out=$(python3 "$NP" report 4)
echo "$out" | sed 's/^/      /'
h3=$(date -d "@$(( $(date +%s) / 3600 * 3600 - 3 * 3600 ))" +%H:00)
h2=$(date -d "@$(( $(date +%s) / 3600 * 3600 - 2 * 3600 ))" +%H:00)
check "3 h ago reads as the ISP's international routes" 1 "$(echo "$out" | grep "^$h3 " | grep -c "ISP international: far 25% loss")"
check "2 h ago reads as the house network" 1 "$(echo "$out" | grep "^$h2 " | grep -c "house network")"
check "tokyo flagged slow 3 h ago" 1 "$(echo "$out" | grep "^$h3 " | grep -c 'slow: tokyo')"
sum=$(python3 "$NP" summary)
check "summary: last hour clean" 1 "$(echo "$sum" | grep -c 'last hour: all paths clean')"
check "summary: names the worst far hour" 1 "$(echo "$sum" | grep -c "worst far hour $h3 25% loss")"
python3 - "$NP" <<'EOF'
import importlib.machinery, importlib.util, sys, time
loader = importlib.machinery.SourceFileLoader("np", sys.argv[1])
spec = importlib.util.spec_from_loader("np", loader); m = importlib.util.module_from_spec(spec); loader.exec_module(m)
m.trim(int(time.time()))
EOF
old=$(awk -v c=$(( $(date +%s) - 7 * 86400 - 10 )) '$1 < c' "$NETPROBE_DATA" | wc -l)
check "trim keeps 7 days" 0 "$old"
check "trim keeps the recent rows" yes "$([ "$(wc -l < "$NETPROBE_DATA")" -gt 30000 ] && echo yes || echo no)"
unset NETPROBE_DATA

new_case "P2 netprobe: a failed lookup on the Pi is not internet loss (2026-10-28)"
export NETPROBE_DATA="$CASE/np.tsv" NETPROBE_IPS="$CASE/ips"
python3 - "$NETPROBE_DATA" <<'EOF'
import sys, time
now = int(time.time()); now -= now % 3600
base = {"router": ("lan", 1), "cloudflare": ("near", 17), "google": ("near", 37),
        "frankfurt": ("far", 146), "virginia": ("far", 220), "tokyo": ("far", 355)}
with open(sys.argv[1], "w") as f:
    for t in range(now - 2 * 86400, now, 120):
        for n, (g, ms) in base.items():
            if now - 3600 <= t < now - 1800 and g == "far":   # last hour: the Pi's DNS is down
                f.write(f"{t}\t{n}\t{g}\t4\t4\t\tdns\n"); continue
            f.write(f"{t}\t{n}\t{g}\t4\t0\t{ms}\t\n")
EOF
sum=$(python3 "$BIN/homelab-netprobe" summary)
echo "      $sum"
check "unresolved rows are not read as ISP loss" 0 "$(echo "$sum" | grep -c 'ISP')"
check "the summary names the Pi's DNS failure" 1 "$(echo "$sum" | grep -c '24 h: all paths clean; Pi DNS failed 45x')"
res=$(python3 - "$BIN/homelab-netprobe" <<'EOF'
import importlib.machinery, importlib.util, socket, sys, time
loader = importlib.machinery.SourceFileLoader("np", sys.argv[1])
spec = importlib.util.spec_from_loader("np", loader); m = importlib.util.module_from_spec(spec); loader.exec_module(m)
class Conn:
    def close(self): pass
m.socket.create_connection = lambda addr, timeout=None: Conn()   # never opens a socket
def hang(*a, **k): time.sleep(30)
def fail(*a, **k): raise socket.gaierror("EAI_AGAIN")
m.RESOLVE_S = 0.2; m.GAP_S = 0
out = {}
m.socket.getaddrinfo = hang; t = time.time()
m.probe_one("frankfurt", "far", "far.example", 443, out, {"far.example": "192.0.2.1"})
print("hang", out["frankfurt"][3], out["frankfurt"][1], "fast" if time.time() - t < 2 else "slow")
m.socket.getaddrinfo = fail
m.probe_one("tokyo", "far", "far.example", 443, out, {})
print("noaddr", out["tokyo"][3], out["tokyo"][2])
m.socket.getaddrinfo = lambda *a, **k: [(0, 0, 0, "", ("192.0.2.9", 443))]
known = {}
m.probe_one("virginia", "far", "far.example", 443, out, known)
print("ok", repr(out["virginia"][3]), known.get("far.example"))
EOF
)
echo "$res" | sed 's/^/      /'
check "a hung lookup gives up fast and probes the last known address" 1 "$(echo "$res" | grep -c '^hang dns-cached 0 fast$')"
check "no known address: marked dns, no sample" 1 "$(echo "$res" | grep -c '^noaddr dns None$')"
check "a good lookup is remembered" 1 "$(echo "$res" | grep -c "^ok '' 192.0.2.9$")"
unset NETPROBE_DATA NETPROBE_IPS

echo
echo "PATH-stub hits (must be 0): $(cat "$W/path-stub-hits" 2>/dev/null | wc -l)"
[ -s "$W/path-stub-hits" ] && { cat "$W/path-stub-hits"; FAIL=$((FAIL + 1)); }
echo "RESULT: $PASS passed, $FAIL failed"
rm -rf "$W"
[ "$FAIL" = 0 ]
