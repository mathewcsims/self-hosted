#!/bin/sh
# Mirrors the B2 bucket to the external drive AUTOMATICALLY, whenever that
# drive is plugged in. Triggered by uk.mathewcsims.kopia-mirror, a launchd
# agent watching /Volumes — see that plist.
#
# ── WHY THIS EXISTS ───────────────────────────────────────────────────────
# The Mac's data has two copies: Kopia to Backblaze B2, and Time Machine to
# the NAS. The Pi's and slartibartfast's data has only ONE — Kopia to B2 —
# because nothing else on those hosts writes anywhere else. The offline
# mirror (scripts/mirror-backup-to-external-drive.sh) is what makes it two,
# and it was manual, deliberately, because the drive is not always
# connected.
#
# Manual turned out to mean "not done": when this was written the mirror on
# the drive was from 2026-07-05, a month stale, holding 9.8 GB of a
# repository that had since grown well past that. A second copy that
# depends on remembering is not a second copy. Since the trigger for
# running it is exactly "the drive is now available", let the machine
# notice that instead.
#
# ── THE DRIVE IDENTIFIES ITSELF ───────────────────────────────────────────
# No volume name is hardcoded. This looks for any mounted volume that
# already contains a `kopia-mirror/` directory — which is precisely what
# the mirror script creates — and treats that as the target. So the drive
# can be renamed or replaced without touching this file: create
# `kopia-mirror` on the new one and it is adopted. A volume WITHOUT that
# directory is never written to, so plugging in an unrelated disk does
# nothing rather than starting a 70 GB sync onto someone's USB stick.
set -eu

REPO_ROOT="/Users/mathewcsims/self-hosted"
LOG="$REPO_ROOT/kopia-mac/mirror.log"
STATE="$REPO_ROOT/kopia-mac/.mirror-state"
LOCK_DIR="$REPO_ROOT/kopia-mac/.mirror.lock"
APPRISE_URL="https://apprise.mathewcsims.uk/notify/self-hosted"

# Don't re-mirror on every mount event. /Volumes changes for all sorts of
# reasons — Time Machine mounting its own sparsebundle, disk images being
# opened — and launchd fires WatchPaths on each one. A full rclone sync is
# expensive, so once a day is plenty for a drive that is plugged in
# occasionally.
MIN_INTERVAL_SECS=$((20 * 60 * 60))

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"
}

notify() {
    curl -fsS --max-time 15 \
        --data-urlencode "title=$1" \
        --data-urlencode "type=$2" \
        --data-urlencode "format=markdown" \
        --data-urlencode "body=$3" \
        "$APPRISE_URL" >/dev/null 2>&1 || log "WARNING: Apprise notification failed"
}

# ── Is the mirror drive present? ─────────────────────────────────────────
TARGET_VOL=""
for v in /Volumes/*/; do
    [ -d "$v/kopia-mirror" ] || continue
    TARGET_VOL="${v%/}"
    break
done

# Nothing plugged in is the normal case, not an error — exit silently so
# this does not spam the log every time any volume appears.
[ -n "$TARGET_VOL" ] || exit 0

# ── Rate-limit ───────────────────────────────────────────────────────────
if [ -f "$STATE" ]; then
    _last=$(awk -F= '/^last_success_epoch=/{print $2}' "$STATE" 2>/dev/null || echo 0)
    _now=$(date +%s)
    if [ -n "$_last" ] && [ "$_last" -gt 0 ] 2>/dev/null; then
        _age=$((_now - _last))
        if [ "$_age" -lt "$MIN_INTERVAL_SECS" ]; then
            exit 0
        fi
    fi
fi

# ── One at a time ────────────────────────────────────────────────────────
# A full sync of the bucket takes a long time; a second one starting
# because the drive remounted mid-run would have two rclones writing the
# same tree. Same mkdir-atomic pattern and stale-lock reclaim as backup.sh.
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    _holder=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
    if [ -n "$_holder" ] && kill -0 "$_holder" 2>/dev/null; then
        log "already mirroring (pid $_holder) — skipping this trigger"
        exit 0
    fi
    log "reclaiming stale lock (pid ${_holder:-unknown} is gone)"
    rm -f "$LOCK_DIR/pid"
fi
echo $$ > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM

log "=== mirroring to $TARGET_VOL ==="
START=$(date +%s)

if "$REPO_ROOT/scripts/mirror-backup-to-external-drive.sh" "$TARGET_VOL" >> "$LOG" 2>&1; then
    END=$(date +%s)
    MINS=$(( (END - START) / 60 ))
    # awk, not `cut -f1`: du pads its output, so cut yields " 75G" with a
    # leading space. And default to "unknown" rather than leaving it blank —
    # the first real run wrote an empty size, which made both the log line
    # and the notification read "complete in 38m ()". A cosmetic field
    # should not be able to produce a confusing report.
    SIZE=$(du -sh "$TARGET_VOL/kopia-mirror" 2>/dev/null | awk '{print $1}')
    [ -n "$SIZE" ] || SIZE="unknown"
    # The verifier reads this to report how stale the second copy is, so it
    # is written ONLY on success — a failed run must not look like a fresh
    # mirror, or the staleness warning silently stops working.
    {
        echo "last_success_epoch=$END"
        echo "last_success_human=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "target=$TARGET_VOL"
        echo "size=$SIZE"
        echo "duration_mins=$MINS"
    } > "$STATE"
    log "=== mirror complete in ${MINS}m ($SIZE) ==="
    notify "💾 Offline backup mirror updated" success \
"The external drive was connected, so the B2 bucket was mirrored to it automatically.

- **Drive:** \`$TARGET_VOL\`
- **Size:** $SIZE
- **Took:** ${MINS} min

This is the second copy for the Pi's and slartibartfast's data, which otherwise exists only in Backblaze B2."
else
    log "=== mirror FAILED ==="
    notify "🚨 Offline backup mirror FAILED" failure \
"Mirroring the B2 bucket to \`$TARGET_VOL\` failed.

The Pi's and slartibartfast's data has no second copy while this is broken — everything else still has one in B2.

Log: $LOG"
    exit 1
fi
