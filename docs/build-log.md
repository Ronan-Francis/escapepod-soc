# Build log

## Phase 1: first working version

### 2026-10-04: groundwork

**Done**
- Phase 0 survey of the Pi (OS, network, ports, Docker, SSH, logging).
- Storage: the plan was a USB drive for log data, but it dropped off the bus with I/O errors
  (`error -71`) while being formatted. Data now lives on the SD card at `/srv/soc-data` instead.
- Installed Docker Engine and the Compose plugin; container logs capped at 10 MB × 3 (json-file).
- Dropped Tailscale from the plan. Anything private is bound to 127.0.0.1 and reached through an SSH tunnel.

### 2026-10-05: SSH, logging stack, decoys, alerts

**Done**
- **Real SSH locked down:** moved to 2222 in two stages (both ports, test, then 2222 only), key-only,
  no root login. Tested from a second session before closing the first.
- **Firewall:** ufw default deny inbound, LAN-only rules for 2222 and the decoy ports. A 10-minute
  auto-disable timer was armed while enabling it, as a lockout safety net, then cancelled once tested.
- **Logging stack:** Loki, Alloy, Grafana and a read-only Docker socket proxy, all pinned, memory-capped,
  with published ports on 127.0.0.1. Grafana tested through the SSH tunnel.
- **Decoys:** OpenCanary SSH/FTP/HTTP and a Samba SMB decoy, each tested from my PC.
- **Alerts:** switched from Telegram to email (no extra third party holding alert data), sent from a
  throwaway Gmail account. Six rules, each triggered and confirmed on my phone.
- **Disk check:** a systemd timer that logs disk usage to the journal (no metrics database).
- **Boot:** Docker now waits for NTP sync before starting.
- **Repo:** git initialised; README, architecture and detections docs written.

**What broke, and the fix**

| Problem | Cause | Fix |
|---|---|---|
| Docker memory limits silently ignored | Pi firmware adds `cgroup_disable=memory` | `cgroup_enable=memory` at the end of `cmdline.txt` (later argument wins) |
| Firewall would have locked me out | My PC reaches the Pi over **IPv6 link-local**, not IPv4 | Rules for both `<LAN>` and `fe80::/10` |
| Container logs missing | `discovery.docker` also needs `GET /networks`; proxy returned 403 | `NETWORKS: 1` (still read-only) |
| `host` label was the container ID | `constants.hostname` inside a container | Alloy container `hostname` from `.env` |
| Grafana downloaded and updated plugins on start | `preinstall` and auto-update are on by default | `GF_PLUGINS_PREINSTALL_DISABLED=true`, deleted downloaded plugins |
| OpenCanary decoys missed IPv6 | default listen address is IPv4 only | `device.listen_addr: "::"` (dual-stack) |
| OpenCanary events never reached Loki | Alloy started 2 s before the log file existed and gave up on it | `local.file_match` re-checks every 10 s |
| SMB decoy refused every share | `full_audit.so` is in Debian's `samba-vfs-modules` | Added the package (same pinned version) |
| First FTP test "failed" | PowerShell's `curl` is `Invoke-WebRequest`; nothing was sent | `curl.exe` |
| Grafana contact-point test API gone | Removed in Grafana 13 | Tested end to end by touching a decoy instead |
| Early-boot events stamped hours in the past | No RTC battery; clock restored from last shutdown until NTP | Docker waits for `time-sync.target` (2-minute cap) |
| OpenCanary crashed 3× at boot | Stale `twistd` PID file matched a new process's PID | tmpfs on `/run` in the container |
| Accidental power cut | (unplugged) | Everything came back by itself, no filesystem errors |

**Findings outside the project**
- My Windows PC accepts insecure guest SMB logins (the decoy accepted a guest session from it).
- `pi` has passwordless sudo (Raspberry Pi OS default). Walk-through and decision pending at the close of Phase 1.

**Seen, believed harmless**
- dockerd at boot: `Failed deleting service host entries … no such file or directory`. Containers unaffected.

**Next**
- Passwordless sudo decision.
- Final reboot test.
- First commit, then a public GitHub repo.
- Screenshots (redacted) for the README.
