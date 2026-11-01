# LinuxScripts
Some scripts to easily configure your Debian server

firewall:
	Easy scripts for configuring IP tables

vmware:
	Scripts for VMware (hotadd, resize disk)

autoUpdate:
	Automatic package updates with optional delay (only install packages 3+ days old)

## autoUpdate Configuration

The autoUpdate script supports delayed updates to avoid installing packages immediately after release.

### Usage

```bash
./autoUpdate.sh --track      # Track new updates (records first-seen date)
./autoUpdate.sh --delayed    # Install only packages aged 3+ days
./autoUpdate.sh --status     # Show status of tracked packages
./autoUpdate.sh              # Original behavior: install all updates immediately
```

### Crontab Setup

To spread load and avoid all servers updating at the same time, use random hours and minutes.

Generate random cron lines for this server:
```bash
TRACK_MIN=$((RANDOM % 60))
TRACK_HOUR=$((RANDOM % 2))        # 0-1 AM
UPDATE_MIN=$((RANDOM % 60))
UPDATE_HOUR=$((2 + RANDOM % 3))   # 2-4 AM

echo "# AutoUpdate - track and delayed update"
echo "$TRACK_MIN $TRACK_HOUR * * * cd /opt/LinuxScripts/autoUpdate && ./autoUpdate.sh --track"
echo "$UPDATE_MIN $UPDATE_HOUR * * * cd /opt/LinuxScripts/autoUpdate && ./autoUpdate.sh --delayed"
```

Add the output to root's crontab with `sudo crontab -e`:
```cron
# AutoUpdate - track and delayed update
23 0 * * * cd /opt/LinuxScripts/autoUpdate && ./autoUpdate.sh --track
47 3 * * * cd /opt/LinuxScripts/autoUpdate && ./autoUpdate.sh --delayed
```

The script handles its own logging to `../logs/updatelog.log` (rotated to `updatelog.YYYYMMDD.log`, 30 day retention), so no shell redirect is needed in the cron line.

This ensures:
- Tracking runs daily at a random time between 0:00-1:59 AM
- Updates install daily at a random time between 2:00-4:59 AM
- Only packages that have been available for 3+ days are installed
- Packages on hold (`apt-mark hold`) are skipped

### Kernel and reboot checks

After every `--delayed` or immediate run (and with `--status`) the script checks:

- **Kernel metapackage** (`linux-image-amd64`, `linux-image-cloud-amd64`, `linux-image-generic`, ...): without one,
  apt never offers a new kernel again and the server silently stays on an old kernel. Missing = ERROR mail.
- **Half-installed packages** (`dpkg --audit`): ERROR mail.
- **Free space in a separate `/boot`**: below `BOOT_MIN_FREE_MB` (80 MB; a Debian kernel needs ~55 MB) = ERROR mail.
- **Pending reboot**: the running kernel (`uname -r`) is older than the newest `/boot/vmlinuz-*`, or
  `/run/reboot-required` exists. This is nightly maintenance, so by default (`AUTO_REBOOT=yes`) the server reboots
  2 minutes after the `--delayed` run, after the status mail is sent; the subject says `(reboot volgt)`. A manual
  run (`--status`, no option) never reboots. Limit the nights with `AUTO_REBOOT_WEEKDAYS`, or switch it off with
  `AUTO_REBOOT=no` (subject `(REBOOT NODIG)`). A reboot still pending after `REBOOT_ALERT_DAYS` (8) days makes the
  mail ERROR.

Containers (no own kernel) skip the kernel checks. Settings: copy `autoUpdate.conf.example` to `autoUpdate.conf`
(not in git) and change what you need, e.g. `AUTO_REBOOT=no` or `AUTO_REBOOT_WEEKDAYS="7"` on a server that may
only reboot in the night to Sunday.

### Self-update

`--track` starts with `git pull --ff-only` on the repository, so the `--delayed` run a few hours later already uses
the newest script. Local files (`firewall/firewall-enable`, `autoUpdate.conf`, tracking and state files) are in
`.gitignore` and stay as they are. A failed pull (local changes, no network) makes the next status mail ERROR; every
status mail shows the script version. Run it by hand with `./autoUpdate.sh --self-update`, or switch it off with
`SELF_UPDATE=no` in `autoUpdate.conf`.

### Deployment via the basic-debian Ansible playbook

On Clever Debian machines this script is rolled out by the `basic-debian` playbook. The relevant pieces:

- `mailutils` is installed as a prerequisite so the script can send its status mail.
- The repository is cloned to `/root/LinuxScripts` with `ansible.builtin.git` (`update: false`; the script keeps itself up to date, see Self-update).
- Two cron jobs are created per host with `ansible.builtin.cron`, using `{{ 60 | random }}` / `{{ 2 | random }}` / `{{ 5 | random(start=2) }}` so each server picks its own random minute and hour:
  - `autoUpdate-track`: `cd /root/LinuxScripts/autoUpdate && ./autoUpdate.sh --track` between 0:00–1:59
  - `autoUpdate-delayed`: `cd /root/LinuxScripts/autoUpdate && ./autoUpdate.sh --delayed` between 2:00–4:59
- A legacy `autoUpdate` cron entry is removed with `state: absent`.
