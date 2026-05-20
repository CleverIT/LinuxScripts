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

### Deployment via the basic-debian Ansible playbook

On Clever Debian machines this script is rolled out by the `basic-debian` playbook. The relevant pieces:

- `mailutils` is installed as a prerequisite so the script can send its status mail.
- The repository is cloned to `/root/LinuxScripts` with `ansible.builtin.git` (`update: false` so local edits to `firewall-enable` and similar are preserved).
- Two cron jobs are created per host with `ansible.builtin.cron`, using `{{ 60 | random }}` / `{{ 2 | random }}` / `{{ 5 | random(start=2) }}` so each server picks its own random minute and hour:
  - `autoUpdate-track`: `cd /root/LinuxScripts/autoUpdate && ./autoUpdate.sh --track` between 0:00–1:59
  - `autoUpdate-delayed`: `cd /root/LinuxScripts/autoUpdate && ./autoUpdate.sh --delayed` between 2:00–4:59
- A legacy `autoUpdate` cron entry is removed with `state: absent`.
