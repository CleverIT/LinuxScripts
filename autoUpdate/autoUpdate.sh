#!/bin/bash
PATH=/usr/bin:/bin:/usr/sbin:/sbin

# Delayed update system - only installs packages that have been available for X days
# Usage:
#   ./autoUpdate.sh --track         Track new updates (run daily via cron)
#   ./autoUpdate.sh --delayed       Install only aged packages (3+ days old)
#   ./autoUpdate.sh --self-update   Update this repository (git pull --ff-only); also done by --track
#   ./autoUpdate.sh                 Original behavior: install all updates immediately
#
# After an update run the script also checks the kernel and the package state
# (see post_update_checks): a missing kernel metapackage, half-installed
# packages, too little room in /boot, or a server that still runs an older
# kernel than the newest installed one. Optional settings go in autoUpdate.conf
# next to this script (not in git); see autoUpdate.conf.example.
#
# Logging: all output is captured in ../logs/updatelog.log. The previous log is
# rotated to ../logs/updatelog.YYYYMMDD.log on each run (date from its mtime);
# rotated logs older than 30 days are deleted.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRACKING_FILE="${SCRIPT_DIR}/package_tracking.db"
LOG_DIR="${SCRIPT_DIR}/../logs"
LOG_FILE="${LOG_DIR}/updatelog.log"
LOG_RETENTION_DAYS=30
MIN_AGE_DAYS=3
REBOOT_STATE_FILE="${SCRIPT_DIR}/reboot_required_since"
SELF_UPDATE_STATE_FILE="${SCRIPT_DIR}/self_update_status"

# Defaults, override in autoUpdate.conf
AUTO_REBOOT=yes                     # reboot after the nightly --delayed run when a reboot is needed
AUTO_REBOOT_WEEKDAYS="1 2 3 4 5 6 7" # days (date +%u, 1=Monday) on which AUTO_REBOOT may reboot
REBOOT_ALERT_DAYS=8                 # reboot pending this many days -> status mail becomes ERROR
BOOT_MIN_FREE_MB=80                 # less free space on a separate /boot -> ERROR (a kernel needs ~55 MB)
SELF_UPDATE=yes                     # --track first runs git pull --ff-only on this repository

if [[ -f "${SCRIPT_DIR}/autoUpdate.conf" ]]; then
    # shellcheck source=/dev/null
    . "${SCRIPT_DIR}/autoUpdate.conf"
fi

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

rotate_log() {
    mkdir -p "$LOG_DIR"
    if [[ -s "$LOG_FILE" ]]; then
        local mtime stamp
        mtime=$(stat -c %Y "$LOG_FILE" 2>/dev/null)
        if [[ -n "$mtime" ]]; then
            stamp=$(date -d "@$mtime" '+%Y%m%d')
        else
            stamp=$(date '+%Y%m%d')
        fi
        mv "$LOG_FILE" "${LOG_FILE%.log}.${stamp}.log"
    fi
    find "$LOG_DIR" -maxdepth 1 -name 'updatelog.*.log' -type f -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null
}

rotate_log
exec > "$LOG_FILE" 2>&1

log "autoUpdate.sh starting (args: ${*:-<none>})"

# If the INPUT chain is empty, enable the firewall
if ! iptables --list-rules INPUT | grep -q -v -E '^-P'; then
    log "INPUT chain empty - enabling firewall"
    ../firewall/firewall-enable
fi

#Server zonder spaties
servert=$HOSTNAME

err=0
run_mode=""
subject=""
from="autoUpdate-"$servert"@cleverit.nl"

# Function to get list of held packages
get_held_packages() {
    apt-mark showhold 2>/dev/null
}

# Function to get list of upgradable packages with versions
# apt list --upgradable format: "package/repo version arch [upgradable from: old_version]"
# Example: "docker-ce/jammy 5:24.0.7-1~ubuntu amd64 [upgradable from: 5:24.0.6-1~ubuntu]"
get_upgradable_packages() {
    apt-get update >/dev/null 2>&1
    local held_packages=$(get_held_packages)
    apt list --upgradable 2>/dev/null | grep -v "^Listing" | while read -r line; do
        pkg=$(echo "$line" | cut -d'/' -f1)
        # Skip held packages
        if echo "$held_packages" | grep -qx "$pkg"; then
            continue
        fi
        # Remove [upgradable...] part, then get second field (version)
        version=$(echo "$line" | sed 's/\[.*//' | awk '{print $2}')
        if [[ -n "$pkg" && -n "$version" ]]; then
            echo "$pkg $version"
        fi
    done
}

# Function to track new packages
track_packages() {
    log "Tracking package updates"
    local today=$(date +%Y-%m-%d)
    local updated=0
    local new_packages=0

    # Create tracking file if it doesn't exist
    touch "$TRACKING_FILE"

    # Get current upgradable packages
    local current_packages=$(get_upgradable_packages)

    # Create temp file for new tracking data
    local temp_file=$(mktemp)

    # Process each upgradable package
    while read -r pkg version; do
        [[ -z "$pkg" ]] && continue

        # Check if this exact package+version is already tracked
        local existing=$(grep "^${pkg}|${version}|" "$TRACKING_FILE" 2>/dev/null)

        if [[ -n "$existing" ]]; then
            # Keep existing entry
            echo "$existing" >> "$temp_file"
        else
            # New package/version - add with today's date
            echo "${pkg}|${version}|${today}" >> "$temp_file"
            echo "  NEW: $pkg $version (first seen: $today)"
            ((new_packages++))
        fi
        ((updated++))
    done <<< "$current_packages"

    # Replace tracking file (removes old entries for packages no longer upgradable)
    mv "$temp_file" "$TRACKING_FILE"

    log "Tracking complete: $updated packages tracked, $new_packages new"
}

# Function to get packages eligible for delayed update
get_eligible_packages() {
    local today_epoch=$(date +%s)
    local min_age_seconds=$((MIN_AGE_DAYS * 86400))
    local eligible=""

    # Get current upgradable packages
    local current_packages=$(get_upgradable_packages)

    while read -r pkg version; do
        [[ -z "$pkg" ]] && continue

        # Check tracking file for this package
        local tracked=$(grep "^${pkg}|" "$TRACKING_FILE" 2>/dev/null)

        if [[ -z "$tracked" ]]; then
            echo "  SKIP: $pkg $version (not yet tracked, run --track first)" >&2
            continue
        fi

        # Get the tracked version and date
        local tracked_version=$(echo "$tracked" | cut -d'|' -f2)
        local tracked_date=$(echo "$tracked" | cut -d'|' -f3)

        # Check if a newer version exists (superseded)
        if [[ "$tracked_version" != "$version" ]]; then
            echo "  SKIP: $pkg (tracked $tracked_version superseded by $version, waiting for new version to age)" >&2
            continue
        fi

        # Check age
        local tracked_epoch=$(date -d "$tracked_date" +%s 2>/dev/null)
        if [[ -z "$tracked_epoch" ]]; then
            echo "  SKIP: $pkg (invalid date in tracking file)" >&2
            continue
        fi

        local age_seconds=$((today_epoch - tracked_epoch))
        local age_days=$((age_seconds / 86400))

        if [[ $age_seconds -ge $min_age_seconds ]]; then
            echo "  OK: $pkg $version (aged $age_days days)" >&2
            eligible="$eligible $pkg"
        else
            echo "  SKIP: $pkg $version (only $age_days days old, need $MIN_AGE_DAYS)" >&2
        fi
    done <<< "$current_packages"

    echo "$eligible"
}

# Function to perform delayed update
delayed_update() {
    log "Performing delayed update (min age: $MIN_AGE_DAYS days)"

    if [[ ! -f "$TRACKING_FILE" ]]; then
        log "ERROR: No tracking file found. Run with --track first."
        err=1
        return 1
    fi

    log "Running apt-get update"
    apt-get update
    if [[ $? -gt 0 ]]; then
        err=1
    fi

    local eligible=$(get_eligible_packages)
    eligible=$(echo "$eligible" | xargs)  # Trim whitespace

    if [[ -z "$eligible" ]]; then
        log "No packages eligible for update yet."
        return 0
    fi

    log "Installing eligible packages: $eligible"
    apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install $eligible
    if [[ $? -gt 0 ]]; then
        err=1
    fi

    log "Running apt-get autoremove --purge"
    apt-get -y --purge autoremove
    if [[ $? -gt 0 ]]; then
        err=1
    fi

    log "Running apt-get autoclean"
    apt-get autoclean
    if [[ $? -gt 0 ]]; then
        err=1
    fi

    # Re-track to update the tracking file after installation
    track_packages
}

script_version() {
    git -C "$SCRIPT_DIR" log -1 --format='%h (%cd)' --date=short 2>/dev/null || echo "unknown (no git checkout)"
}

# Keep this repository (and so this script) up to date. Runs from --track, a
# few hours before --delayed, so the update run already uses the new version.
# Local files like firewall/firewall-enable and the state files are in
# .gitignore, so a fast-forward pull leaves them alone. The result is written
# to SELF_UPDATE_STATE_FILE and reported in the next status mail.
self_update() {
    if [[ "$SELF_UPDATE" != "yes" ]]; then
        log "Self-update disabled (SELF_UPDATE=$SELF_UPDATE)"
        rm -f "$SELF_UPDATE_STATE_FILE"
        return 0
    fi
    if ! git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        log "Self-update skipped: $SCRIPT_DIR is not a git checkout"
        return 0
    fi
    local before after out
    before=$(script_version)
    if out=$(GIT_TERMINAL_PROMPT=0 timeout 120 git -C "$SCRIPT_DIR" pull --ff-only --quiet 2>&1); then
        after=$(script_version)
        if [[ "$before" != "$after" ]]; then
            log "Self-update: $before -> $after"
        else
            log "Self-update: already up to date, $after"
        fi
        echo "OK $(date +%Y-%m-%d) $after" > "$SELF_UPDATE_STATE_FILE"
    else
        log "ERROR: self-update failed (git pull --ff-only): $out"
        echo "FAILED $(date +%Y-%m-%d) $(echo "$out" | tr '\n' ' ')" > "$SELF_UPDATE_STATE_FILE"
        return 1
    fi
}

# Report the result of the last self-update in the update run.
check_self_update() {
    log "Script version: $(script_version)"
    [[ "$SELF_UPDATE" == "yes" && -f "$SELF_UPDATE_STATE_FILE" ]] || return 0
    local state
    state=$(head -n 1 "$SELF_UPDATE_STATE_FILE")
    if [[ "$state" == FAILED* ]]; then
        log "ERROR: last self-update failed: ${state#FAILED }"
        err=1
    else
        log "Last self-update: ${state#OK }"
    fi
}

# Is there a real kernel on this machine (not a container)?
has_own_kernel() {
    if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt --container --quiet; then
        return 1
    fi
    find /boot -maxdepth 1 -type f -name 'vmlinuz-*' 2>/dev/null | grep -q .
}

# Kernel metapackages (linux-image-amd64, linux-image-cloud-amd64, linux-image-generic,
# linux-generic, ...) pull in each new kernel ABI. Without one, apt never offers a new
# kernel again and the server silently stays on an old one.
installed_kernel_metapackages() {
    dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 2>/dev/null \
        | awk '$1 ~ /^ii/ {print $2}' \
        | grep -E '^linux-image-[a-z]|^linux-(generic|virtual|aws|azure|gcp|kvm|oracle|oem)' \
        | grep -vE '^linux-image-(unsigned-|extra-)|-dbg(sym)?$'
}

newest_installed_kernel() {
    find /boot -maxdepth 1 -type f -name 'vmlinuz-*' -printf '%f\n' 2>/dev/null \
        | sed 's/^vmlinuz-//' | sort -V | tail -n 1
}

# Checks after an update run. Sets err=1 for problems that need a person, and
# reboot_needed=1 when the running kernel (or a library) is older than installed.
reboot_needed=0
reboot_reason=""
post_update_checks() {
    log "Post-update checks"
    check_self_update

    local audit
    audit=$(dpkg --audit 2>&1)
    if [[ -n "$audit" ]]; then
        log "ERROR: dpkg reports half-installed or unconfigured packages:"
        echo "$audit"
        err=1
    fi

    if ! has_own_kernel; then
        log "No kernel in /boot (container?) - skipping kernel checks"
        return 0
    fi

    local metas
    metas=$(installed_kernel_metapackages | xargs)
    if [[ -z "$metas" ]]; then
        log "ERROR: no kernel metapackage installed (e.g. linux-image-amd64): new kernels will never be installed. Fix: apt-get install linux-image-amd64 (or the flavour for this machine)"
        err=1
    else
        log "Kernel metapackage(s): $metas"
    fi

    if mountpoint -q /boot; then
        local free_mb
        free_mb=$(df -Pm /boot | awk 'NR==2 {print $4}')
        if [[ -n "$free_mb" && "$free_mb" -lt "$BOOT_MIN_FREE_MB" ]]; then
            log "ERROR: only ${free_mb} MB free in /boot (minimum ${BOOT_MIN_FREE_MB} MB): the next kernel will not fit. Remove old kernels (apt-get --purge autoremove)"
            err=1
        else
            log "/boot free: ${free_mb} MB"
        fi
    fi

    local running newest
    running=$(uname -r)
    newest=$(newest_installed_kernel)
    if [[ -n "$newest" && "$running" != "$newest" ]]; then
        reboot_needed=1
        reboot_reason="running kernel $running, newest installed $newest"
    elif [[ -f /run/reboot-required ]]; then
        reboot_needed=1
        reboot_reason="/run/reboot-required: $(xargs < /run/reboot-required.pkgs 2>/dev/null)"
    fi

    if [[ $reboot_needed -eq 1 ]]; then
        local today since since_epoch days
        today=$(date +%Y-%m-%d)
        [[ -s "$REBOOT_STATE_FILE" ]] || echo "$today" > "$REBOOT_STATE_FILE"
        since=$(head -n 1 "$REBOOT_STATE_FILE")
        since_epoch=$(date -d "$since" +%s 2>/dev/null || date +%s)
        days=$(( ($(date +%s) - since_epoch) / 86400 ))
        log "Reboot needed since $since ($days days): $reboot_reason"
        if [[ $days -ge $REBOOT_ALERT_DAYS ]]; then
            if [[ "$AUTO_REBOOT" == "yes" ]]; then
                log "ERROR: reboot pending for $days days (limit $REBOOT_ALERT_DAYS) although AUTO_REBOOT is on: check why the reboot does not happen or does not help (boot order, /boot)"
            else
                log "ERROR: reboot pending for $days days (limit $REBOOT_ALERT_DAYS) and AUTO_REBOOT is off: please reboot this server"
            fi
            err=1
        fi
    else
        rm -f "$REBOOT_STATE_FILE"
        log "Running kernel $running is the newest installed"
    fi
}

# Function to perform immediate update (original behavior)
immediate_update() {
    log "Performing immediate update"

    log "Running apt-get update"
    apt-get update
    if [[ $? -gt 0 ]]; then
        err=1
    fi

    log "Running apt-get upgrade"
    apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade
    if [[ $? -gt 0 ]]; then
        err=1
    fi

    log "Running apt-get autoremove --purge"
    apt-get -y --purge autoremove
    if [[ $? -gt 0 ]]; then
        err=1
    fi

    log "Running apt-get autoclean"
    apt-get autoclean
    if [[ $? -gt 0 ]]; then
        err=1
    fi
}

# Main logic based on arguments
case "${1:-}" in
    --track|-t)
        self_update
        log "Running apt-get update (pre-track)"
        apt-get update
        track_packages
        exit 0
        ;;
    --self-update)
        self_update
        exit $?
        ;;
    --delayed|-d)
        run_mode=delayed
        delayed_update
        post_update_checks
        ;;
    --status|-s)
        log "Package tracking status (min age: $MIN_AGE_DAYS days):"
        if [[ -f "$TRACKING_FILE" ]]; then
            apt-get update >/dev/null 2>&1
            get_eligible_packages >/dev/null
        else
            log "No tracking file. Run --track first."
        fi
        post_update_checks
        exit 0
        ;;
    --help|-h)
        echo "Usage: $0 [OPTION]"
        echo "  --track, -t     Track new package updates (run daily)"
        echo "  --delayed, -d   Install only packages aged $MIN_AGE_DAYS+ days"
        echo "  --status, -s    Show status of tracked packages"
        echo "  --self-update   Update this repository now (git pull --ff-only)"
        echo "  --help, -h      Show this help"
        echo "  (no option)     Original behavior: install all updates immediately"
        exit 0
        ;;
    "")
        run_mode=immediate
        immediate_update
        post_update_checks
        ;;
    *)
        log "Unknown option: $1"
        echo "Use --help for usage information"
        exit 1
        ;;
esac

if [[ $err -gt 0 ]]; then
    subject="ERROR - HELP linux autoUpdate voor server: $servert is mislukt!!!"
    echo "HELP ER IS EEN FOUT!!!" > ./email.txt
    echo "Server: $servert" >> ./email.txt
else
    subject="HOERA - Linux autoUpdate voor server: $servert is succesvol!!!"
    echo "HOERA het is GOED!!!" > ./email.txt
    echo "Server: $servert" >> ./email.txt
fi
echo "Script: LinuxScripts $(script_version)" >> ./email.txt

will_reboot=0
if [[ $reboot_needed -eq 1 ]]; then
    # Only the nightly --delayed run reboots; a manual run never reboots by surprise.
    if [[ "$run_mode" == "delayed" && "$AUTO_REBOOT" == "yes" ]] && [[ " $AUTO_REBOOT_WEEKDAYS " == *" $(date +%u) "* ]]; then
        will_reboot=1
        subject="$subject (reboot volgt)"
        echo "Reboot volgt na deze run: $reboot_reason" >> ./email.txt
    else
        subject="$subject (REBOOT NODIG)"
        echo "REBOOT NODIG: $reboot_reason" >> ./email.txt
    fi
fi

cat /etc/*-release >> ./email.txt

cat "$LOG_FILE" >> ./email.txt

# Strip carriage returns from the body. apt/dpkg progress output embeds bare
# CR characters (e.g. "Reading database ... 5%\r10%\r..."), which modern
# sendmail rejects with "421 4.5.0 Bare carriage return (CR) not allowed",
# leaving the message stuck forever in the MSP queue. First drop trailing CRs
# (CRLF -> LF), then collapse in-line progress bars to their final state.
sed -i 's/\r$//; s/.*\r//' ./email.txt

log "Sending status email: subject=\"$subject\" to=backup@cleverit.nl"
mail_output=$(mail -aFrom:"autoUpdate-${servert}@cleverit.nl" -s "$subject" backup@cleverit.nl < ./email.txt 2>&1)
mail_status=$?
if [[ -n "$mail_output" ]]; then
    log "mail output: $mail_output"
fi
if [[ $mail_status -eq 0 ]]; then
    log "mail command exit 0 - message queued to local MTA"
else
    log "mail command exit $mail_status - message NOT queued"
fi

if [[ $will_reboot -eq 1 ]]; then
    log "AUTO_REBOOT: rebooting in 2 minutes ($reboot_reason)"
    shutdown -r +2 "autoUpdate: reboot for updates ($reboot_reason)"
fi
