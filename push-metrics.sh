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
