#!/bin/bash
PATH=/usr/bin:/bin:/usr/sbin:/sbin

# Delayed update system - only installs packages that have been available for X days
# Usage:
#   ./autoUpdate.sh --track         Track new updates (run daily via cron)
#   ./autoUpdate.sh --delayed       Install only aged packages (3+ days old)
#   ./autoUpdate.sh --gitlab-critical  Install GitLab now, but only if GitLab reports a
#                                   critical vulnerability for the installed version
#   ./autoUpdate.sh                 Original behavior: install all updates immediately
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
GITLAB_VERSION_FILE=/opt/gitlab/embedded/service/gitlab-rails/VERSION
GITLAB_CHECK_URL="https://version.gitlab.com/check.json"
GITLAB_CHECK_LOG="${LOG_DIR}/gitlab-critical.log"
GITLAB_FAILS_FILE="${SCRIPT_DIR}/gitlab_check_fails"
GITLAB_MIN_FREE_GB=5
critical_reason=""

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

# GitLab critical security releases
# GitLab's version check (the same source as the "critical security release" banner
# for admins) says whether the installed version has a critical vulnerability. If it
# does and a newer gitlab-ee/gitlab-ce is in apt, that package is installed right
# away: on weekly servers via --gitlab-critical, on daily servers past the delay.
gitlab_package() {
    dpkg-query -W -f='${Package} ${db:Status-Status}\n' gitlab-ee gitlab-ce 2>/dev/null | awk '$2=="installed"{print $1; exit}'
}

# Prints the GitLab package to install now, or nothing. Logs to stderr.
# Exit 2 when the version check could not be reached.
gitlab_critical_package() {
    local pkg version info answer
    pkg=$(gitlab_package)
    [[ -z "$pkg" || ! -f "$GITLAB_VERSION_FILE" ]] && return 0
    version=$(cat "$GITLAB_VERSION_FILE")
    info=$(printf '{"version":"%s"}' "$version" | base64 -w0)
    if ! answer=$(curl -fsS -m 30 -A "LinuxScripts-autoUpdate" "${GITLAB_CHECK_URL}?gitlab_info=${info}" 2>&1); then
        echo "  GitLab version check failed: $answer" >&2
        return 2
    fi
    if ! echo "$answer" | grep -q '"critical_vulnerability":true'; then
        echo "  GitLab $version: no critical vulnerability" >&2
        return 0
    fi
    if apt-mark showhold 2>/dev/null | grep -qx "$pkg"; then
        echo "  GitLab $version: CRITICAL, but $pkg is on hold" >&2
        return 0
    fi
    if ! apt list --upgradable 2>/dev/null | grep -q "^${pkg}/"; then
        echo "  GitLab $version: CRITICAL, but no newer $pkg in apt yet" >&2
        return 0
    fi
    echo "  GitLab $version: CRITICAL, installing $pkg now ($answer)" >&2
    echo "$pkg"
}

# GitLab makes a backup before it upgrades; make sure that fits.
gitlab_disk_ok() {
    local free_gb
    free_gb=$(df --output=avail -BG /var/opt/gitlab 2>/dev/null | tail -1 | tr -dc 0-9)
    if [[ -n "$free_gb" && "$free_gb" -lt "$GITLAB_MIN_FREE_GB" ]]; then
        log "ERROR: only ${free_gb} GB free on /var/opt/gitlab (need ${GITLAB_MIN_FREE_GB}), GitLab not updated"
        return 1
    fi
    return 0
}

# --gitlab-critical: check quietly (own log, no mail) and only carry on to the
# normal logging and mail when there is something to install or to report.
if [[ "${1:-}" == "--gitlab-critical" ]]; then
    mkdir -p "$LOG_DIR"
    {
        log "GitLab critical check"
        apt-get update >/dev/null 2>&1
        gitlab_pkg=$(gitlab_critical_package)
        check_status=$?
    } >> "$GITLAB_CHECK_LOG" 2>&1
    if [[ $check_status -eq 2 ]]; then
        fails=$(( $(cat "$GITLAB_FAILS_FILE" 2>/dev/null || echo 0) + 1 ))
        echo "$fails" > "$GITLAB_FAILS_FILE"
        # report once, on the third night in a row
        [[ $fails -ne 3 ]] && exit 0
        gitlab_check_broken=1
    else
        rm -f "$GITLAB_FAILS_FILE"
        [[ -z "$gitlab_pkg" ]] && exit 0
    fi
fi

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

    # A critical GitLab release does not wait for the delay
    local gitlab_pkg=$(gitlab_critical_package)
    if [[ -n "$gitlab_pkg" ]] && ! echo " $eligible " | grep -q " $gitlab_pkg "; then
        if gitlab_disk_ok; then
            eligible=$(echo "$eligible $gitlab_pkg" | xargs)
            critical_reason="kritieke GitLab-update"
        else
            err=1
        fi
    fi

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

# Install only the GitLab package (checked before the log rotation above)
gitlab_critical_update() {
    if [[ -n "${gitlab_check_broken:-}" ]]; then
        log "ERROR: GitLab version check failed 3 nights in a row, see $GITLAB_CHECK_LOG"
        err=1
        return 1
    fi
    log "Critical GitLab release: installing $gitlab_pkg"
    critical_reason="kritieke GitLab-update"
    gitlab_disk_ok || { err=1; return 1; }
    apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install "$gitlab_pkg"
    if [[ $? -gt 0 ]]; then
        err=1
    fi
    log "Installed: $(cat "$GITLAB_VERSION_FILE" 2>/dev/null)"
}

# Main logic based on arguments
case "${1:-}" in
    --gitlab-critical)
        gitlab_critical_update
        ;;
    --track|-t)
        log "Running apt-get update (pre-track)"
        apt-get update
        track_packages
        exit 0
        ;;
    --delayed|-d)
        delayed_update
        ;;
    --status|-s)
        log "Package tracking status (min age: $MIN_AGE_DAYS days):"
        if [[ -f "$TRACKING_FILE" ]]; then
            apt-get update >/dev/null 2>&1
            get_eligible_packages >/dev/null
        else
            log "No tracking file. Run --track first."
        fi
        exit 0
        ;;
    --help|-h)
        echo "Usage: $0 [OPTION]"
        echo "  --track, -t     Track new package updates (run daily)"
        echo "  --delayed, -d   Install only packages aged $MIN_AGE_DAYS+ days"
        echo "  --status, -s    Show status of tracked packages"
        echo "  --gitlab-critical  Install GitLab now if it reports a critical vulnerability"
        echo "                  (for servers on a weekly schedule; quiet when nothing to do)"
        echo "  --help, -h      Show this help"
        echo "  (no option)     Original behavior: install all updates immediately"
        exit 0
        ;;
    "")
        immediate_update
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

if [[ -n "$critical_reason" ]]; then
    subject="$subject ($critical_reason)"
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
