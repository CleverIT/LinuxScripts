#!/bin/bash
PATH=/usr/bin:/bin:/usr/sbin:/sbin

# Delayed update system - only installs packages that have been available for X days
# Usage:
#   ./autoUpdate.sh --track         Track new updates (run daily via cron)
#   ./autoUpdate.sh --delayed       Install only aged packages (3+ days old)
#   ./autoUpdate.sh                 Original behavior: install all updates immediately

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRACKING_FILE="${SCRIPT_DIR}/package_tracking.db"
MIN_AGE_DAYS=3

# If the INPUT chain is empty, enable the firewall
if ! iptables --list-rules INPUT | grep -q -v -E '^-P'; then
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
    echo "Tracking package updates..."
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

    echo "Tracking complete: $updated packages tracked, $new_packages new"
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
    echo "Performing delayed update (min age: $MIN_AGE_DAYS days)..."

    if [[ ! -f "$TRACKING_FILE" ]]; then
        echo "ERROR: No tracking file found. Run with --track first."
        return 1
    fi

    apt-get update
    if [[ $? -gt 0 ]]; then
        err=1
    fi

    local eligible=$(get_eligible_packages)
    eligible=$(echo "$eligible" | xargs)  # Trim whitespace

    if [[ -z "$eligible" ]]; then
        echo "No packages eligible for update yet."
        return 0
    fi

    echo "Installing eligible packages: $eligible"
    apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install $eligible
    if [[ $? -gt 0 ]]; then
        err=1
    fi

    apt-get autoclean
    if [[ $? -gt 0 ]]; then
        err=1
    fi

    # Re-track to update the tracking file after installation
    track_packages
}

# Function to perform immediate update (original behavior)
immediate_update() {
    apt-get update
    if [[ $? -gt 0 ]]; then
        err=1
    fi

    apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade
    if [[ $? -gt 0 ]]; then
        err=1
    fi

    apt-get autoclean
    if [[ $? -gt 0 ]]; then
        err=1
    fi
}

# Main logic based on arguments
case "${1:-}" in
    --track|-t)
        apt-get update
        track_packages
        exit 0
        ;;
    --delayed|-d)
        delayed_update
        ;;
    --status|-s)
        echo "Package tracking status (min age: $MIN_AGE_DAYS days):"
        if [[ -f "$TRACKING_FILE" ]]; then
            apt-get update >/dev/null 2>&1
            get_eligible_packages >/dev/null
        else
            echo "No tracking file. Run --track first."
        fi
        exit 0
        ;;
    --help|-h)
        echo "Usage: $0 [OPTION]"
        echo "  --track, -t     Track new package updates (run daily)"
        echo "  --delayed, -d   Install only packages aged $MIN_AGE_DAYS+ days"
        echo "  --status, -s    Show status of tracked packages"
        echo "  --help, -h      Show this help"
        echo "  (no option)     Original behavior: install all updates immediately"
        exit 0
        ;;
    "")
        immediate_update
        ;;
    *)
        echo "Unknown option: $1"
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

cat /etc/*-release >> ./email.txt

cat ./updatelog.log >> ./email.txt
cat ./email.txt | mail -aFrom:"autoUpdate-"$servert"@cleverit.nl" -s "$subject" backup@cleverit.nl
