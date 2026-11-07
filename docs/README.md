# Docs

Read in order. Each one stands alone, but later ones assume the architecture from the first.

1. [Architecture](../README.md): services, network, design decisions, past failures, how
   a change is made.
2. [Backups and restore](backups-and-restore.md): the backup engine, what each set holds,
   the weekly restore drill, and the rebuild from bare hardware.
3. [Monitoring and alerts](monitoring-and-alerts.md): the alert layers, the deduplicating
   notifier, the daily health check, the dead-man switch and the stubbed tests.
4. [AI operator](ai-operator.md): the always-on Claude Code session, how it is woken, what
   it may and may not do, and how to stop it.
5. [TV ambient lighting](tv-ambient-lighting.md): Hue lamps that follow the TV picture,
   from the sampling on the TV to the colour math on the Pi.

Security model and reporting: [SECURITY.md](../SECURITY.md).
