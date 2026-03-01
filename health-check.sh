#!/bin/sh
# health-check.sh — Shared health gate for router scripts
# Source this at the top of any script: . /jffs/scripts/health-check.sh
# If the router is stressed, the calling script will exit early.

HEALTH_LOG="/tmp/health-check.log"
MAX_LOAD="3.0"
MIN_MEM_PCT=15

check_health() {
    # Get 1-minute load average
    load=$(awk '{print $1}' /proc/loadavg)

    # Get memory info
    mem_total=$(awk '/^MemTotal/ {print $2}' /proc/meminfo)
    mem_available=$(awk '/^MemAvailable/ {print $2}' /proc/meminfo)

    # Fallback if MemAvailable not present (older kernels)
    if [ -z "$mem_available" ]; then
        mem_free=$(awk '/^MemFree/ {print $2}' /proc/meminfo)
        buffers=$(awk '/^Buffers/ {print $2}' /proc/meminfo)
        cached=$(awk '/^Cached/ {print $2}' /proc/meminfo)
        mem_available=$((mem_free + buffers + cached))
    fi

    mem_pct=$((mem_available * 100 / mem_total))

    # Check load — use awk for float comparison
    load_high=$(awk "BEGIN {print ($load > $MAX_LOAD) ? 1 : 0}")
    if [ "$load_high" = "1" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') SKIP $(basename "$0"): load=$load exceeds $MAX_LOAD" >> "$HEALTH_LOG"
        exit 0
    fi

    # Check memory
    if [ "$mem_pct" -lt "$MIN_MEM_PCT" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') SKIP $(basename "$0"): mem=${mem_pct}% below ${MIN_MEM_PCT}%" >> "$HEALTH_LOG"
        exit 0
    fi
}

check_health
