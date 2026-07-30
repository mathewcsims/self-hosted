#!/bin/sh
# Dump every Mac-hosted database to a consistent, restorable file before
# Kopia snapshots anything. Called at the top of kopia-mac/backup.sh.
#
# ── WHY THIS EXISTS ───────────────────────────────────────────────────────
# Until this script, EVERY database in this repo was backed up by
# snapshotting its live data directory while the service was running —
# healthlog/pgdata, blog/db, bookstack/db, plus a pile of SQLite files in
# WAL mode. That is not a backup. A file-level copy of a running Postgres
# or MySQL datadir can capture torn pages and a half-written WAL, and a
# WAL-mode SQLite copy can capture a .db and -wal that disagree. The result
# looks like a valid backup right up until you need it.
#
# Immich was the exception (it ships its own dump), and testing that dump
# is what surfaced the gap for everything else.
#
# ── CONSISTENCY, PER ENGINE ───────────────────────────────────────────────
#   Postgres  pg_dump, run INSIDE the container. No password needed — local
#             socket auth is trusted there — so no credential ever reaches
#             the host or a command line.
#   MySQL/    mysqldump/mariadb-dump with --single-transaction, which takes
#   MariaDB   a consistent InnoDB snapshot without locking the tables (so
#             Ghost and BookStack keep serving during the dump). The root
#             password is read from the container's OWN environment via
#             MYSQL_PWD, so it is never in argv on the host or in the
#             container.
#   SQLite    `VACUUM INTO`, which is safe against a live WAL database — it
#             takes SQLite's own read lock and writes one clean, fully
#             checkpointed file. Verified against a live Memos DB: the copy
#             passed `PRAGMA integrity_check` and its row count matched the
#             source exactly. This is why it beats `cp`.
#
# ── WHAT IS DELIBERATELY NOT DUMPED ───────────────────────────────────────
#   copyparty's up2k.db / shares.db / sessions.db — an upload-dedup index
#     and session state, both regenerable by rescanning; copyparty's actual
#     files are backed up directly.
#   karakeep's queue.db — a transient job queue, not user data.
#   wanderer's pb_data/auxiliary.db — PocketBase's LOG database (35 MB and
#     growing). data.db, the real content, IS dumped.
#
# Failures are collected and reported via Apprise rather than exiting at
# the first problem, so one broken database can't silently prevent the
# other twelve from being dumped. Exits non-zero if anything failed, which
# kopia-mac/backup.sh surfaces.
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(dirname "$SCRIPT_DIR")
OUT="$REPO_ROOT/db-dumps"
STAMP=$(date +%Y%m%dT%H%M%S)
KEEP=7
APPRISE_URL="https://apprise.mathewcsims.uk/notify/self-hosted"
FAILED=""

mkdir -p "$OUT"

fail() {
    echo "  FAILED: $1" >&2
    FAILED="$FAILED
  - $1"
}

# ── Postgres ──────────────────────────────────────────────────────────────
# args: <container> <user> <dbname> <label>
dump_postgres() {
    _c=$1; _u=$2; _d=$3; _l=$4
    printf '  %-22s ' "$_l"
    if podman exec "$_c" pg_dump -U "$_u" "$_d" 2>/dev/null | gzip > "$OUT/$_l-$STAMP.sql.gz"; then
        # A dump that "succeeded" but is a few bytes is a failed dump.
        if [ "$(wc -c < "$OUT/$_l-$STAMP.sql.gz")" -lt 500 ]; then
            rm -f "$OUT/$_l-$STAMP.sql.gz"; fail "$_l (postgres) — dump suspiciously small"
        else
            echo "ok  $(du -h "$OUT/$_l-$STAMP.sql.gz" | cut -f1)"
        fi
    else
        rm -f "$OUT/$_l-$STAMP.sql.gz"; fail "$_l (postgres)"
    fi
}

# ── MySQL / MariaDB ───────────────────────────────────────────────────────
# args: <container> <dump-binary> <label>
#
# Dumps ONLY the app's own database, and deliberately NOT with
# `--all-databases` or `--databases`. Both of those emit `USE <db>;` and
# `CREATE DATABASE` statements into the dump, which OVERRIDE whatever
# target you pipe the restore into — so a "restore into a scratch database"
# silently rewrites the live one instead. Found the hard way: an early
# restore test of this very script wrote back over the live Ghost and
# `mysql` system databases. No data was lost (the dump was minutes old and
# identical), but it easily could have been.
#
# Dumping bare tables like this means the output restores cleanly into ANY
# target database, which is what makes a restore test safe and honest.
# Trade-off accepted: users/grants (the `mysql` system database) are no
# longer captured — they're reproducible from the Pass items and the
# compose files, and are not app data.
#
# MYSQL_PWD keeps the password out of argv entirely; --single-transaction
# gives InnoDB consistency without locking the running app out.
dump_mysql() {
    _c=$1; _bin=$2; _l=$3
    printf '  %-22s ' "$_l"
    if podman exec "$_c" sh -c \
        "MYSQL_PWD=\"\$MYSQL_ROOT_PASSWORD\" exec $_bin -u root \"\$MYSQL_DATABASE\" --single-transaction --quick" \
        2>/dev/null | gzip > "$OUT/$_l-$STAMP.sql.gz"; then
        if [ "$(wc -c < "$OUT/$_l-$STAMP.sql.gz")" -lt 500 ]; then
            rm -f "$OUT/$_l-$STAMP.sql.gz"; fail "$_l (mysql) — dump suspiciously small"
        else
            echo "ok  $(du -h "$OUT/$_l-$STAMP.sql.gz" | cut -f1)"
        fi
    else
        rm -f "$OUT/$_l-$STAMP.sql.gz"; fail "$_l (mysql)"
    fi
}

# ── SQLite ────────────────────────────────────────────────────────────────
# args: <path-to-db> <label>
dump_sqlite() {
    _src=$1; _l=$2
    printf '  %-22s ' "$_l"
    if [ ! -f "$_src" ]; then echo "skip (not present)"; return; fi
    _tmp="$OUT/.$_l-$STAMP.tmp.db"
    rm -f "$_tmp"
    # VACUUM INTO is safe on a live WAL database and yields a checkpointed,
    # self-contained file (no separate -wal needed to read it).
    if sqlite3 "$_src" "VACUUM INTO '$_tmp'" 2>/dev/null \
       && [ "$(sqlite3 "$_tmp" 'PRAGMA integrity_check;' 2>/dev/null)" = "ok" ]; then
        gzip -c "$_tmp" > "$OUT/$_l-$STAMP.db.gz" && rm -f "$_tmp"
        echo "ok  $(du -h "$OUT/$_l-$STAMP.db.gz" | cut -f1)"
    else
        rm -f "$_tmp"; fail "$_l (sqlite)"
    fi
}

echo "=== dumping databases -> $OUT ==="

dump_postgres healthlog-postgres healthlog healthlog healthlog

dump_mysql blog-db      mysqldump     ghost
dump_mysql bookstack-db mariadb-dump  bookstack

dump_sqlite "$REPO_ROOT/owl/data/memos_prod.db"                    owl
dump_sqlite "$REPO_ROOT/marque/data/memos_prod.db"                 marque
dump_sqlite "$REPO_ROOT/memos-prospect-ukri-tus/data/memos_prod.db" memos-prospect
dump_sqlite "$REPO_ROOT/vikunja/db/vikunja.db"                     vikunja
dump_sqlite "$REPO_ROOT/forgejo/data/gitea/gitea.db"               forgejo
dump_sqlite "$REPO_ROOT/karakeep/data/db.db"                       karakeep
dump_sqlite "$REPO_ROOT/wanderer/data/pb_data/data.db"             wanderer

# TimeTagger stores one SQLite file per user; glob rather than hardcode.
for _f in "$REPO_ROOT"/timetagger/data/users/*.db; do
    [ -f "$_f" ] || continue
    dump_sqlite "$_f" "timetagger-$(basename "$_f" .db | cut -c1-24)"
done

# ── Rotation: keep the most recent $KEEP of each label ────────────────────
# Kopia keeps its own history, so this only bounds local disk.
for _label in $(ls "$OUT" 2>/dev/null | sed -E 's/-[0-9]{8}T[0-9]{6}\.(sql|db)\.gz$//' | sort -u); do
    ls -t "$OUT/$_label"-*.gz 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r _old; do rm -f "$_old"; done
done

if [ -n "$FAILED" ]; then
    echo "=== database dumps FAILED for:$FAILED ==="
    curl -fsS --max-time 10 \
        --data-urlencode "title=⚠️ Database dumps failed before backup" \
        --data-urlencode "type=failure" \
        --data-urlencode "format=markdown" \
        --data-urlencode "body=Kopia will still run, but these databases have NO consistent dump this cycle:
$FAILED

Host: the Mac. Script: scripts/dump-databases.sh" \
        "$APPRISE_URL" >/dev/null 2>&1 || true
    exit 1
fi

echo "=== all database dumps completed ==="
