#!/bin/sh
# wan-watchdog.sh — Monitor WAN connectivity and restart if down
# Runs every 1 minute via cron. Exempt from health check gate.

LOGFILE="/tmp/wan-watchdog.log"
FAIL_FILE="/tmp/wan_watchdog_fails"
MAX_FAILS=3
PING_TARGETS="1.1.1.1 8.8.8.8 208.67.222.222"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOGFILE"
}

[ ! -f "$FAIL_FILE" ] && echo 0 > "$FAIL_FILE"

# Try pinging multiple targets
wan_ok=0
for target in $PING_TARGETS; do
    if ping -c 1 -W 3 "$target" >/dev/null 2>&1; then
        wan_ok=1
        break
    fi
done

if [ "$wan_ok" = "1" ]; then
    # WAN is up — reset counter
    echo 0 > "$FAIL_FILE"
else
    # WAN is down
    fails=$(cat "$FAIL_FILE")
    fails=$((fails + 1))
    echo "$fails" > "$FAIL_FILE"
    log "WAN DOWN: ping failed (consecutive=$fails)"

    if [ "$fails" -ge "$MAX_FAILS" ]; then
        log "WAN DOWN for $fails checks. Restarting WAN interface."
        service restart_wan
        echo 0 > "$FAIL_FILE"
        log "WAN restart triggered."
    fi
fi

# Trim log
tail -200 "$LOGFILE" > "${LOGFILE}.tmp" && mv "${LOGFILE}.tmp" "$LOGFILE"
