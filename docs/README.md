# Docs

Read in order. Each one stands alone, but later ones assume the architecture from the first.

1. [Overview](../README.md): what runs, the goals in priority order, how a change is made.
2. [Design decisions](design-decisions.md): remote access, the public surface, Docker and
   ufw, DNS without a fallback, verified backups, drift checks, tiered updates, the flash
   stick, and the maintenance switch.
3. [Past failures and what changed](past-failures.md): seven incidents, their root causes,
   and the change each one left behind.
4. [Backups and restore](backups-and-restore.md): the backup engine, what each set holds,
   the weekly restore drill, and the rebuild from bare hardware.
5. [Monitoring and alerts](monitoring-and-alerts.md): the alert layers, the deduplicating
   notifier, the daily health check, the dead-man switch and the stubbed tests.
6. [AI operator](ai-operator.md): the always-on Claude Code session, how it is woken, what
   it may and may not do, and how to stop it.
7. [TV ambient lighting](tv-ambient-lighting.md): Hue lamps that follow the TV picture,
   from the sampling on the TV to the colour math on the Pi.

Security model and reporting: [SECURITY.md](../SECURITY.md). The README images and how
they are made: [`readme/`](readme) and [`scripts/`](../scripts).
