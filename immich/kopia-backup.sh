#!/bin/sh
# Backs up Immich's irreplaceable data from slartibartfast to the same
# Backblaze B2 Kopia repository the Mac and Pi use. Triggered daily by
# kopia-immich.timer (03:00) — see SETUP.md's Immich section.
#
# Runs as the `mathewcsims` USER, not root, via a systemd --user unit
# (linger is enabled so it fires without an active login). That works
# because Immich's container-written data directories are root-owned but
# world-readable. If Immich ever starts writing mode-600 files, kopia will
# report errors rather than silently skipping them — which is exactly why
# this script inspects kopia's exit status per source and alerts instead of
# reporting a cheerful success.
#
# WHY 03:00: Immich's own database backup runs at 02:00 (Admin ▸ Settings ▸
# Backup) and writes dumps into data/backups/. Snapshotting an hour later
# means every snapshot contains that night's fresh dump. Don't move this
# earlier than Immich's dump without moving Immich's too.
#
# WHAT IS DELIBERATELY NOT BACKED UP:
#   * data/thumbs/ and data/encoded-video/ — regenerable by Immich's own
#     jobs, per upstream's backup guidance. Excluding them saves real B2
#     storage. The trade-off is a slower recovery, since regenerating on
#     this box's Haswell CPU is not fast — accepted deliberately.
#   * pgdata/ — the live Postgres data directory. Upstream is explicit that
#     a file copy of it will not reliably restore; the dump in
#     data/backups/ is the supported path. Backing up both would be worse
#     than useless, because a torn datadir copy LOOKS like a valid backup.
#
# The repository password is NOT needed here: `kopia repository connect`
# persisted it to ~/.config/kopia/repository.config.kopia-password (0600),
# because this headless box has no keyring daemon for kopia to use.
set -eu

KOPIA="$HOME/.local/bin/kopia"
IMMICH_DATA="$HOME/immich/data"
LOG="$HOME/kopia-immich/backup.log"
APPRISE_URL="https://apprise.mathewcsims.uk/notify/self-hosted"

mkdir -p "$(dirname "$LOG")"

log() {
    echo "[$(date -Is)] $1" >> "$LOG"
}

notify_failure() {
    # Best-effort, no retry — same curl-to-Apprise pattern as
    # pi-unattended-upgrades/notify-reboot-required.sh and
    # pi-fail2ban/notify-apprise.sh.
    curl -fsS --max-time 10 \
        --data-urlencode "title=⚠️ Immich backup FAILED on slartibartfast" \
        --data-urlencode "type=failure" \
        --data-urlencode "format=markdown" \
        --data-urlencode "body=$1" \
        "$APPRISE_URL" >/dev/null 2>&1 || true
}

log "=== starting Immich backup ==="

FAILED=""
for sub in library upload profile backups; do
    SRC="$IMMICH_DATA/$sub"
    if [ ! -d "$SRC" ]; then
        log "SKIP $sub — directory does not exist yet"
        continue
    fi
    # --log-level=error keeps the log readable; kopia still exits non-zero
    # and prints on real failures.
    if "$KOPIA" snapshot create "$SRC" --log-level=error >> "$LOG" 2>&1; then
        log "OK   $sub"
    else
        log "FAIL $sub"
        FAILED="$FAILED $sub"
    fi
done

if [ -n "$FAILED" ]; then
    log "=== FAILED for:$FAILED ==="
    notify_failure "Kopia snapshot failed for:$FAILED

Host: slartibartfast
Log: $LOG

Immich's photo library is the least replaceable data in the stack — worth
checking promptly rather than waiting for the next run."
    exit 1
fi

log "=== completed successfully ==="
