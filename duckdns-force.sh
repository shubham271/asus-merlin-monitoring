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
