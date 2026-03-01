#!/bin/sh
# curfew.sh — Internet curfew enforcement via iptables
# Subcommands: check, status, flush, block MAC, unblock MAC

# Health check gate (except for status/flush which should always work)
case "$1" in
    status|flush) ;;
    *) . /jffs/scripts/health-check.sh ;;
esac

CONF="/jffs/scripts/curfew.conf"
LOGFILE="/tmp/curfew.log"
CHAIN="CURFEW"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOGFILE"
}

# Ensure CURFEW chain exists
ensure_chain() {
    iptables -N "$CHAIN" 2>/dev/null
    # Ensure chain is referenced from FORWARD
    iptables -C FORWARD -j "$CHAIN" 2>/dev/null || iptables -I FORWARD -j "$CHAIN"
}

# Block a specific MAC
do_block() {
    local mac="$1"
    local label="$2"
    # Check if already blocked
    if iptables -C "$CHAIN" -m mac --mac-source "$mac" -j DROP 2>/dev/null; then
        return 0  # Already blocked
    fi
    iptables -A "$CHAIN" -m mac --mac-source "$mac" -j DROP
    log "BLOCKED: $mac ($label)"
}

# Unblock a specific MAC
do_unblock() {
    local mac="$1"
    local label="$2"
    # Remove all matching rules
    while iptables -D "$CHAIN" -m mac --mac-source "$mac" -j DROP 2>/dev/null; do
        :
    done
    log "UNBLOCKED: $mac ($label)"
}

# Check if current time falls within curfew window
is_curfew_active() {
    local start="$1"
    local end="$2"
    local days="$3"
    local current_hour current_day

    current_hour=$(date +%H | sed 's/^0//')
    current_day=$(date +%w)  # 0=Sunday

    # Check day of week
    if [ "$days" != "all" ]; then
        echo "$days" | grep -q "$current_day" || return 1
    fi

    # Handle overnight curfew (e.g., 22-06)
    if [ "$start" -gt "$end" ]; then
        # Overnight: active if hour >= start OR hour < end
        [ "$current_hour" -ge "$start" ] || [ "$current_hour" -lt "$end" ]
    else
        # Same-day: active if hour >= start AND hour < end
        [ "$current_hour" -ge "$start" ] && [ "$current_hour" -lt "$end" ]
    fi
}

# Process all entries in config
do_check() {
    [ ! -f "$CONF" ] && return
    ensure_chain

    while IFS='|' read -r mac start end days label; do
        # Skip comments and empty lines
        case "$mac" in
            \#*|"") continue ;;
        esac

        if is_curfew_active "$start" "$end" "$days"; then
            do_block "$mac" "$label"
        else
            do_unblock "$mac" "$label"
        fi
    done < "$CONF"
}

# Show current curfew status
do_status() {
    ensure_chain
    echo "=== Curfew Chain Rules ==="
    iptables -L "$CHAIN" -v --line-numbers 2>/dev/null
    echo ""
    echo "=== Config Entries ==="
    if [ -f "$CONF" ]; then
        grep -v '^#' "$CONF" | grep -v '^$' | while IFS='|' read -r mac start end days label; do
            if is_curfew_active "$start" "$end" "$days"; then
                state="ACTIVE (blocked)"
            else
                state="inactive"
            fi
            echo "  $label ($mac): ${start}:00-${end}:00 days=$days [$state]"
        done
    else
        echo "  No config file found at $CONF"
    fi
}

# Flush all curfew rules
do_flush() {
    iptables -F "$CHAIN" 2>/dev/null
    log "FLUSHED: All curfew rules removed"
    echo "All curfew rules flushed."
}

# Main command dispatch
case "$1" in
    check)
        do_check
        ;;
    status)
        do_status
        ;;
    flush)
        do_flush
        ;;
    block)
        [ -z "$2" ] && echo "Usage: $0 block MAC [label]" && exit 1
        ensure_chain
        do_block "$2" "${3:-manual}"
        ;;
    unblock)
        [ -z "$2" ] && echo "Usage: $0 unblock MAC [label]" && exit 1
        ensure_chain
        do_unblock "$2" "${3:-manual}"
        ;;
    *)
        echo "Usage: $0 {check|status|flush|block MAC|unblock MAC}"
        exit 1
        ;;
esac

# Trim log
[ -f "$LOGFILE" ] && { tail -500 "$LOGFILE" > "${LOGFILE}.tmp" && mv "${LOGFILE}.tmp" "$LOGFILE"; }
