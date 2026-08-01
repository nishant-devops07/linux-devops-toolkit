#!/usr/bin/env bash
#
# server-health-monitor.sh
# Simple server health monitor: CPU, memory, disk, load average, and
# optional service/port checks. Logs results and warns on threshold breach.
#
# Usage:
#   ./server-health-monitor.sh                 # run once, print + log
#   ./server-health-monitor.sh --watch 60       # run every 60s (Ctrl+C to stop)
#
# Configure thresholds and services below, or override via environment
# variables, e.g.:
#   CPU_THRESHOLD=90 MEM_THRESHOLD=85 ./server-health-monitor.sh
#
set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration (override via env vars if desired)
# ---------------------------------------------------------------------------
CPU_THRESHOLD="${CPU_THRESHOLD:-85}"      # percent
MEM_THRESHOLD="${MEM_THRESHOLD:-85}"      # percent
DISK_THRESHOLD="${DISK_THRESHOLD:-85}"    # percent
LOAD_THRESHOLD="${LOAD_THRESHOLD:-4.0}"   # 1-minute load average

LOG_FILE="${LOG_FILE:-/var/log/server-health-monitor.log}"
# Fallback to a local log if we can't write to /var/log (e.g. no sudo)
if ! touch "$LOG_FILE" 2>/dev/null; then
    LOG_FILE="./server-health-monitor.log"
fi

# Services to check (systemd unit names). Leave empty to skip.
SERVICES=("sshd" "cron")

# TCP ports to check locally (host:port). Leave empty to skip.
PORTS=("localhost:22")

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

WARN_COUNT=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() {
    local msg="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $msg" >> "$LOG_FILE"
}

status_line() {
    # status_line "label" value threshold unit
    local label="$1" value="$2" threshold="$3" unit="$4"
    local color="$GREEN" tag="OK"

    if awk -v v="$value" -v t="$threshold" 'BEGIN{exit !(v >= t)}'; then
        color="$RED"
        tag="WARN"
        WARN_COUNT=$((WARN_COUNT + 1))
    fi

    printf "  %-22s ${color}%6s%s  [%s]${NC}\n" "$label" "$value" "$unit" "$tag"
    log "$label: ${value}${unit} (threshold ${threshold}${unit}) [$tag]"
}

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------
check_cpu() {
    # % CPU currently in use, derived from /proc/stat delta over 1s
    local a b idle1 idle2 total1 total2 diff_idle diff_total cpu_pct
    read -r _ a b c d prev_idle e f g h i j <<< "$(grep '^cpu ' /proc/stat)"
    total1=$((a+b+c+d+prev_idle+e+f+g+h+i+j))
    idle1=$prev_idle
    sleep 1
    read -r _ a b c d idle2raw e f g h i j <<< "$(grep '^cpu ' /proc/stat)"
    total2=$((a+b+c+d+idle2raw+e+f+g+h+i+j))
    idle2=$idle2raw

    diff_idle=$((idle2 - idle1))
    diff_total=$((total2 - total1))
    if [ "$diff_total" -le 0 ]; then
        cpu_pct=0
    else
        cpu_pct=$(awk -v di="$diff_idle" -v dt="$diff_total" 'BEGIN{printf "%.1f", (1 - di/dt) * 100}')
    fi
    status_line "CPU usage" "$cpu_pct" "$CPU_THRESHOLD" "%"
}

check_memory() {
    local mem_pct
    mem_pct=$(free | awk '/^Mem:/ {printf "%.1f", ($2-$7)/$2 * 100}')
    status_line "Memory usage" "$mem_pct" "$MEM_THRESHOLD" "%"
}

check_disk() {
    # Check every real mounted filesystem
    while read -r fs size used avail pct mount; do
        pct="${pct%%%}"
        status_line "Disk ($mount)" "$pct" "$DISK_THRESHOLD" "%"
    done < <(df -hP -x tmpfs -x devtmpfs -x squashfs | tail -n +2)
}

check_load() {
    local load1
    load1=$(awk '{print $1}' /proc/loadavg)
    status_line "Load average (1m)" "$load1" "$LOAD_THRESHOLD" ""
}

check_services() {
    [ ${#SERVICES[@]} -eq 0 ] && return
    echo "  --- Services ---"
    for svc in "${SERVICES[@]}"; do
        if ! command -v systemctl >/dev/null 2>&1; then
            echo "  (systemctl not available, skipping service checks)"
            break
        fi
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            printf "  %-22s ${GREEN}%s${NC}\n" "$svc" "running"
            log "Service $svc: running [OK]"
        else
            printf "  %-22s ${RED}%s${NC}\n" "$svc" "not running"
            log "Service $svc: not running [WARN]"
            WARN_COUNT=$((WARN_COUNT + 1))
        fi
    done
}

check_ports() {
    [ ${#PORTS[@]} -eq 0 ] && return
    echo "  --- Ports ---"
    for hp in "${PORTS[@]}"; do
        host="${hp%%:*}"
        port="${hp##*:}"
        if (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null; then
            exec 3<&- 3>&-
            printf "  %-22s ${GREEN}%s${NC}\n" "$hp" "open"
            log "Port $hp: open [OK]"
        else
            printf "  %-22s ${RED}%s${NC}\n" "$hp" "closed/unreachable"
            log "Port $hp: closed/unreachable [WARN]"
            WARN_COUNT=$((WARN_COUNT + 1))
        fi
    done
}

run_checks() {
    echo "=============================================="
    echo " Server Health Report - $(hostname) - $(date '+%Y-%m-%d %H:%M:%S')"
    echo "=============================================="
    log "----- Health check run -----"

    check_cpu
    check_memory
    check_disk
    check_load
    check_services
    check_ports

    echo "------------------------------------------------"
    if [ "$WARN_COUNT" -gt 0 ]; then
        printf "${RED}%s issue(s) need attention. See log: %s${NC}\n" "$WARN_COUNT" "$LOG_FILE"
    else
        printf "${GREEN}All checks passed.${NC}\n"
    fi
    echo
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--watch" ]; then
    interval="${2:-60}"
    echo "Watching every ${interval}s. Press Ctrl+C to stop."
    while true; do
        WARN_COUNT=0
        run_checks
        sleep "$interval"
    done
else
    run_checks
fi
