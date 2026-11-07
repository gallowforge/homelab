# Changelog

## Initial public release

A sanitized copy of the private repo that runs the Pi.

**Included**
- Docker Compose stacks for AdGuard Home, Caddy, Vaultwarden, CouchDB, Home Assistant,
  Syncthing, Uptime Kuma, Dockge and Watchtower, with `.env.example` files listing the
  variable names.
- Host configuration under `_host/` at its live paths: systemd units and timers, ufw and
  `DOCKER-USER` rules, fail2ban, journald, sysctl, tmpfiles and Docker daemon settings,
  with a `MANIFEST` and `install.sh` to diff, apply, pull and bootstrap them.
- The backup engine and its list of sets, the weekly restore drill, the daily health check,
  the deduplicating notifier, the heartbeat gate, the network probe, and the scripts that
  keep the AI operator session running and wake it on alerts.
- The TV ambient lighting chain (`tv-mood`, the HyperHDR guard) and the Home Assistant
  configuration around it.
- The pre-commit hook that refuses secrets, and a stubbed test suite (43 checks).
- Docs: architecture and design decisions, past failures, backups and restore, monitoring
  and alerts, the AI operator, TV ambient lighting, and a security policy.
- CI that runs syntax checks, shellcheck, a YAML parse, the backup config check, the
  stubbed tests and gitleaks on every push.

**Left out**
- A media stack, its public endpoint, a watch-history tracker, and their watchdogs and
  timers.
- Scripts that reach into other personal machines or data.
- The private runbooks, the operator's charter and its journal. The files in `docs/` are
  condensed public versions.

**Changed from the live repo**
- LAN addresses use `192.168.1.x`, tailnet addresses `100.64.0.x`, and the tailnet is
  `example-tailnet.ts.net`. Device IDs, MAC addresses and a session ID are placeholders.
