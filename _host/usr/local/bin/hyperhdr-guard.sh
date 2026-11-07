#!/bin/bash
# hyperhdr-guard: restart HyperHDR when it grows past LIMIT_MB (it leaks memory; see
# /etc/systemd/system/hyperhdr@.service.d/limits.conf). Runs every minute from hyperhdr-guard.timer.
LIMIT_MB=300
pid=$(systemctl show -p MainPID --value hyperhdr@hyperhdr)
[ "${pid:-0}" -gt 0 ] || exit 0
rss=$(( $(awk '/^VmRSS/{print $2}' /proc/$pid/status 2>/dev/null || echo 0) / 1024 ))
if [ "$rss" -gt "$LIMIT_MB" ]; then
    echo "HyperHDR at ${rss} MB (limit ${LIMIT_MB}): restarting"
    systemctl restart hyperhdr@hyperhdr
fi
