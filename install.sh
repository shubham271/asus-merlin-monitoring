#!/bin/sh
# install.sh — Deploy all router scripts to /jffs/scripts/
# Run this on the router to install everything in one shot.

set -e

DEST="/jffs/scripts"

echo "=== Installing router scripts to $DEST ==="
mkdir -p "$DEST"

# --- curfew.conf ---
echo "Writing curfew.conf..."
cat > "$DEST/curfew.conf" << 'SCRIPTEOF'
# Internet Curfew Configuration
# Format: MAC|START_HOUR|END_HOUR|DAYS|LABEL
# START_HOUR/END_HOUR: 0-23 (24h format). Block FROM start TO end.
# DAYS: comma-separated (0=Sun,1=Mon,...,6=Sat) or "all"
#
# Examples:
# AA:BB:CC:DD:EE:FF|22|06|all|Kids Tablet
# 11:22:33:44:55:66|23|07|1,2,3,4,5|Work Laptop (weeknights)
#
# Add your devices below:
SCRIPTEOF

# --- curfew.sh ---
echo "Writing curfew.sh..."
cat > "$DEST/curfew.sh" << 'SCRIPTEOF'
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
SCRIPTEOF

# --- duckdns.conf ---
echo "Writing duckdns.conf..."
cat > "$DEST/duckdns.conf" << 'SCRIPTEOF'
# DuckDNS Configuration
# Get your token from https://www.duckdns.org after logging in
# Create a subdomain there, then fill in these values

DUCKDNS_TOKEN="YOUR_TOKEN_HERE"
DUCKDNS_SUBDOMAIN="YOUR_SUBDOMAIN_HERE"
SCRIPTEOF

# --- duckdns-force.sh ---
echo "Writing duckdns-force.sh..."
cat > "$DEST/duckdns-force.sh" << 'SCRIPTEOF'
#!/bin/sh
# duckdns-force.sh — Force DuckDNS update (daily keep-alive)
# Runs daily at 4 AM via cron

# Health check gate
. /jffs/scripts/health-check.sh

CONF="/jffs/scripts/duckdns.conf"
LOGFILE="/tmp/duckdns.log"
IP_CACHE="/tmp/duckdns_last_ip"

# Load config
if [ ! -f "$CONF" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: Config file $CONF not found" >> "$LOGFILE"
    exit 1
fi
. "$CONF"

if [ "$DUCKDNS_TOKEN" = "YOUR_TOKEN_HERE" ] || [ "$DUCKDNS_SUBDOMAIN" = "YOUR_SUBDOMAIN_HERE" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: DuckDNS not configured. Edit $CONF" >> "$LOGFILE"
    exit 1
fi

# Get current public IP
current_ip=$(curl -s --connect-timeout 10 --max-time 15 "https://api.ipify.org" 2>/dev/null)
if [ -z "$current_ip" ]; then
    current_ip=$(curl -s --connect-timeout 10 --max-time 15 "https://ifconfig.me" 2>/dev/null)
fi

# Force update regardless of IP change
result=$(curl -s --connect-timeout 10 --max-time 15 \
    "https://www.duckdns.org/update?domains=${DUCKDNS_SUBDOMAIN}&token=${DUCKDNS_TOKEN}&ip=${current_ip}" 2>/dev/null)

if [ "$result" = "OK" ]; then
    [ -n "$current_ip" ] && echo "$current_ip" > "$IP_CACHE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') FORCE update: ip=$current_ip result=OK" >> "$LOGFILE"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') FORCE update FAILED: ip=$current_ip result=$result" >> "$LOGFILE"
fi

# Trim log
tail -200 "$LOGFILE" > "${LOGFILE}.tmp" && mv "${LOGFILE}.tmp" "$LOGFILE"
SCRIPTEOF

# --- duckdns-update.sh ---
echo "Writing duckdns-update.sh..."
cat > "$DEST/duckdns-update.sh" << 'SCRIPTEOF'
#!/bin/sh
# duckdns-update.sh — Update DuckDNS only if public IP has changed
# Runs every 5 minutes via cron

# Health check gate
. /jffs/scripts/health-check.sh

CONF="/jffs/scripts/duckdns.conf"
LOGFILE="/tmp/duckdns.log"
IP_CACHE="/tmp/duckdns_last_ip"

# Load config
if [ ! -f "$CONF" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: Config file $CONF not found" >> "$LOGFILE"
    exit 1
fi
. "$CONF"

if [ "$DUCKDNS_TOKEN" = "YOUR_TOKEN_HERE" ] || [ "$DUCKDNS_SUBDOMAIN" = "YOUR_SUBDOMAIN_HERE" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: DuckDNS not configured. Edit $CONF" >> "$LOGFILE"
    exit 1
fi

# Get current public IP
current_ip=$(curl -s --connect-timeout 10 --max-time 15 "https://api.ipify.org" 2>/dev/null)
if [ -z "$current_ip" ]; then
    current_ip=$(curl -s --connect-timeout 10 --max-time 15 "https://ifconfig.me" 2>/dev/null)
fi

if [ -z "$current_ip" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: Could not determine public IP" >> "$LOGFILE"
    exit 1
fi

# Check if IP has changed
last_ip=""
[ -f "$IP_CACHE" ] && last_ip=$(cat "$IP_CACHE")

if [ "$current_ip" = "$last_ip" ]; then
    # IP unchanged, skip update
    exit 0
fi

# IP changed — update DuckDNS
result=$(curl -s --connect-timeout 10 --max-time 15 \
    "https://www.duckdns.org/update?domains=${DUCKDNS_SUBDOMAIN}&token=${DUCKDNS_TOKEN}&ip=${current_ip}" 2>/dev/null)

if [ "$result" = "OK" ]; then
    echo "$current_ip" > "$IP_CACHE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') Updated: $last_ip -> $current_ip" >> "$LOGFILE"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') FAILED: result=$result ip=$current_ip" >> "$LOGFILE"
fi

# Trim log
tail -200 "$LOGFILE" > "${LOGFILE}.tmp" && mv "${LOGFILE}.tmp" "$LOGFILE"
SCRIPTEOF

# --- firewall-start ---
echo "Writing firewall-start..."
cat > "$DEST/firewall-start" << 'SCRIPTEOF'
#!/bin/sh
# firewall-start — Called by Asuswrt-Merlin after firewall rules are loaded
# Ensures the CURFEW iptables chain exists after reboot

CHAIN="CURFEW"

# Create chain if it doesn't exist
iptables -N "$CHAIN" 2>/dev/null

# Insert jump to CURFEW chain in FORWARD if not already present
iptables -C FORWARD -j "$CHAIN" 2>/dev/null || iptables -I FORWARD -j "$CHAIN"

# Run an immediate curfew check
/jffs/scripts/curfew.sh check
SCRIPTEOF

# --- health-check.sh ---
echo "Writing health-check.sh..."
cat > "$DEST/health-check.sh" << 'SCRIPTEOF'
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
SCRIPTEOF

# --- health-monitor.sh ---
echo "Writing health-monitor.sh..."
cat > "$DEST/health-monitor.sh" << 'SCRIPTEOF'
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
SCRIPTEOF

# --- push-metrics.sh ---
echo "Writing push-metrics.sh..."
cat > "$DEST/push-metrics.sh" << 'SCRIPTEOF'
#!/bin/sh
# push-metrics.sh — Collect router metrics and push to Prometheus Pushgateway
# Runs every 1 minute via cron

# Health check gate (skip if router is stressed)
. /jffs/scripts/health-check.sh

PUSHGW="http://192.168.50.100:9092"
JOB="router"
INSTANCE="gt-ax11000"

# --- CPU Usage ---
# Read /proc/stat twice with 1s interval for accurate calculation
cpu1=$(awk '/^cpu / {print $2+$3+$4+$5+$6+$7+$8, $5}' /proc/stat)
sleep 1
cpu2=$(awk '/^cpu / {print $2+$3+$4+$5+$6+$7+$8, $5}' /proc/stat)

total1=$(echo "$cpu1" | awk '{print $1}')
idle1=$(echo "$cpu1" | awk '{print $2}')
total2=$(echo "$cpu2" | awk '{print $1}')
idle2=$(echo "$cpu2" | awk '{print $2}')

cpu_pct=$(awk "BEGIN {
    dt = $total2 - $total1;
    di = $idle2 - $idle1;
    if (dt > 0) printf \"%.1f\", (1 - di/dt) * 100;
    else print 0;
}")

# --- Memory ---
mem_total=$(awk '/^MemTotal/ {print $2}' /proc/meminfo)
mem_available=$(awk '/^MemAvailable/ {print $2}' /proc/meminfo)
if [ -z "$mem_available" ]; then
    mem_free=$(awk '/^MemFree/ {print $2}' /proc/meminfo)
    buffers=$(awk '/^Buffers/ {print $2}' /proc/meminfo)
    cached=$(awk '/^Cached/ {print $2}' /proc/meminfo)
    mem_available=$((mem_free + buffers + cached))
fi
mem_used=$((mem_total - mem_available))
mem_pct=$(awk "BEGIN {printf \"%.1f\", $mem_used / $mem_total * 100}")

# --- Load Average ---
read load1 load5 load15 _ _ < /proc/loadavg

# --- Uptime (seconds) ---
uptime_sec=$(awk '{print int($1)}' /proc/uptime)

# --- Temperatures ---
cpu_temp=""
wifi0_temp=""
wifi1_temp=""
wifi2_temp=""

# Try thermal zones first
for tz in /sys/class/thermal/thermal_zone*/temp; do
    [ -f "$tz" ] || continue
    val=$(cat "$tz" 2>/dev/null)
    if [ -z "$cpu_temp" ] && [ -n "$val" ]; then
        cpu_temp=$(awk "BEGIN {printf \"%.1f\", $val / 1000}")
    fi
done

# Try wl command for WiFi radio temperatures
if command -v wl >/dev/null 2>&1; then
    wifi0_temp=$(wl -i eth6 phy_tempsense 2>/dev/null | awk '{print $1}')
    wifi1_temp=$(wl -i eth7 phy_tempsense 2>/dev/null | awk '{print $1}')
    wifi2_temp=$(wl -i eth8 phy_tempsense 2>/dev/null | awk '{print $1}')
fi

# Fallback if empty
[ -z "$cpu_temp" ] && cpu_temp=0
[ -z "$wifi0_temp" ] && wifi0_temp=0
[ -z "$wifi1_temp" ] && wifi1_temp=0
[ -z "$wifi2_temp" ] && wifi2_temp=0

# --- Connected Clients ---
clients_24ghz=0
clients_5ghz=0
clients_5ghz2=0

if command -v wl >/dev/null 2>&1; then
    clients_24ghz=$(wl -i eth6 assoclist 2>/dev/null | grep -c "assoclist")
    clients_5ghz=$(wl -i eth7 assoclist 2>/dev/null | grep -c "assoclist")
    clients_5ghz2=$(wl -i eth8 assoclist 2>/dev/null | grep -c "assoclist")
fi
clients_total=$((clients_24ghz + clients_5ghz + clients_5ghz2))

# --- WAN Status ---
wan_iface="eth0"
wan_up=0
wan_rx=0
wan_tx=0

if [ -d "/sys/class/net/${wan_iface}" ]; then
    operstate=$(cat "/sys/class/net/${wan_iface}/operstate" 2>/dev/null)
    [ "$operstate" = "up" ] && wan_up=1
    wan_rx=$(cat "/sys/class/net/${wan_iface}/statistics/rx_bytes" 2>/dev/null || echo 0)
    wan_tx=$(cat "/sys/class/net/${wan_iface}/statistics/tx_bytes" 2>/dev/null || echo 0)
fi

# --- Push all metrics ---
cat <<PEOF | curl -s --connect-timeout 5 --max-time 10 --data-binary @- "$PUSHGW/metrics/job/$JOB/instance/$INSTANCE" 2>/dev/null
# HELP router_cpu_usage_percent Router CPU usage percentage
# TYPE router_cpu_usage_percent gauge
router_cpu_usage_percent $cpu_pct
# HELP router_memory_total_kb Router total memory in KB
# TYPE router_memory_total_kb gauge
router_memory_total_kb $mem_total
# HELP router_memory_used_kb Router used memory in KB
# TYPE router_memory_used_kb gauge
router_memory_used_kb $mem_used
# HELP router_memory_usage_percent Router memory usage percentage
# TYPE router_memory_usage_percent gauge
router_memory_usage_percent $mem_pct
# HELP router_load_1m Router 1-minute load average
# TYPE router_load_1m gauge
router_load_1m $load1
# HELP router_load_5m Router 5-minute load average
# TYPE router_load_5m gauge
router_load_5m $load5
# HELP router_load_15m Router 15-minute load average
# TYPE router_load_15m gauge
router_load_15m $load15
# HELP router_uptime_seconds Router uptime in seconds
# TYPE router_uptime_seconds gauge
router_uptime_seconds $uptime_sec
# HELP router_cpu_temp_celsius Router CPU temperature in Celsius
# TYPE router_cpu_temp_celsius gauge
router_cpu_temp_celsius $cpu_temp
# HELP router_wifi_temp_24ghz WiFi 2.4GHz radio temperature
# TYPE router_wifi_temp_24ghz gauge
router_wifi_temp_24ghz $wifi0_temp
# HELP router_wifi_temp_5ghz WiFi 5GHz-1 radio temperature
# TYPE router_wifi_temp_5ghz gauge
router_wifi_temp_5ghz $wifi1_temp
# HELP router_wifi_temp_5ghz2 WiFi 5GHz-2 radio temperature
# TYPE router_wifi_temp_5ghz2 gauge
router_wifi_temp_5ghz2 $wifi2_temp
# HELP router_clients_total Total connected WiFi clients
# TYPE router_clients_total gauge
router_clients_total $clients_total
# HELP router_clients_24ghz Connected clients on 2.4GHz
# TYPE router_clients_24ghz gauge
router_clients_24ghz $clients_24ghz
# HELP router_clients_5ghz Connected clients on 5GHz-1
# TYPE router_clients_5ghz gauge
router_clients_5ghz $clients_5ghz
# HELP router_clients_5ghz2 Connected clients on 5GHz-2
# TYPE router_clients_5ghz2 gauge
router_clients_5ghz2 $clients_5ghz2
# HELP router_wan_up WAN interface status (1=up, 0=down)
# TYPE router_wan_up gauge
router_wan_up $wan_up
# HELP router_wan_rx_bytes WAN received bytes total
# TYPE router_wan_rx_bytes counter
router_wan_rx_bytes $wan_rx
# HELP router_wan_tx_bytes WAN transmitted bytes total
# TYPE router_wan_tx_bytes counter
router_wan_tx_bytes $wan_tx
PEOF
SCRIPTEOF

# --- services-start ---
echo "Writing services-start..."
cat > "$DEST/services-start" << 'SCRIPTEOF'
#!/bin/sh
# services-start — Called by Asuswrt-Merlin after all services have started
# Sets up all cron jobs for router automation

# WAN watchdog — always runs (exempt from health gate)
cru a wan-watchdog "* * * * * /jffs/scripts/wan-watchdog.sh"

# Health monitor — checks router health every 2 minutes
cru a health_monitor "*/2 * * * * /jffs/scripts/health-monitor.sh"

# Push router metrics to Grafana every minute
cru a push_metrics "*/1 * * * * /jffs/scripts/push-metrics.sh"

# DuckDNS — check IP every 5 minutes, force update daily at 4 AM
cru a duckdns_update "*/5 * * * * /jffs/scripts/duckdns-update.sh"
cru a duckdns_force "0 4 * * * /jffs/scripts/duckdns-force.sh"

# WiFi channel optimizer — weekly Sunday 3 AM
cru a wifi_optimize "0 3 * * 0 /jffs/scripts/wifi-channel-optimizer.sh"

# Internet curfew — check every 5 minutes
cru a curfew_check "*/5 * * * * /jffs/scripts/curfew.sh check"
SCRIPTEOF

# --- wan-watchdog.sh ---
echo "Writing wan-watchdog.sh..."
cat > "$DEST/wan-watchdog.sh" << 'SCRIPTEOF'
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
SCRIPTEOF

# --- wifi-channel-optimizer.sh ---
echo "Writing wifi-channel-optimizer.sh..."
cat > "$DEST/wifi-channel-optimizer.sh" << 'SCRIPTEOF'
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
SCRIPTEOF

# --- Set permissions ---
echo ""
echo "=== Setting permissions ==="
chmod +x "$DEST/curfew.sh"
chmod +x "$DEST/duckdns-force.sh"
chmod +x "$DEST/duckdns-update.sh"
chmod +x "$DEST/firewall-start"
chmod +x "$DEST/health-check.sh"
chmod +x "$DEST/health-monitor.sh"
chmod +x "$DEST/push-metrics.sh"
chmod +x "$DEST/services-start"
chmod +x "$DEST/wan-watchdog.sh"
chmod +x "$DEST/wifi-channel-optimizer.sh"
echo "All .sh files, services-start, and firewall-start set to executable."

# --- List installed files ---
echo ""
echo "=== Installed files ==="
ls -la "$DEST/"

# --- Run services-start to register cron jobs ---
echo ""
echo "=== Running services-start ==="
"$DEST/services-start"

# --- Verify cron jobs ---
echo ""
echo "=== Cron jobs (cru l) ==="
cru l

echo ""
echo "=== Installation complete ==="
