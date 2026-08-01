#!/bin/sh
# Dumps Tududi's SQLite database to a consistent file and hands it, plus the
# uploads directory, to Kopia. Triggered daily by tududi-backup.timer at
# 03:45 on slartibartfast.
#
# ── WHY A DUMP, NOT A FILE COPY ───────────────────────────────────────────
# Same reason every database in this repo is now dumped rather than
# snapshotted in place: a file-level copy of a live SQLite database in WAL
# mode can capture a .db and -wal that disagree, producing a "backup" that
# looks fine until you try to restore it. See scripts/dump-databases.sh's
# header for the full reasoning.
#
# ── THE READ-ONLY HANDLE IS LOAD-BEARING ──────────────────────────────────
# `?mode=ro` is not a nicety — DO NOT REMOVE IT. Opening a live SQLite
# database read-write (which is the DEFAULT) takes write locks, checkpoints
# the WAL and rewrites the -shm of a file another process has open. On
# 2026-07-30 that broke Forgejo: it served HTTP 500 with "file is not a
# database" roughly 20 minutes after the first dump, despite the file itself
# being perfectly valid. It was the running app's CONNECTION STATE that
# broke, not the data, and only a container restart cleared it.
#
# A read-only handle takes no write lock and cannot checkpoint, so Tududi's
# own view is untouched. Python's Connection.backup() is the supported
# online-copy API and is safe against a live writer.
#
# sqlite3 the CLI is NOT installed on this box and adding it needs root;
# Python 3 is present, so this uses the same approach as the Pi's dump
# script rather than installing anything.
#
# ── WHY 03:45 ─────────────────────────────────────────────────────────────
# Immich's Kopia run starts at 03:00 and takes ~27 minutes for a 31 GB
# library. 03:45 keeps the two clear of each other on a 4-core box without
# leaving a long idle gap. Both are well after Immich's own 02:00 database
# dump.
#
# Runs as the `mathewcsims` USER via a systemd --user unit (linger enabled),
# so no root anywhere. That works because the container writes as PUID/PGID
# 1000 (see compose.yaml), which is this user.
set -eu

TUDUDI_DATA="$HOME/tududi/data"
DUMP_DIR="$HOME/tududi-dumps"
KOPIA="$HOME/.local/bin/kopia"
LOG="$HOME/tududi-dumps/backup.log"
APPRISE_URL="https://apprise.mathewcsims.uk/notify/self-hosted"
STAMP=$(date +%Y%m%dT%H%M%S)
KEEP=7

mkdir -p "$DUMP_DIR"

log() {
    echo "[$(date -Is)] $1" >> "$LOG"
}

notify_failure() {
    curl -fsS --max-time 10 \
        --data-urlencode "title=⚠️ Tududi backup FAILED on slartibartfast" \
        --data-urlencode "type=failure" \
        --data-urlencode "format=markdown" \
        --data-urlencode "body=$1" \
        "$APPRISE_URL" >/dev/null 2>&1 || true
}

log "=== starting Tududi backup ==="

FAILED=""

# ── Dump the database ─────────────────────────────────────────────────────
# Tududi's SQLite file lives in data/db/. Glob rather than hardcode the
# filename: upstream has renamed/moved it between versions before (the
# container mount path itself changed in v1.2.0), and a hardcoded name that
# silently matches nothing would be a backup of nothing.
DUMPED=0
for _src in "$TUDUDI_DATA"/db/*.sqlite3 "$TUDUDI_DATA"/db/*.sqlite "$TUDUDI_DATA"/db/*.db; do
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

# Finding NO database at all is a failure, not a quiet success — it's the
# signature of the v1.2.0-style mount-path change writing to an anonymous
# volume that gets discarded on container recreation.
if [ "$DUMPED" = 0 ] && [ -z "$FAILED" ]; then
    log "FAIL no database file found under $TUDUDI_DATA/db"
    FAILED="$FAILED no-database-found"
fi

# ── Rotate local dumps (Kopia keeps the real history) ─────────────────────
for _label in $(ls "$DUMP_DIR" 2>/dev/null | sed -E 's/-[0-9]{8}T[0-9]{6}\.gz$//' | sort -u); do
    ls -t "$DUMP_DIR/$_label"-*.gz 2>/dev/null | tail -n +$((KEEP + 1)) \
        | while read -r _old; do rm -f "$_old"; done
done

# ── Snapshot dumps + uploads ──────────────────────────────────────────────
# data/db itself is deliberately NOT snapshotted — the dump above is the
# restorable artefact, and backing up both would invite restoring the wrong
# one. Uploads are plain files, so a direct snapshot is correct for those.
for _src in "$DUMP_DIR" "$TUDUDI_DATA/uploads"; do
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
    notify_failure "Tududi backup failed for:$FAILED

Host: slartibartfast
Log: $LOG

Note: 'no-database-found' specifically means the dump step found no SQLite
file at all under tududi/data/db — check the container's volume mount
paths, which upstream changed in v1.2.0 and which silently write to a
throwaway volume when wrong."
    exit 1
fi

log "=== completed successfully ==="
