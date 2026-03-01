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
