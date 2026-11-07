#!/usr/bin/env bash
# Re-pin an AdGuard rewrite to a name's current public A records.
# Used for the house's one public Tailscale Funnel name: the LAN has no IPv6 and Tailscale's
# A records drift every few days, so AdGuard answers LAN clients with a pinned, verified set.
# Procedure: edited copy in /dev/shm, offline --check-config with the same image, stop,
# diff, install, start (~2 s DNS gap). Skips when the pin already matches.
set -euo pipefail
NAME=${PIN_NAME:-public.example-tailnet.ts.net}
CONF=$HOME/docker/adguard/conf/AdGuardHome.yaml
mapfile -t NEW < <(dig +short "$NAME" @8.8.8.8 | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort)
[ "${#NEW[@]}" -eq 3 ] || { echo "expected 3 public A records, got ${#NEW[@]}" >&2; exit 1; }
# Cheap no-op for the timer (adguard-pin.timer, every 20 min): nothing to do when the pin already matches.
PINNED=$(sudo grep -A1 "domain: $NAME" "$CONF" | awk '/answer:/{print $2}' | sort | tr '\n' ' ')
[ "$PINNED" = "${NEW[*]} " ] && { echo "pin already current"; exit 0; }
# Another disruptive job owns the maintenance flag: do not touch DNS now, the next run will.
[ -e /run/homelab/maintenance ] && { echo "maintenance in progress, skipping this run"; exit 0; }
for ip in "${NEW[@]}"; do
  [ "$(curl -s -m 10 -o /dev/null -w '%{http_code}' --resolve "$NAME:443:$ip" "https://$NAME/")" = 200 ] || { echo "$ip does not answer 200, not pinning" >&2; exit 1; }
done
D=$(sudo mktemp -d /dev/shm/agh.XXXX); trap 'sudo rm -rf "$D"' EXIT
sudo chmod 700 "$D"; sudo mkdir "$D/conf" "$D/work"
sudo cp "$CONF" "$D/conf/AdGuardHome.yaml"
sudo python3 - "$D/conf/AdGuardHome.yaml" "$NAME" "${NEW[@]}" <<'PY'
import re, sys
path, name, *ips = sys.argv[1:]
s = open(path).read()
pat = re.compile(r"(    - domain: %s\n      answer: )\S+(\n      enabled: true\n)" % re.escape(name))
it = iter(ips)
s, n = pat.subn(lambda m: m.group(1) + next(it) + m.group(2), s)
assert n == 3, "expected 3 rewrite entries, found %d" % n
open(path, "w").write(s)
PY
sudo docker run --rm --network none -v "$D/conf:/opt/adguardhome/conf" -v "$D/work:/opt/adguardhome/work" adguard/adguardhome:latest --no-check-update --check-config -c /opt/adguardhome/conf/AdGuardHome.yaml -w /opt/adguardhome/work 2>&1 | grep -q "configuration file is ok" || { echo "config check failed" >&2; exit 1; }
if sudo diff -q "$CONF" "$D/conf/AdGuardHome.yaml" >/dev/null; then echo "pin already current"; exit 0; fi
sudo touch /run/homelab/maintenance
docker stop adguard >/dev/null
if [ "$(sudo diff "$CONF" "$D/conf/AdGuardHome.yaml" | grep -c '^[<>]')" = 6 ]; then
  sudo install -o root -g root -m 600 "$D/conf/AdGuardHome.yaml" "$CONF"; echo installed
else echo "unexpected diff after stop, leaving the live file alone" >&2; fi
docker start adguard >/dev/null
sleep 3
dig +short +time=3 example.com @192.168.1.10 | head -1 | grep -q . || echo "WARNING: AdGuard did not answer example.com" >&2
echo "pin now: $(dig +short "$NAME" @192.168.1.10 | sort | tr '\n' ' ')"
sudo rm -f /run/homelab/maintenance
