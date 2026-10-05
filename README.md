# escapepod-soc

A small home security operations setup on a Raspberry Pi 5. It collects the Pi's own logs,
runs **decoy services** (honeypots) that nobody should ever touch, and **emails my phone within
about 35 seconds** when something does.

Built as a learning and portfolio project: everything runs in Docker, every alert is tested,
and every design choice is written down.

## What it does

- **Four decoys** on the home network: fake SSH (22), FTP (21) and an HTTP login page (80) from
  [OpenCanary](https://github.com/thinkst/opencanary), plus a real Samba server with a read-only bait
  share (445). Any touch is an alert, because nothing legitimate uses them.
- **Host monitoring** of the Pi itself: brute force against the real SSH server, failed sudo,
  new user accounts, and the SD card filling up.
- **Email alerts** with the useful details: source address, service, and the username and password
  the intruder typed.

| Alert | MITRE ATT&CK |
|---|---|
| Decoy touched (SSH/FTP/HTTP) | T1110.001, T1046 |
| Decoy touched (SMB share) | T1021.002, T1135 |
| Repeated failed SSH logins | T1110 |
| Failed sudo | T1548.003 |
| New local user | T1136.001 |
| SD card filling up | operational |

Details, queries and how to test each one: **[docs/detections.md](docs/detections.md)**.

## How it works

```
decoys / sshd / sudo / useradd ──► journal, log files, container logs
                                           │
                                    Grafana Alloy  (collects, labels)
                                           │
                                         Loki      (stores 7 days, 127.0.0.1 only)
                                           │
                                        Grafana    (alert rules, 127.0.0.1 only)
                                           │
                                      Gmail SMTP ──► phone
```

Full diagram, port list and design reasons: **[docs/architecture.md](docs/architecture.md)**.

## Constraints I built within

- **A shared family network with no router access.** No port forwarding, nothing exposed to the
  internet, and **no scanning or sniffing of anyone else's devices**. The decoys only listen; all
  testing came from my own PC.
- **Wi-Fi only, no new hardware**, and the Pi is **switched off every night**, so everything has to
  start on its own at boot and cope with gaps in the logs.

## Security design highlights

- Real SSH is key-only on port 2222; port 22 is the decoy.
- ufw: default deny inbound, LAN-only allow rules. Docker-published ports bypass ufw, so Loki and
  Grafana are bound to 127.0.0.1 and reached through an SSH tunnel.
- The log collector reaches Docker through a **read-only socket proxy**, never `docker.sock`.
- Least privilege throughout: `cap_drop: ALL`, `no-new-privileges`, non-root where possible, memory limits.
- Pinned image versions, and Grafana's automatic plugin downloads switched off.
- Alerts are sent from a **throwaway Gmail account**, so a compromised Pi can't reach my real inbox.
- At boot, Docker waits for NTP, so events are never stamped with a stale clock (the Pi has no RTC battery).

## Setup

Tested on a Raspberry Pi 5, Raspberry Pi OS 64-bit (Debian 12 "bookworm"), Docker Engine 29 with
the Compose plugin. Adapt the placeholders in `<angle brackets>`.

**1. Clone and create `.env`**
```bash
git clone <this-repo-url> escapepod-soc && cd escapepod-soc
cp .env.example .env && chmod 600 .env && nano .env
```
For email alerts, create a **separate** Gmail account, turn on 2-step verification, and create an
[app password](https://myaccount.google.com/apppasswords) for `SMTP_PASSWORD`.

**2. Enable Docker memory limits** (the Pi's firmware turns them off). Append ` cgroup_enable=memory`
to the single line in `/boot/firmware/cmdline.txt`, then reboot. Check with `docker info` (no memory-limit warning).

**3. Move real SSH to 2222, key-only.** Set up key login first and keep a session open while testing:
```bash
sudo install -m 644 system/sshd_config.d/10-escapepod.conf /etc/ssh/sshd_config.d/
sudo sshd -t && sudo systemctl reload ssh
```

**4. Firewall** (`<LAN_SUBNET>` is your LAN, e.g. a /24):
```bash
sudo ufw default deny incoming && sudo ufw default allow outgoing
for src in <LAN_SUBNET> fe80::/10; do
  sudo ufw allow in on wlan0 proto tcp from $src to any port 2222
  sudo ufw allow in on wlan0 proto tcp from $src to any port 21,22,80,445
done
sudo ufw enable
```

**5. Data folders**, each owned by the user its container runs as:
```bash
sudo install -d -m 750 -o 10001 -g 10001 /srv/soc-data/loki
sudo install -d -m 750 -o 472   -g 472   /srv/soc-data/grafana
sudo install -d -m 750 -o 473   -g 473   /srv/soc-data/alloy
sudo install -d -m 750 -o 65534 -g 473   /srv/soc-data/opencanary
```

**6. systemd: disk check timer, and wait for NTP before Docker**
```bash
sudo install -m 755 system/soc-diskcheck.sh /usr/local/sbin/soc-diskcheck
sudo install -m 644 system/soc-diskcheck.service system/soc-diskcheck.timer /etc/systemd/system/
sudo install -D -m 644 system/docker.service.d/10-escapepod-wait-for-time.conf \
  /etc/systemd/system/docker.service.d/10-escapepod-wait-for-time.conf
sudo install -D -m 644 system/systemd-time-wait-sync.service.d/10-escapepod-timeout.conf \
  /etc/systemd/system/systemd-time-wait-sync.service.d/10-escapepod-timeout.conf
sudo systemctl daemon-reload
sudo systemctl enable --now soc-diskcheck.timer
sudo systemctl enable systemd-time-wait-sync.service
```

**7. Start the stack**
```bash
docker compose build && docker compose up -d
docker compose ps
```

**8. Open Grafana** from your PC through an SSH tunnel, then browse to http://localhost:3000
(user `admin`, password from `.env`):
```bash
ssh -p 2222 -N -L 3000:127.0.0.1:3000 pi@<pi-hostname>
```

**9. Test every alert** using the commands in [docs/detections.md](docs/detections.md).

## Screenshots

_To add: an alert email, Grafana Explore showing decoy events, the alert rules list.
IP addresses, device names and email addresses redacted._

## Known limitations

- The `pi` user has passwordless sudo (the Raspberry Pi OS default), so it can never trigger the failed-sudo alert.
- The journal lives in RAM: anything logged in the last seconds before power-off may never reach Loki.
- The SMB decoy is a real Samba server, so it has a bigger attack surface than OpenCanary's emulated
  services. That's reduced by a container, a read-only share, no SMB1, and only 3 capabilities.
- No alert if the Pi goes offline (it's off every night by design).

## What I learned

_Draft points, to be rewritten in my own words:_

- **Test that the test actually ran.** In Windows PowerShell, `curl` is an alias for
  `Invoke-WebRequest`; my first FTP decoy test never left the PC, and the decoy had nothing to report.
- **Timing bugs hide at boot.** Three separate start-up races showed up only after restarts: a log
  file that didn't exist yet, a stale PID file, and a stale clock with no RTC battery.
- **IPv6 is already on your LAN.** My PC reached the Pi over IPv6 link-local by default, and an
  IPv4-only firewall rule or decoy would have locked me out or missed the attack.
- **Least privilege needs testing too.** I checked each container's effective capabilities, rather
  than assuming the image dropped privileges.
- **The decoy found a real weakness in its own tester:** my Windows PC accepted insecure guest SMB logins.

## Repo layout

```
docker-compose.yml        all services
.env.example              settings and secrets template (real .env is gitignored)
config/                   Alloy, Loki, Grafana provisioning (datasource, alerts), OpenCanary, Samba
docker/samba-decoy/       Dockerfile for the SMB decoy
system/                   sshd, systemd timer and drop-ins installed on the host
docs/                     architecture, detections, build log
```
