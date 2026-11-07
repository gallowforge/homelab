# Past failures and what changed

Each of these cost an outage, data, or a morning of diagnosis. Each ended in a change to
the configuration, a new check, or a written rule the operator follows.

1. **Remote access through a public domain, and a VPN that never connected.**
   - *What broke:* the first setup published about 17 services under a public domain,
     first with its own certificates, then behind a Cloudflare Tunnel. A self-hosted
     WireGuard server ran alongside it and never completed a handshake. Four stale port
     forwards to the Pi, DNS among them, were still open on the router.
   - *Root cause:* the ISP uses CGNAT, so nothing inbound can reach the house, and the
     public names put admin panels on the internet for no real gain.
   - *Now:* Tailscale only. Port forwarding and UPnP are off, WireGuard was purged with its
     keys and firewall rules, and the tunnel and domain are gone. Written rule: no new
     public names, no new open ports.

2. **A fallback DNS server broke every local link on Apple devices.**
   - *What broke:* the router handed out a public resolver as a second DNS server so the
     house would survive the Pi going down. Apple devices then lost the Pi's name, and
     every bookmark to it stopped working.
   - *Root cause:* Apple's resolver races all configured servers. The public one answered
     NXDOMAIN for the private name, and that answer often won.
   - *Now:* the Pi is the only resolver and the router redirects any other DNS to it. The
     single point of failure is managed in place (see
     [No fallback DNS, on purpose](design-decisions.md#no-fallback-dns-on-purpose)). Hard rule: never add a
     fallback resolver for clients.

3. **Arming the hardware watchdog reset the Pi and damaged the boot partition.**
   - *What broke:* minutes after a 15-second systemd watchdog was armed, the Pi reset
     itself during a 3-second backup run. The boot-time FAT check truncated `cmdline.txt`
     to 0 bytes, the newest git objects came back empty, and three container logs had runs
     of NUL bytes. That boot worked only because the bootloader had already read the old
     file; the next one would not have found the root filesystem.
   - *Root cause:* PID 1 most likely blocked for more than 15 seconds on writes to the
     flash stick, and the stick lost its recent writes in the abrupt reset.
   - *Now:* the watchdog is off by design. Rebooting, editing `/boot/firmware`, forcing
     fsck and arming the watchdog happen only with someone at the Pi. The health check
     reports every abrupt reset. `cmdline.txt` was restored from a checksummed copy and
     the repo from its previous commit, with `git fsck --full` clean.

4. **A memory leak made the whole house's internet feel slow.**
   - *What broke:* "the internet is very laggy". The internet was fine. The Pi had 55 MB
     free, swap full on the flash stick and a load of 36, and every DNS lookup in the house
     waited on it.
   - *Root cause:* `tv-mood` opened a new HyperHDR connection every second, and HyperHDR
     leaks memory per connection: 2.6 GB in under two days. `MemoryMax=` would have capped
     it, but Raspberry Pi OS boots with the memory cgroup disabled, so systemd memory limits
     silently do nothing.
   - *Now:* one kept-open connection. `hyperhdr-guard.timer` restarts HyperHDR past
     300 MB, 1 GB of zstd zram swap sits ahead of the swap file on the stick, and the health
     check alerts below 800 MB available, naming the biggest process. Runbook order for
     "the internet is slow": the Pi first, then the ISP.

5. **Watchtower reported healthy while it could not reach Docker.**
   - *What broke:* two scheduled update runs failed with "Cannot connect to the Docker
     daemon". The container's health check stayed green and nothing alerted.
   - *Root cause:* restarting dockerd recreates `/var/run/docker.sock`. A container that
     bind-mounts it keeps the old, deleted inode.
   - *Now:* the health check compares the socket inode inside every container that mounts
     it with the host's, and names the container to restart.

6. **A partial upstream fault became a 25-minute whole-house DNS outage.**
   - *What broke:* house DNS nearly stopped answering. The network probe reported it as
     24% international packet loss, and the operator session went deaf too, because its
     own lookups use the same resolver.
   - *Root cause:* plain DNS to public resolvers timed out upstream while TCP still worked.
     AdGuard's browsing-security feature makes every query, cached ones included, wait on a
     lookup at a server abroad; about 3,600 connections piled up there and turned a partial
     fault into a total one. The probe resolved its targets by name, so it could not tell a
     DNS failure from packet loss.
   - *Now:* browsing security is off. The probe gives a lookup 5 seconds, then tests the
     last known address, and reports lookup failures as their own category. No automatic
     AdGuard restart was added: a restart would not have helped, and DNS is not restarted
     automatically without evidence that it fixes something.

7. **The restore drill failed a backup that was fine.**
   - *What broke:* the weekly drill failed the secrets set: 1 of 24 restored files differed
     from live.
   - *Root cause:* Home Assistant runs its own nightly backup at a drifting time near
     05:00, sometimes after ours, and rewrites the history part of the file that holds its
     backup encryption key. The key, the reason the file is backed up, was identical.
   - *Now:* the drill checks that file by its key only and lists files modified after the
     archive in the PASS line instead of failing. A changed key still fails, tested with a
     tampered copy. A drill that cries wolf teaches people to ignore it, so the test was
     fixed rather than re-run.
