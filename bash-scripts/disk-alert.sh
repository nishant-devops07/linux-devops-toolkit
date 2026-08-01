#!/usr/bin/env bash
#
# disk-alert.sh
# Monitors disk usage per mounted filesystem and sends an alert
# (email and/or webhook) when usage crosses warning/critical thresholds.
# Designed to be run from cron.
#
# Usage:
#   ./disk-alert.sh                # run a check now
#   ./disk-alert.sh --list         # show current usage for all filesystems, no alerting
#
# Configure via the variables below, or override with environment
# variables, e.g.:
#   WARN_THRESHOLD=75 CRIT_THRESHOLD=90 EMAIL_TO=ops@example.com ./disk-alert.sh
#
# Example cron entry (every 15 minutes):
#   */15 * * * * /path/to/disk-alert.sh >> /var/log/disk-alert-cron.log 2>&1
#
set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration (override via env vars if desired)
# ---------------------------------------------------------------------------
WARN_THRESHOLD="${WARN_THRESHOLD:-75}"    # percent used -> warning
CRIT_THRESHOLD="${CRIT_THRESHOLD:-90}"    # percent used -> critical

# Filesystems to exclude from checks (mount points, space-separated)
EXCLUDE_MOUNTS="${EXCLUDE_MOUNTS:-/boot/efi /snap}"

# Filesystem types to skip (virtual/pseudo filesystems)
EXCLUDE_TYPES="tmpfs devtmpfs squashfs overlay"

LOG_FILE="${LOG_FILE:-/var/log/disk-alert.log}"
if ! touch "$LOG_FILE" 2>/dev/null; then
    LOG_FILE="./disk-alert.log"
fi

# State file so we only alert once per breach, not every cron run
STATE_FILE="${STATE_FILE:-/var/tmp/disk-alert.state}"
if ! touch "$STATE_FILE" 2>/dev/null; then
    STATE_FILE="./disk-alert.state"
fi

# Email alerting (requires `mail` / `mailx` on the system). Leave empty to skip.
EMAIL_TO="${EMAIL_TO:-}"
EMAIL_SUBJECT_PREFIX="${EMAIL_SUBJECT_PREFIX:-[Disk Alert]}"

# Webhook alerting (e.g. Slack incoming webhook). Leave empty to skip.
WEBHOOK_URL="${WEBHOOK_URL:-}"

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

HOSTNAME_TAG="$(hostname -s 2>/dev/null || hostname)"
ALERTS_FIRED=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOG_FILE"
}

is_excluded_mount() {
    local mount="$1"
    for ex in $EXCLUDE_MOUNTS; do
        [ "$mount" = "$ex" ] && return 0
    done
    return 1
}

# Track last-known state per mount ("ok", "warn", "crit") to avoid alert spam.
get_last_state() {
    local mount="$1"
    grep -F "|${mount}|" "$STATE_FILE" 2>/dev/null | tail -n1 | cut -d'|' -f3
}

set_last_state() {
    local mount="$1" state="$2"
    local tmp
    tmp="$(mktemp)"
    grep -vF "|${mount}|" "$STATE_FILE" 2>/dev/null > "$tmp" || true
    echo "$(date '+%s')|${mount}|${state}" >> "$tmp"
    mv "$tmp" "$STATE_FILE"
}

send_email() {
    local subject="$1" body="$2"
    [ -z "$EMAIL_TO" ] && return
    if command -v mail >/dev/null 2>&1; then
        echo "$body" | mail -s "$subject" "$EMAIL_TO"
        log "Email alert sent to $EMAIL_TO: $subject"
    else
        log "WARN: EMAIL_TO is set but 'mail' command not found; skipping email alert."
    fi
}

send_webhook() {
    local text="$1"
    [ -z "$WEBHOOK_URL" ] && return
    if command -v curl >/dev/null 2>&1; then
        curl -sS -X POST -H 'Content-Type: application/json' \
            -d "{\"text\": \"${text}\"}" "$WEBHOOK_URL" >/dev/null 2>>"$LOG_FILE"
        log "Webhook alert sent."
    else
        log "WARN: WEBHOOK_URL is set but 'curl' not found; skipping webhook alert."
    fi
}

alert() {
    local level="$1" mount="$2" pct="$3" avail="$4"
    local subject="${EMAIL_SUBJECT_PREFIX} ${level^^} - ${HOSTNAME_TAG} ${mount} at ${pct}%"
    local body="Host: ${HOSTNAME_TAG}
Mount: ${mount}
Usage: ${pct}%
Available: ${avail}
Level: ${level^^}
Time: $(date '+%Y-%m-%d %H:%M:%S')"

    log "ALERT [$level] $mount at ${pct}% (available: $avail)"
    send_email "$subject" "$body"
    send_webhook "*${level^^}*: ${HOSTNAME_TAG} ${mount} is at ${pct}% (available: ${avail})"
    ALERTS_FIRED=$((ALERTS_FIRED + 1))
}

recovery_notice() {
    local mount="$1" pct="$2"
    log "RECOVERED $mount back to ${pct}% (below warning threshold)"
    send_email "${EMAIL_SUBJECT_PREFIX} RECOVERED - ${HOSTNAME_TAG} ${mount}" \
        "Host: ${HOSTNAME_TAG}
Mount: ${mount}
Usage: ${pct}%
Status: back under ${WARN_THRESHOLD}% threshold
Time: $(date '+%Y-%m-%d %H:%M:%S')"
    send_webhook "*RECOVERED*: ${HOSTNAME_TAG} ${mount} back to ${pct}%"
}

# ---------------------------------------------------------------------------
# Core check
# ---------------------------------------------------------------------------
build_exclude_args() {
    local args=()
    for t in $EXCLUDE_TYPES; do
        args+=(-x "$t")
    done
    printf '%s\n' "${args[@]}"
}

run_check() {
    log "----- Disk check run -----"
    local exclude_args=()
    while IFS= read -r line; do exclude_args+=("$line"); done < <(build_exclude_args)

    while read -r fs size used avail pct mount; do
        pct="${pct%%%}"
        is_excluded_mount "$mount" && continue

        local state="ok"
        if [ "$pct" -ge "$CRIT_THRESHOLD" ]; then
            state="crit"
        elif [ "$pct" -ge "$WARN_THRESHOLD" ]; then
            state="warn"
        fi

        local last_state
        last_state="$(get_last_state "$mount")"

        case "$state" in
            crit)
                printf "  %-20s ${RED}%3s%%  [CRITICAL]${NC}\n" "$mount" "$pct"
                if [ "$last_state" != "crit" ]; then
                    alert "critical" "$mount" "$pct" "$avail"
                fi
                ;;
            warn)
                printf "  %-20s ${YELLOW}%3s%%  [WARNING]${NC}\n" "$mount" "$pct"
                if [ "$last_state" != "warn" ] && [ "$last_state" != "crit" ]; then
                    alert "warning" "$mount" "$pct" "$avail"
                fi
                ;;
            ok)
                printf "  %-20s ${GREEN}%3s%%  [OK]${NC}\n" "$mount" "$pct"
                if [ "$last_state" = "warn" ] || [ "$last_state" = "crit" ]; then
                    recovery_notice "$mount" "$pct"
                fi
                ;;
        esac

        set_last_state "$mount" "$state"
    done < <(df -hP "${exclude_args[@]}" | tail -n +2)

    if [ "$ALERTS_FIRED" -gt 0 ]; then
        printf "${RED}%s new alert(s) fired. See log: %s${NC}\n" "$ALERTS_FIRED" "$LOG_FILE"
    else
        printf "${GREEN}No new alerts.${NC}\n"
    fi
}

list_usage() {
    echo "Current disk usage:"
    local exclude_args=()
    while IFS= read -r line; do exclude_args+=("$line"); done < <(build_exclude_args)
    df -hP "${exclude_args[@]}"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
case "${1:-}" in
    --list)
        list_usage
        ;;
    "")
        echo "=============================================="
        echo " Disk Alert Check - ${HOSTNAME_TAG} - $(date '+%Y-%m-%d %H:%M:%S')"
        echo "=============================================="
        run_check
        ;;
    *)
        echo "Usage: $0 [--list]"
        exit 1
        ;;
esac
