# Detections

Every alert is a Grafana rule defined as a file in
[`config/grafana/provisioning/alerting/`](../config/grafana/provisioning/alerting/).
Each rule runs a LogQL query against Loki and emails me when the result is above a threshold.

| # | Alert | Source | Fires when | MITRE ATT&CK |
|---|-------|--------|------------|--------------|
| 1 | Decoy touched (SSH/FTP/HTTP) | OpenCanary | any interaction | T1110.001, T1046 |
| 2 | Decoy touched (SMB file share) | Samba decoy | any login attempt | T1021.002, T1135 |
| 3 | Repeated failed SSH logins | journal (sshd) | 5 or more from one source in 10 min | T1110 |
| 4 | Failed sudo attempt | journal (sudo) | any | T1548.003 |
| 5 | New local user account created | journal (useradd) | any | T1136.001 |
| 6 | SD card filling up | journal (soc-diskcheck) | above 85% | n/a (operational) |

Measured end to end, from touching a decoy to the email being sent: about 35 seconds.

---

## 1. Decoy touched (SSH/FTP/HTTP)

**What it catches:** any connection or login attempt on OpenCanary's fake SSH (22), FTP (21) or
HTTP login page (80). The email includes the service, the source address and any username and password typed.

**Why it matters:** these services exist only as bait, so nobody legitimate ever touches them.
Unlike a real server, a decoy has almost no false positives: any hit means something on the
network is scanning or trying logins. A decoy SSH on port 22 is also what an automated scanner
tries first, which is why real SSH moved to 2222.

**Query (simplified):**
```logql
sum by (service, src_host, username, password) (
  count_over_time({job="opencanary", service=~"ssh|ftp|http"}
    | json username="logdata.USERNAME", password="logdata.PASSWORD" [1m]))
```
`service=~"ssh|ftp|http"` leaves out OpenCanary's own startup and heartbeat events (logtype 1000–1006).

**How to test (from another machine on the LAN, with made-up credentials):**
```powershell
curl.exe ftp://<pi-ip>/ --user alerttest:NotARealPass1        # Windows: curl.exe, not curl
ssh -p 22 -o StrictHostKeyChecking=no fakeuser@<pi-ip>         # type any password
# or open http://<pi-ip>/ in a browser and submit the login form
```

**MITRE:** T1110.001 Brute Force: Password Guessing; T1046 Network Service Discovery (a bare connection with no login).

**Notes:** anything typed into a decoy ends up in Loki and in an email. Treat test credentials as public.

---

## 2. Decoy touched (SMB file share)

**What it catches:** login attempts against the Samba decoy share on port 445. The email includes the
source, the username tried, the client's machine name and the result. SMB never sends passwords in
plain text (NTLMv2 is a challenge-response), so unlike the other decoys there's no password to capture.

**Why it matters:** SMB shares are a favourite target for lateral movement and data theft on Windows
networks. Listing shares and browsing them is classic discovery behaviour.

**Query (simplified):**
```logql
sum by (src, user, workstation, status) (
  count_over_time({service="smb-decoy"} |= "\"type\": \"Authentication\""
    | json src="Authentication.remoteAddress", user="Authentication.clientAccount",
           workstation="Authentication.workstation", status="Authentication.status" [1m]))
```
Samba's `auth_json_audit` logging writes one JSON line per login attempt, with event ID 4625 for a
failure, the same ID as Windows' "An account failed to log on". File-level activity (connects, file
opens) comes from Samba's `full_audit` module and is kept in Loki for investigation.

**How to test (Windows, with explicit fake credentials):**
```powershell
net use \\<pi-ip>\Backups /user:alerttest NotARealPass2
net use \\<pi-ip>\Backups /delete
```
⚠️ Don't browse to the share in File Explorer. Windows automatically sends your real account name.

**MITRE:** T1021.002 Remote Services: SMB/Windows Admin Shares; T1135 Network Share Discovery.

---

## 3. Repeated failed SSH logins (real sshd)

**What it catches:** 5 or more rejected logins from one source address within 10 minutes on the
real SSH server (port 2222, key-only).

**Why it matters:** with passwords disabled, nobody can actually guess their way in, but repeated
attempts show that someone has found the real SSH port and is trying to get in.

**Query (simplified):**
```logql
sum by (src) (
  count_over_time({job="journal", syslog_identifier=~"sshd|sshd-session"}
    |~ "Invalid user |Connection closed by authenticating user |Failed (password|publickey) for "
    | regexp `(?P<src>[0-9A-Fa-f.:]+(%\w+)?) port \d+` [10m]))   > 4
```
With key-only login, a failure shows up as `Invalid user …` (unknown name) or
`Connection closed by authenticating user …` (real name, no valid key). The regex handles IPv4 and
IPv6 link-local sources.

**How to test:**
```powershell
1..5 | % { ssh -p 2222 -o PubkeyAuthentication=no -o BatchMode=yes nosuchuser@<pi-ip> }
```

**MITRE:** T1110 Brute Force.

---

## 4. Failed sudo attempt

**What it catches:** sudo's own failure lines: `incorrect password attempt`, `user NOT in sudoers`,
`command not allowed`.

**Why it matters:** someone trying to become root, either with a guessed password or from an
account that shouldn't have admin rights. That's a classic step after getting a foothold.

**Query (simplified):**
```logql
sum by (user, command) (
  count_over_time({job="journal", syslog_identifier="sudo"}
    |~ "incorrect password attempt|NOT in sudoers|command not allowed"
    | regexp `^\s*(?P<user>\S+) : ` | regexp `COMMAND=(?P<command>.*)$` [2m]))
```

**How to test (on the Pi):**
```bash
sudo useradd -M -s /usr/sbin/nologin canarytest
sudo -u canarytest sh -c 'echo wrong | sudo -S -k true'
sudo userdel canarytest
```

**Known gap:** the default `pi` user has passwordless sudo (Raspberry Pi OS default), so `pi` can
never *fail* sudo, and this rule only catches other accounts. See the build log for the decision on this.

**MITRE:** T1548.003 Abuse Elevation Control Mechanism: Sudo and Sudo Caching.

---

## 5. New local user account created

**What it catches:** `useradd` (also used by `adduser`) logging `new user: name=…, UID=…`.

**Why it matters:** creating a local account is a common way for an attacker to keep access after
the first break-in. On a single-user Pi, a new account should never appear unexpectedly.

**Query (simplified):**
```logql
sum by (new_user, uid) (
  count_over_time({job="journal", syslog_identifier="useradd"} |= "new user:"
    | regexp `name=(?P<new_user>[^,]+), UID=(?P<uid>\d+)` [2m]))
```

**How to test:** the `useradd` in the sudo test above sets off this rule too.

**Known gap:** an attacker who is already root could edit `/etc/passwd` directly, which bypasses `useradd`.

**MITRE:** T1136.001 Create Account: Local Account.

---

## 6. SD card filling up

**What it catches:** root filesystem usage above 85%.

**Why it matters:** this is an operational alert. If the SD card fills up, Loki stops storing logs
and every other detection goes blind.

**How it works without a metrics database:** a systemd timer
([`system/soc-diskcheck.*`](../system/)) runs every 15 minutes and writes one line to the journal,
`root_used_pct=5 avail_gb=423.0`. Alloy already ships the journal to Loki, and the rule reads the
number back out of that line:
```logql
max by (host) (max_over_time({job="journal", syslog_identifier="soc-diskcheck"}
  | logfmt | unwrap root_used_pct [30m]))   > 85
```

**How to test (fake reading, clears itself within 30 minutes):**
```bash
logger -t soc-diskcheck "root_used_pct=99 avail_gb=1.0 test=synthetic"
```

---

## Deliberately not alerted on

- **"Pi offline":** the Pi is switched off every night, so this would fire every evening.

## Ideas for later (Phase 2)

- Port-scan detection (OpenCanary `portscan` module).
- A new user being added to the `sudo` group (`usermod -aG sudo`), T1098.
- Detections for attacks against a deliberately vulnerable practice app, bound to 127.0.0.1.
