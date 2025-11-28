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
echo "$TRACK_MIN $TRACK_HOUR * * * /path/to/autoUpdate/autoUpdate.sh --track >> /var/log/autoupdate-track.log 2>&1"
echo "$UPDATE_MIN $UPDATE_HOUR * * * /path/to/autoUpdate/autoUpdate.sh --delayed >> /var/log/autoupdate.log 2>&1"
```

Add the output to root's crontab with `sudo crontab -e`:
```cron
# AutoUpdate - track and delayed update
23 0 * * * /opt/LinuxScripts/autoUpdate/autoUpdate.sh --track >> /var/log/autoupdate-track.log 2>&1
47 3 * * * /opt/LinuxScripts/autoUpdate/autoUpdate.sh --delayed >> /var/log/autoupdate.log 2>&1
```

This ensures:
- Tracking runs daily at a random time between 0:00-1:59 AM
- Updates install daily at a random time between 2:00-4:59 AM
- Only packages that have been available for 3+ days are installed
- Packages on hold (`apt-mark hold`) are skipped
