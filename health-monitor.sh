#!/bin/sh
# health-monitor.sh — Router health monitor with auto-recovery
# Runs every 2 minutes via cron. Tracks CPU/memory and takes action if stressed.

LOGFILE="/tmp/health-monitor.log"
FAIL_FILE="/tmp/health_monitor_fails"
MEM_FAIL_FILE="/tmp/health_monitor_mem_fails"
PUSHGW="http://192.168.50.100:9092"

# Thresholds
LOAD_CRITICAL=4.0
MEM_LOW_PCT=10
MEM_CRIT_PCT=5

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOGFILE"
}

# Initialize fail counters if missing
[ ! -f "$FAIL_FILE" ] && echo 0 > "$FAIL_FILE"
[ ! -f "$MEM_FAIL_FILE" ] && echo 0 > "$MEM_FAIL_FILE"

# Gather metrics
load=$(awk '{print $1}' /proc/loadavg)
mem_total=$(awk '/^MemTotal/ {print $2}' /proc/meminfo)
mem_available=$(awk '/^MemAvailable/ {print $2}' /proc/meminfo)
if [ -z "$mem_available" ]; then
    mem_free=$(awk '/^MemFree/ {print $2}' /proc/meminfo)
    buffers=$(awk '/^Buffers/ {print $2}' /proc/meminfo)
    cached=$(awk '/^Cached/ {print $2}' /proc/meminfo)
    mem_available=$((mem_free + buffers + cached))
fi
mem_pct=$((mem_available * 100 / mem_total))

health_status=1  # 1=healthy, 0=stressed

# --- CPU Load Check ---
load_critical=$(awk "BEGIN {print ($load > $LOAD_CRITICAL) ? 1 : 0}")
if [ "$load_critical" = "1" ]; then
    cpu_fails=$(cat "$FAIL_FILE")
    cpu_fails=$((cpu_fails + 1))
    echo "$cpu_fails" > "$FAIL_FILE"
    log "WARNING: load=$load exceeds $LOAD_CRITICAL (consecutive=$cpu_fails)"
    health_status=0

    if [ "$cpu_fails" -ge 3 ]; then
        log "ALERT: High CPU for 3+ checks. Killing non-essential cron jobs."
        cru d push_metrics 2>/dev/null
        cru d duckdns_update 2>/dev/null
        cru d wifi_optimize 2>/dev/null
        cru d curfew_check 2>/dev/null
        log "Non-essential cron jobs removed. Manual restart required via services-start."
    fi
else
    echo 0 > "$FAIL_FILE"
fi

# --- Memory Check ---
if [ "$mem_pct" -lt "$MEM_CRIT_PCT" ]; then
    mem_fails=$(cat "$MEM_FAIL_FILE")
    mem_fails=$((mem_fails + 1))
    echo "$mem_fails" > "$MEM_FAIL_FILE"
    log "CRITICAL: memory=${mem_pct}% below ${MEM_CRIT_PCT}% (consecutive=$mem_fails)"
    health_status=0

    # Flush caches first
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    log "Flushed filesystem caches"

    if [ "$mem_fails" -ge 3 ]; then
        log "EMERGENCY: Memory critical for 3+ checks. Rebooting router."
        # Push metric before reboot
        cat <<PEOF | curl -s --connect-timeout 5 --data-binary @- "$PUSHGW/metrics/job/router/instance/gt-ax11000" 2>/dev/null
# HELP router_health_status Router health (1=healthy, 0=stressed)
# TYPE router_health_status gauge
router_health_status 0
PEOF
        reboot
        exit 0
    fi
elif [ "$mem_pct" -lt "$MEM_LOW_PCT" ]; then
    log "WARNING: memory=${mem_pct}% below ${MEM_LOW_PCT}%. Flushing caches."
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    health_status=0
    echo 0 > "$MEM_FAIL_FILE"
else
    echo 0 > "$MEM_FAIL_FILE"
fi

# --- Push health metric to Grafana ---
cat <<PEOF | curl -s --connect-timeout 5 --data-binary @- "$PUSHGW/metrics/job/router/instance/gt-ax11000" 2>/dev/null
# HELP router_health_status Router health (1=healthy, 0=stressed)
# TYPE router_health_status gauge
router_health_status $health_status
# HELP router_health_load Router 1-min load average
# TYPE router_health_load gauge
router_health_load $load
# HELP router_health_mem_pct Router available memory percentage
# TYPE router_health_mem_pct gauge
router_health_mem_pct $mem_pct
PEOF

log "CHECK: load=$load mem=${mem_pct}% status=$health_status"

# Trim log to last 500 lines
tail -500 "$LOGFILE" > "${LOGFILE}.tmp" && mv "${LOGFILE}.tmp" "$LOGFILE"
