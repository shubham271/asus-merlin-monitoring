# ASUS Merlin Monitoring

Shell-based automation suite for Asuswrt-Merlin routers (tested on GT-AX11000). Collects system metrics via Prometheus Pushgateway for Grafana dashboards, plus health monitoring, WAN failover, WiFi optimization, DuckDNS DDNS, and internet curfew enforcement.

## Features

| Script | Description | Schedule |
|--------|-------------|----------|
| `push-metrics.sh` | Collects CPU, memory, temps, WiFi clients, WAN traffic, conntrack and pushes to Pushgateway | Every 1 min |
| `health-monitor.sh` | Monitors system health (CPU, memory, load) with auto-recovery actions | Every 2 min |
| `health-check.sh` | Shared health gate — sourced by other scripts to skip work when router is stressed | Library |
| `wan-watchdog.sh` | Monitors WAN connectivity, restarts interface after sustained failures | Every 3 min |
| `wifi-channel-optimizer.sh` | Scans for interference and switches to optimal WiFi channels | Weekly (Sun 3 AM) |
| `duckdns-update.sh` | Updates DuckDNS only when public IP changes | Every 5 min |
| `duckdns-force.sh` | Forces a DuckDNS update regardless of IP change | Daily (4 AM) |
| `curfew.sh` | Enforces internet curfew schedules per device via iptables | Every 1 min |
| `firewall-start` | Merlin hook — restores curfew iptables chain on reboot | On firewall load |
| `services-start` | Merlin hook — registers all cron jobs on boot | On boot |
| `install.sh` | One-shot installer — deploys all scripts to `/jffs/scripts/` | Manual |

## Architecture

```
┌──────────────┐    SSH + curl    ┌────────────────┐     scrape    ┌──────────┐
│  GT-AX11000  │ ───────────────> │  Pushgateway   │ <──────────── │Prometheus│
│  (router)    │   push-metrics   │  :9091         │               │  :9090   │
└──────────────┘                  └────────────────┘               └───┬──────┘
                                                                       │
                                                                  ┌────▼─────┐
                                                                  │ Grafana  │
                                                                  │  :3000   │
                                                                  └──────────┘
```

## Metrics Collected

- **CPU:** usage %, load averages (1m/5m/15m), temperature
- **Memory:** total, used, free, usage %
- **WiFi:** client count per band (2.4 GHz, 5 GHz-1, 5 GHz-2), radio temperatures
- **Network:** WAN RX/TX bytes, WAN status, connection tracking count
- **System:** uptime, health status

## Quick Start

### Option 1: One-Shot Install

```bash
# From your management server, SCP the install script to the router
scp install.sh admin@192.168.50.1:/tmp/

# SSH into the router and run it
ssh admin@192.168.50.1
sh /tmp/install.sh
```

### Option 2: Manual Deploy

```bash
# Copy all scripts to the router
scp *.sh *.conf firewall-start services-start admin@<ROUTER_IP>:/jffs/scripts/

# SSH in and make executable
ssh admin@<ROUTER_IP>
chmod +x /jffs/scripts/*.sh /jffs/scripts/services-start /jffs/scripts/firewall-start

# Enable custom scripts
nvram set jffs2_scripts=1
nvram commit

# Register cron jobs
/jffs/scripts/services-start

# Verify
cru l
```

## Configuration

### Pushgateway Target

Edit `push-metrics.sh` and `health-monitor.sh` to set your Pushgateway URL:

```bash
PUSHGW="http://<YOUR_SERVER_IP>:9091"
```

### DuckDNS

Edit `duckdns.conf`:

```bash
DUCKDNS_TOKEN="YOUR_TOKEN_HERE"
DUCKDNS_SUBDOMAIN="YOUR_SUBDOMAIN_HERE"
```

### Internet Curfew

Edit `curfew.conf` — one device per line:

```
AA:BB:CC:DD:EE:FF|22|06|all|Kids Tablet
11:22:33:44:55:66|23|07|1,2,3,4,5|Work Laptop
```

Format: `MAC|START_HOUR|END_HOUR|DAYS|LABEL`

### WiFi Optimizer

Dry run first to see what channels it would pick:

```bash
/jffs/scripts/wifi-channel-optimizer.sh --dry-run
```

## Requirements

- Asuswrt-Merlin firmware (tested on 3.0.0.4.388)
- JFFS custom scripts enabled (`nvram set jffs2_scripts=1`)
- Prometheus Pushgateway reachable from router (SSH tunnel or direct)

## Verification

| Feature | Test | Expected |
|---------|------|----------|
| Metrics | `curl http://<PUSHGW>:9091/metrics \| grep router_` | Router metrics present |
| Health | `/jffs/scripts/health-check.sh && echo OK` | Prints OK |
| WAN | `cat /tmp/wan-watchdog.log` | No persistent failures |
| DuckDNS | `/jffs/scripts/duckdns-force.sh && cat /tmp/duckdns.log` | OK |
| WiFi | `/jffs/scripts/wifi-channel-optimizer.sh --dry-run` | Channel analysis |
| Curfew | `/jffs/scripts/curfew.sh status` | Shows config |

## License

MIT
