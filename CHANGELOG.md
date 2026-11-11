# Changelog

## Unreleased

### README and docs checked against the repository

- The images that show the `platform` backup set (the hero, the nightly backup and the restore
  drill) were captured again with `scripts/readme-demo.sh`, so they show what the scripts print
  for this copy today: 31 units, and 146 files in the bundle.
- The link from `docs/design-decisions.md` to the goals lands on a heading that exists, and the
  Quality table says what the 14 YAML files are.

### A generic public copy

- Every compose file reads its time zone from `TZ` and falls back to `UTC`; the README and
  the `.env.example` files document it. The network probe's report says "local time".
- The Home Assistant configuration is reduced to a few illustrative routines with generic
  entity names (`media_player.tv`, `scene.living_room_*`). The door-lock automations are
  replaced by one generic battery alert over example sensors.
- The operator's account-login reminder (`claude-login-check`) is removed, and the session
  launcher no longer carries remote-access flags. The charter, the wake-ups and the
  keepalive are unchanged.
- Docs and comments describe a room and its devices in general terms instead of one
  particular home.

### README in the Glass look

- The README images are now real output as frosted-glass windows floating in light, the
  same family as the author's GitHub profile, in a dark and a light version that follow
  GitHub's theme, each with a phone layout. The control-room board is retired.
- Each image lifts out the one line that proves its point: the drill's result, Vaultwarden
  restored and identical to live, the held-back push, the drifted line put back, the
  command that stops the operator, the internet with no way in. The hero is an 8-second
  loop in which only the light moves.
- The README is shorter and leads with the evidence; the goals, the services and the
  repository layout moved into collapsed sections.
- `scripts/readme-visuals.sh` now typesets each window from `docs/readme/src/demo/*.txt`
  (dates and archive names removed so the images do not age) and renders the scenes with
  three.js in headless Chromium. See `docs/readme/IDENTITY.md`.

## 1.0.1

### Visual identity

- The README images were redrawn as panels of one control-room mimic board: navy enamel,
  engraved ivory, signal lamps (Saira and Martian Mono). Each feature gets its own
  instrument: panel meters, a locked-out breaker, an event printer, a synchroscope, an
  annunciator, discrepancy switches and standing orders. The content is unchanged: the
  same captured demo output, ports and timers. See `docs/readme/IDENTITY.md`.
- `scripts/readme-visuals.sh` now also renders the social preview, `docs/readme/social.png`.

### README and visuals

- The README was rebuilt around designed images in `docs/readme/`: a hero diagram, the
  numbers, a status board, the backup engine, the restore drill, the alert path, the drift
  check and the operator's charter.
- The terminal images show real output. `scripts/readme-demo.sh` runs the backup engine,
  the restore drill, `install.sh`, the failure notifier and the caretaker wake-up in a
  bubblewrap sandbox on synthetic data; `scripts/readme-visuals.sh` renders the images.
- The design decisions and the past failures moved to `docs/design-decisions.md` and
  `docs/past-failures.md`, unchanged in substance.
- The account name in paths and units is now the placeholder `pi`.

## 1.0.0: initial public release

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
- A few services, their public endpoint, and their watchdogs and timers.
- Scripts that reach into other personal machines or data.
- The private runbooks, the operator's charter and its journal. The files in `docs/` are
  condensed public versions.

**Changed from the live repo**
- LAN addresses use `192.168.1.x`, tailnet addresses `100.64.0.x`, and the tailnet is
  `example-tailnet.ts.net`. Device IDs, MAC addresses and a session ID are placeholders.
