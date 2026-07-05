#!/bin/sh
# Run daily by uk.mathewcsims.kopia-mac-backup (LaunchAgent) via launchd's
# StartCalendarInterval — see kopia-mac/uk.mathewcsims.kopia-mac-backup.plist.
#
# Kopia itself needs no secrets here: `kopia repository connect` (done once,
# interactively, when this was set up) persists locally, so subsequent
# `kopia snapshot create` calls just work. The only credential this script
# touches is the NAS mount, and that comes from the macOS Keychain (added
# once via Finder > Cmd+K > "remember password") — mount_smbfs never sees a
# password on its command line, here or anywhere else.
set -eu

REPO_ROOT="/Users/mathewcsims/self-hosted"
# A custom path under the home directory, not /Volumes/AppleBackups: macOS
# only lets privileged processes (Finder's own mount helper, effectively)
# create new directories directly under /Volumes — a plain `mkdir` there
# gets "Permission denied", confirmed directly while testing this script.
# A path under $HOME has no such restriction.
NAS_MOUNT="/Users/mathewcsims/nas-mounts/AppleBackups"
LOG="$REPO_ROOT/kopia-mac/backup.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"
}

log "=== backup run starting ==="

mkdir -p "$NAS_MOUNT"
if ! mount | grep -q "$NAS_MOUNT"; then
    if mount_smbfs "//kopla-user@eddie.nas/AppleBackups" "$NAS_MOUNT" >> "$LOG" 2>&1; then
        log "NAS mounted"
        MOUNTED_NAS=1
    else
        log "NAS mount FAILED — continuing with local sources only"
        MOUNTED_NAS=0
    fi
else
    log "NAS already mounted"
    MOUNTED_NAS=0
fi

SOURCES="
$REPO_ROOT/karakeep/data
$REPO_ROOT/karakeep/meilisearch-data
$REPO_ROOT/vikunja/db
$REPO_ROOT/vikunja/files
$REPO_ROOT/blog/db
$REPO_ROOT/blog/content
$REPO_ROOT/blog/traffic-analytics-data
$REPO_ROOT/memos-prospect-ukri-tus/data
$REPO_ROOT/copyparty/data
$REPO_ROOT/copyparty/public
$REPO_ROOT/copyparty/inbox
$REPO_ROOT/copyparty/cfg/accounts.conf
"
if [ -d "$NAS_MOUNT" ] && mount | grep -q "$NAS_MOUNT"; then
    SOURCES="$SOURCES
$NAS_MOUNT"
fi

for source in $SOURCES; do
    log "snapshotting $source"
    kopia snapshot create "$source" >> "$LOG" 2>&1 || log "FAILED: $source"
done

if [ "${MOUNTED_NAS:-0}" = "1" ]; then
    umount "$NAS_MOUNT" >> "$LOG" 2>&1 || log "unmount failed (non-fatal)"
    log "NAS unmounted"
fi

log "=== backup run finished ==="
