# Security

This repo is a sanitized public copy of the configuration that runs a home server. It
publishes no running service. The useful reports are about what is in the files: a secret
that slipped through, or a published default that would be unsafe for someone who copies
it.

## Threat model

**What is exposed.** Nothing on the router is forwarded and UPnP is off. The ISP uses
CGNAT, so nothing inbound reaches the house regardless. In this copy no service is public.
(The live Pi publishes one name through Tailscale Funnel, for a service that is not part of
this copy.)

**Who can reach what.**
- *LAN devices*: DNS on `:53`, Caddy's TLS ports `:8443-8453`, and Home Assistant on
  `:8123` for phone shortcuts. AdGuard's and Syncthing's admin UIs listen only for Caddy;
  ufw denies them to the LAN. Vaultwarden, CouchDB, Uptime Kuma and Dockge have no host port.
- *Tailnet devices*: the same Caddy sites over WireGuard, with the tailnet's certificate.
- *Containers*: ufw admits only DNS and three host-network ports from Docker networks.
  [`after.rules`](_host/etc/ufw/after.rules) fills `DOCKER-USER`, so a Docker-published
  port cannot be reached from outside the LAN by bypassing ufw's INPUT rules.
- *SSH*: keys only, no root login, LAN and tailnet only. fail2ban watches sshd.

**What is defended against.** A compromised or curious device on the LAN, a leaked secret
in this repo, a container trying to reach host services it does not need, and an unsafe
default carried into someone else's copy.

**Accepted risks, written down.**
- Dockge holds `docker.sock`, which is root on the host. It is reached only through Caddy,
  behind its own login.
- The Pi is the house's only DNS resolver, on purpose (README,
  [No fallback DNS, on purpose](README.md#no-fallback-dns-on-purpose)).
- The operator is an AI session with root on the Pi, bound by a written charter and
  stoppable with one command ([docs/ai-operator.md](docs/ai-operator.md)).
- Physical access to the Pi is not defended against; the Pi sits inside the home.

## How secrets are handled

- **Never in git.** Each stack's secrets are in a `.env` file next to its compose file,
  mode 600, never tracked. The `.env.example` beside it lists the variable names with
  placeholder values. Host scripts read `/etc/homelab/secrets.env` (mode 600); its names
  are in [`secrets.env.example`](_host/etc/homelab/secrets.env.example).
- **The `.gitignore` is a whitelist.** Everything is ignored unless listed, so a new data
  directory, database or key file cannot be committed by accident.
- **A pre-commit hook is the second line.** [`pre-commit`](_host/git-hooks/pre-commit)
  refuses secret-bearing file types (`.env`, databases, keys, Tailscale state) and added
  lines that match known secret shapes. It prints only `file:line` and the rule name,
  never the matched text.
- **CI is the third.** gitleaks scans the full history on every push
  ([validate.yml](.github/workflows/validate.yml)).
- **Backups do not carry secrets where they should not go.** The `secrets` set lives only
  on the Pi and the desktop PC; the PC's Syncthing ignore file holds it back from the
  laptop, and the laptop push script refuses to run if it appears. The `platform` set,
  which collects host configuration and does travel, has `forbid` rules in
  [`backups.conf`](_host/etc/homelab/backups.conf): an archive that would contain a
  `.env`, `secrets.env` or network connection secrets fails instead of being shipped.
- **Values in this copy are placeholders.** LAN addresses are `192.168.1.x`, tailnet
  addresses `100.64.0.x`, the tailnet `example-tailnet.ts.net`. Device IDs and MAC
  addresses are made up.

## Reporting

**In scope**
- A secret, token, private key or real address committed anywhere in the history.
- An unsafe default in a published config or script: a port bound wider than documented,
  a missing authentication step, a firewall rule that does not do what its comment says,
  a script that could leak a secret into logs or notifications.
- A gap in the pre-commit hook or the backup `forbid` rules that would let a secret through.

**Out of scope**
- Problems in your own deployment caused by changing these files.
- Attacks that need physical access to the hardware or an already compromised LAN device
  with root.
- Vulnerabilities in the upstream projects (AdGuard Home, Vaultwarden, Caddy and others).
  Report those to the project.
- Findings from automated scanners without a concrete path to harm.

**How.** Email `ali@gallowforge.dev` with what you found and where (file and
commit). Please do not open a public issue for a committed secret; the secret has to be
rotated first, then the history dealt with.
