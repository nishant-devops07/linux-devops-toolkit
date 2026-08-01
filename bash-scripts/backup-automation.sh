#!/usr/bin/env bash
#
# backup-automation.sh
# Automated backup script: archives source directories into timestamped,
# compressed tarballs, rotates old backups, optionally syncs to a remote
# host, and logs everything.
#
# Usage:
#   ./backup-automation.sh                # run a backup now
#   ./backup-automation.sh --restore FILE DEST   # extract a backup archive to DEST
#   ./backup-automation.sh --list         # list existing backups
#
# Configure via the variables below, or override with environment
# variables, e.g.:
#   BACKUP_SOURCES="/etc /home/user/data" RETENTION_DAYS=14 ./backup-automation.sh
#
set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration (override via env vars if desired)
# ---------------------------------------------------------------------------
# Space-separated list of paths to back up
BACKUP_SOURCES="${BACKUP_SOURCES:-/etc /home}"

# Where backups are stored locally
BACKUP_DEST="${BACKUP_DEST:-/var/backups/automated}"

# How many days of backups to keep locally
RETENTION_DAYS="${RETENTION_DAYS:-7}"

# Patterns to exclude (space-separated, tar --exclude style)
EXCLUDES="${EXCLUDES:-*.tmp *.log node_modules .cache}"

# Optional: rsync backups to a remote host after creation.
# Leave REMOTE_HOST empty to skip remote sync.
REMOTE_HOST="${REMOTE_HOST:-}"          # e.g. user@backup-server.example.com
REMOTE_PATH="${REMOTE_PATH:-}"          # e.g. /srv/backups/myhost
SSH_KEY="${SSH_KEY:-}"                  # e.g. /home/user/.ssh/id_backup

LOG_FILE="${LOG_FILE:-/var/log/backup-automation.log}"
if ! touch "$LOG_FILE" 2>/dev/null; then
    LOG_FILE="./backup-automation.log"
fi

TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
HOSTNAME_TAG="$(hostname -s 2>/dev/null || hostname)"
ARCHIVE_NAME="backup-${HOSTNAME_TAG}-${TIMESTAMP}.tar.gz"
ARCHIVE_PATH="${BACKUP_DEST}/${ARCHIVE_NAME}"
CHECKSUM_PATH="${ARCHIVE_PATH}.sha256"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG_FILE"
}

die() {
    printf "${RED}ERROR: %s${NC}\n" "$1" | tee -a "$LOG_FILE" >&2
    exit 1
}

check_sources() {
    local missing=0
    for src in $BACKUP_SOURCES; do
        if [ ! -e "$src" ]; then
            log "WARN: source path does not exist, skipping: $src"
            missing=1
        fi
    done
    [ "$missing" -eq 1 ] && log "Continuing with remaining valid sources."
}

# ---------------------------------------------------------------------------
# Core actions
# ---------------------------------------------------------------------------
run_backup() {
    mkdir -p "$BACKUP_DEST" || die "Could not create backup destination: $BACKUP_DEST"
    check_sources

    log "----- Starting backup: $ARCHIVE_NAME -----"

    # Build tar exclude args
    local exclude_args=()
    for pattern in $EXCLUDES; do
        exclude_args+=(--exclude="$pattern")
    done

    # Only back up sources that actually exist
    local valid_sources=()
    for src in $BACKUP_SOURCES; do
        [ -e "$src" ] && valid_sources+=("$src")
    done

    if [ ${#valid_sources[@]} -eq 0 ]; then
        die "No valid backup sources found. Nothing to do."
    fi

    if tar -czpf "$ARCHIVE_PATH" "${exclude_args[@]}" "${valid_sources[@]}" 2>>"$LOG_FILE"; then
        local size
        size=$(du -h "$ARCHIVE_PATH" | cut -f1)
        log "Archive created: $ARCHIVE_PATH ($size)"
    else
        die "tar failed while creating $ARCHIVE_PATH — see $LOG_FILE for details"
    fi

    # Checksum for integrity verification
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$ARCHIVE_PATH" > "$CHECKSUM_PATH"
        log "Checksum written: $CHECKSUM_PATH"
    fi

    rotate_backups
    sync_remote

    log "----- Backup complete -----"
    printf "${GREEN}Backup complete: %s${NC}\n" "$ARCHIVE_PATH"
}

rotate_backups() {
    log "Rotating backups older than ${RETENTION_DAYS} days in $BACKUP_DEST"
    find "$BACKUP_DEST" -maxdepth 1 -name 'backup-*.tar.gz' -mtime "+${RETENTION_DAYS}" -print -delete >> "$LOG_FILE" 2>&1
    find "$BACKUP_DEST" -maxdepth 1 -name 'backup-*.tar.gz.sha256' -mtime "+${RETENTION_DAYS}" -print -delete >> "$LOG_FILE" 2>&1
}

sync_remote() {
    [ -z "$REMOTE_HOST" ] && return
    [ -z "$REMOTE_PATH" ] && { log "REMOTE_HOST set but REMOTE_PATH is empty, skipping remote sync."; return; }

    if ! command -v rsync >/dev/null 2>&1; then
        log "WARN: rsync not found, skipping remote sync."
        return
    fi

    local ssh_opts=()
    [ -n "$SSH_KEY" ] && ssh_opts=(-e "ssh -i $SSH_KEY")

    log "Syncing $ARCHIVE_PATH to ${REMOTE_HOST}:${REMOTE_PATH}"
    if rsync -az "${ssh_opts[@]}" "$ARCHIVE_PATH" "$CHECKSUM_PATH" "${REMOTE_HOST}:${REMOTE_PATH}/" >> "$LOG_FILE" 2>&1; then
        log "Remote sync succeeded."
    else
        log "WARN: remote sync failed — see $LOG_FILE for details."
    fi
}

list_backups() {
    echo "Backups in $BACKUP_DEST:"
    ls -lh "$BACKUP_DEST"/backup-*.tar.gz 2>/dev/null || echo "  (none found)"
}

restore_backup() {
    local archive="$1"
    local dest="$2"

    [ -f "$archive" ] || die "Archive not found: $archive"
    [ -z "$dest" ] && die "Restore destination required: --restore FILE DEST"

    mkdir -p "$dest" || die "Could not create restore destination: $dest"

    if [ -f "${archive}.sha256" ] && command -v sha256sum >/dev/null 2>&1; then
        log "Verifying checksum for $archive"
        (cd "$(dirname "$archive")" && sha256sum -c "$(basename "${archive}.sha256")") \
            || die "Checksum verification failed for $archive"
    fi

    log "Restoring $archive to $dest"
    tar -xzpf "$archive" -C "$dest" || die "Extraction failed for $archive"
    printf "${GREEN}Restore complete: %s -> %s${NC}\n" "$archive" "$dest"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
case "${1:-}" in
    --list)
        list_backups
        ;;
    --restore)
        restore_backup "${2:-}" "${3:-}"
        ;;
    "")
        run_backup
        ;;
    *)
        echo "Usage: $0 [--list] [--restore FILE DEST]"
        exit 1
        ;;
esac
