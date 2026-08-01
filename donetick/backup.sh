#!/bin/sh
# Dumps Donetick's SQLite database to a consistent file and hands it, plus
# uploads, to Kopia. Triggered daily by donetick-backup.timer at 03:45 on
# slartibartfast.
#
# ── WHY A DUMP, NOT A FILE COPY ───────────────────────────────────────────
# Same reason every database in this repo is dumped rather than snapshotted
# in place: a file-level copy of a live SQLite database in WAL mode can
# capture a .db and -wal that disagree, producing a "backup" that looks fine
# until you try to restore it. See scripts/dump-databases.sh's header.
#
# ── THE READ-ONLY HANDLE IS LOAD-BEARING ──────────────────────────────────
# `?mode=ro` is not a nicety — DO NOT REMOVE IT. Opening a live SQLite
# database read-write (the DEFAULT) takes write locks, checkpoints the WAL
# and rewrites the -shm of a file another process has open. On 2026-07-30
# that broke Forgejo: HTTP 500s with "file is not a database" about twenty
# minutes after the first dump, despite the file itself being valid. It was
# the running app's CONNECTION STATE that broke, not the data, and only a
# container restart cleared it.
#
# sqlite3 the CLI is NOT installed on this box and adding it needs root;
# Python 3 is present, so this uses Connection.backup(), the supported
# online-copy API, same as the Pi's dump script.
#
# ── WHY 03:45 ─────────────────────────────────────────────────────────────
# Immich's Kopia run starts at 03:00 and takes ~27 minutes for a 31 GB
# library. 03:45 keeps the two clear of each other on a 4-core box.
#
# Runs as the `mathewcsims` USER via a systemd --user unit (linger enabled),
# so no root anywhere.
set -eu

DATA="$HOME/donetick/data"
DUMP_DIR="$HOME/donetick-dumps"
KOPIA="$HOME/.local/bin/kopia"
LOG="$DUMP_DIR/backup.log"
APPRISE_URL="https://apprise.mathewcsims.uk/notify/self-hosted"
STAMP=$(date +%Y%m%dT%H%M%S)
KEEP=7

mkdir -p "$DUMP_DIR"

log() {
    echo "[$(date -Is)] $1" >> "$LOG"
}

notify_failure() {
    curl -fsS --max-time 10 \
        --data-urlencode "title=⚠️ Donetick backup FAILED on slartibartfast" \
        --data-urlencode "type=failure" \
        --data-urlencode "format=markdown" \
        --data-urlencode "body=$1" \
        "$APPRISE_URL" >/dev/null 2>&1 || true
}

log "=== starting Donetick backup ==="
FAILED=""

# ── Dump the database ─────────────────────────────────────────────────────
# Glob rather than hardcode the filename: the SQLite file's name and location
# are the image's business, not ours, and a hardcoded name that silently
# matched nothing would be a backup of nothing.
DUMPED=0
for _src in "$DATA"/*.db "$DATA"/*.sqlite "$DATA"/*.sqlite3; do
    [ -f "$_src" ] || continue
    _name=$(basename "$_src")
    _tmp="$DUMP_DIR/.$_name-$STAMP.tmp"
    rm -f "$_tmp"
    if python3 -c "
import sqlite3, sys
src = sqlite3.connect('file:' + sys.argv[1] + '?mode=ro', uri=True)
dst = sqlite3.connect(sys.argv[2])
src.backup(dst)
dst.close()
chk = sqlite3.connect(sys.argv[2]).execute('PRAGMA integrity_check').fetchone()[0]
sys.exit(0 if chk == 'ok' else 1)
" "$_src" "$_tmp" 2>>"$LOG"; then
        gzip -c "$_tmp" > "$DUMP_DIR/$_name-$STAMP.gz" && rm -f "$_tmp"
        log "OK   dump $_name ($(du -h "$DUMP_DIR/$_name-$STAMP.gz" | cut -f1))"
        DUMPED=$((DUMPED + 1))
    else
        rm -f "$_tmp"
        log "FAIL dump $_name"
        FAILED="$FAILED dump:$_name"
    fi
done

# Finding NO database at all is a failure, not a quiet success — it is the
# signature of the data directory moving inside the image, which would
# otherwise produce cheerful empty backups indefinitely.
if [ "$DUMPED" = 0 ] && [ -z "$FAILED" ]; then
    log "FAIL no database file found under $DATA"
    FAILED="$FAILED no-database-found"
fi

# ── Rotate local dumps (Kopia keeps the real history) ─────────────────────
for _label in $(ls "$DUMP_DIR" 2>/dev/null | sed -E 's/-[0-9]{8}T[0-9]{6}\.gz$//' | sort -u); do
    ls -t "$DUMP_DIR/$_label"-*.gz 2>/dev/null | tail -n +$((KEEP + 1)) \
        | while read -r _old; do rm -f "$_old"; done
done

# ── Snapshot dumps + uploads ──────────────────────────────────────────────
# The live database file itself is deliberately NOT snapshotted — the dump
# above is the restorable artefact, and keeping both invites restoring the
# wrong one.
for _src in "$DUMP_DIR" "$DATA/uploads"; do
    [ -d "$_src" ] || { log "SKIP $_src — does not exist"; continue; }
    if "$KOPIA" snapshot create "$_src" --log-level=error >> "$LOG" 2>&1; then
        log "OK   snapshot $_src"
    else
        log "FAIL snapshot $_src"
        FAILED="$FAILED snapshot:$_src"
    fi
done

if [ -n "$FAILED" ]; then
    log "=== FAILED for:$FAILED ==="
    notify_failure "Donetick backup failed for:$FAILED

Host: slartibartfast
Log: $LOG

'no-database-found' means the dump step found no SQLite file at all under
donetick/data — check the container's volume mount, since that produces
empty backups that look successful."
    exit 1
fi

log "=== completed successfully ==="
