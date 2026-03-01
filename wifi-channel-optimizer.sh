#!/bin/sh
# wifi-channel-optimizer.sh — Scan and switch to least congested WiFi channels
# Runs weekly Sunday 3 AM via cron. Supports --dry-run and --band filter.

# Health check gate
. /jffs/scripts/health-check.sh

LOGFILE="/tmp/wifi-optimizer.log"
DRY_RUN=0
BAND_FILTER=""

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --band) BAND_FILTER="$2"; shift ;;
        *) echo "Usage: $0 [--dry-run] [--band 2.4|5|5-2]"; exit 1 ;;
    esac
    shift
done

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOGFILE"
    [ "$DRY_RUN" = "1" ] && echo "$1"
}

# Interface mapping for GT-AX11000
# eth6 = 2.4GHz, eth7 = 5GHz-1, eth8 = 5GHz-2 (tri-band)
IFACE_24="eth6"
IFACE_5="eth7"
IFACE_52="eth8"

# Preferred channels per band
CHANNELS_24="1 6 11"
CHANNELS_5="36 40 44 48 149 153 157 161 165"
CHANNELS_52="36 40 44 48 149 153 157 161 165"

count_aps_on_channel() {
    local iface="$1"
    local channel="$2"
    wl -i "$iface" scanresults 2>/dev/null | awk -v ch="$channel" '
        /^Channel:/ { if ($2 == ch) count++ }
        END { print count+0 }
    '
}

find_best_channel() {
    local iface="$1"
    local channels="$2"
    local band_name="$3"

    log "Scanning $band_name on $iface..."

    # Trigger scan
    wl -i "$iface" scan 2>/dev/null
    sleep 5  # Wait for scan to complete

    best_ch=""
    best_count=9999

    for ch in $channels; do
        count=$(count_aps_on_channel "$iface" "$ch")
        log "  Channel $ch: $count APs detected"

        if [ "$count" -lt "$best_count" ]; then
            best_count=$count
            best_ch=$ch
        fi
    done

    # Get current channel
    current_ch=$(wl -i "$iface" channel 2>/dev/null | awk '{print $NF}')

    log "Best channel for $band_name: $best_ch ($best_count APs) — current: $current_ch"

    if [ "$best_ch" = "$current_ch" ]; then
        log "Already on best channel for $band_name. No change needed."
        return
    fi

    if [ "$DRY_RUN" = "1" ]; then
        log "[DRY-RUN] Would switch $band_name from channel $current_ch to $best_ch"
    else
        log "Switching $band_name from channel $current_ch to $best_ch"
        wl -i "$iface" channel "$best_ch" 2>/dev/null
        if [ $? -eq 0 ]; then
            log "SUCCESS: $band_name now on channel $best_ch"
        else
            log "ERROR: Failed to switch $band_name to channel $best_ch"
        fi
    fi
}

log "=== WiFi Channel Optimization Start (dry_run=$DRY_RUN, band_filter=$BAND_FILTER) ==="

if ! command -v wl >/dev/null 2>&1; then
    log "ERROR: 'wl' command not found. Are you running this on the router?"
    exit 1
fi

# Optimize per band
if [ -z "$BAND_FILTER" ] || [ "$BAND_FILTER" = "2.4" ]; then
    find_best_channel "$IFACE_24" "$CHANNELS_24" "2.4GHz"
fi

if [ -z "$BAND_FILTER" ] || [ "$BAND_FILTER" = "5" ]; then
    find_best_channel "$IFACE_5" "$CHANNELS_5" "5GHz-1"
fi

if [ -z "$BAND_FILTER" ] || [ "$BAND_FILTER" = "5-2" ]; then
    find_best_channel "$IFACE_52" "$CHANNELS_52" "5GHz-2"
fi

log "=== WiFi Channel Optimization Complete ==="

# Trim log
tail -500 "$LOGFILE" > "${LOGFILE}.tmp" && mv "${LOGFILE}.tmp" "$LOGFILE"
