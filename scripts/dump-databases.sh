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

# ── Preflight: is podman actually usable? ─────────────────────────────────
# Every container-based dump below needs it, and a missing binary should be
# ONE clear message rather than three identical mystery failures. This is
# not hypothetical: on 2026-07-31 the LaunchAgent's PATH lacked
# /opt/podman/bin, so podman was absent under launchd and all three
# container dumps silently produced empty files. The plist is fixed (see
# kopia-mac/uk.mathewcsims.kopia-mac-backup.plist), but the script should
# say plainly what is wrong rather than leaving it to be deduced from
# byte counts.
PODMAN_OK=1
if ! command -v podman >/dev/null 2>&1; then
    PODMAN_OK=0
fi

# ── Running a dump command, with the exit status actually checked ─────────
# args: <label> <engine> <output-path> <command...>
#
# WHY THIS ISN'T JUST `cmd | gzip > file`: in a pipeline, `if` tests the
# status of the LAST command — gzip — which happily exits 0 after
# compressing nothing at all. So `podman: command not found` read as
# success, and the only thing that noticed was the size guard below. That
# is a safety net doing a job that belongs to error handling.
#
# Writing the raw dump to a temp file first means the producer's OWN exit
# status is what gets tested. The size guard stays as a second line of
# defence against a command that fails while still returning 0.
run_dump() {
    _label=$1; _engine=$2; _out=$3; shift 3
    _raw="$_out.raw"
    rm -f "$_raw"
    if ! "$@" > "$_raw" 2>/dev/null; then
        rm -f "$_raw"; fail "$_label ($_engine) — dump command failed"; return
    fi
    if ! gzip -c "$_raw" > "$_out"; then
        rm -f "$_raw" "$_out"; fail "$_label ($_engine) — compression failed"; return
    fi
    rm -f "$_raw"
    # A dump that "succeeded" but is a few bytes is a failed dump.
    if [ "$(wc -c < "$_out")" -lt 500 ]; then
        rm -f "$_out"; fail "$_label ($_engine) — dump suspiciously small"
    else
        echo "ok  $(du -h "$_out" | cut -f1)"
    fi
}

# ── Postgres ──────────────────────────────────────────────────────────────
# args: <container> <user> <dbname> <label>
dump_postgres() {
    _c=$1; _u=$2; _d=$3; _l=$4
    printf '  %-22s ' "$_l"
    if [ "$PODMAN_OK" = 0 ]; then
        echo ""; fail "$_l (postgres) — podman not found on PATH"; return
    fi
    run_dump "$_l" postgres "$OUT/$_l-$STAMP.sql.gz" \
        podman exec "$_c" pg_dump -U "$_u" "$_d"
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
    if [ "$PODMAN_OK" = 0 ]; then
        echo ""; fail "$_l (mysql) — podman not found on PATH"; return
    fi
    run_dump "$_l" mysql "$OUT/$_l-$STAMP.sql.gz" \
        podman exec "$_c" sh -c \
        "MYSQL_PWD=\"\$MYSQL_ROOT_PASSWORD\" exec $_bin -u root \"\$MYSQL_DATABASE\" --single-transaction --quick"
}

# ── SQLite ────────────────────────────────────────────────────────────────
# args: <path-to-db> <label>
dump_sqlite() {
    _src=$1; _l=$2
    printf '  %-22s ' "$_l"
    if [ ! -f "$_src" ]; then echo "skip (not present)"; return; fi
    _tmp="$OUT/.$_l-$STAMP.tmp.db"
    rm -f "$_tmp"
    # VACUUM INTO yields a checkpointed, self-contained file (no separate
    # -wal needed to read it).
    #
    # `?mode=ro` IS LOAD-BEARING — do not remove it. The first version of
    # this script opened the source with a plain path, which sqlite3 opens
    # READ-WRITE by default. That takes write locks, checkpoints the WAL
    # and rewrites the -shm of a database another process has open. It
    # broke Forgejo in exactly that way: ~20 minutes after the first dump
    # it began failing every query with "file is not a database" and served
    # HTTP 500, despite the file itself being perfectly valid
    # (integrity_check ok, correct row counts). Only a container restart
    # cleared it.
    #
    # Opening read-only takes no write lock and cannot checkpoint, so the
    # running application's own view is left completely untouched. This is
    # what the Pi script does via Python's read-only URI, and the two are
    # now consistent.
    #
    # THE STOPPED-CONTAINER CASE. A read-only open of a WAL-mode database
    # needs the -shm WAL index, and cannot create one. While the app runs
    # that file exists and the plain open above works. But a clean shutdown
    # checkpoints and REMOVES both -wal and -shm, and the read-only open
    # then fails outright:
    #
    #     Error: stepping, unable to open database file (14)
    #
    # So any app stopped for maintenance overnight produced a spurious
    # FAILED here — an Apprise alert and a dump-failure warning in
    # kopia-mac/backup.sh for a database that is perfectly healthy. False
    # alarms are how real ones get ignored.
    #
    # `immutable=1` tells SQLite the file cannot change, which lets it skip
    # the WAL index entirely. That is only TRUE when nothing has the
    # database open, so it is a guarded fallback and never the first
    # choice.
    #
    # THE GUARD IS THE ABSENCE OF -wal, NOT OF -shm. Measured, because the
    # obvious version of this check is wrong: with -shm deleted but a -wal
    # still holding committed transactions (a hard kill), the plain
    # read-only open SUCCEEDS — SQLite just rebuilds the -shm — while
    # `immutable=1` silently returns the last-checkpointed state and
    # `PRAGMA integrity_check` still says "ok". A test on a 9-row database
    # in that state: plain read-only 9 rows, immutable 3 rows, both "ok".
    # Keying off a missing -shm, or blindly retrying on any failure, would
    # therefore have written a truncated dump and called it a success —
    # exactly the class of silent lie the rest of this script exists to
    # prevent. With no -wal present there is no such content to lose.
    #
    # The Pi script is NOT affected and deliberately not changed: Python's
    # sqlite3 creates the -shm itself on a read-only open, verified on
    # babel (python 3.11.2 / sqlite 3.40.1). This is specific to the
    # sqlite3 CLI (3.51.0 on the Mac).
    _dumped=0
    if sqlite3 "file:$_src?mode=ro" "VACUUM INTO '$_tmp'" 2>/dev/null; then
        _dumped=1
    elif [ ! -e "$_src-wal" ]; then
        rm -f "$_tmp"
        if sqlite3 "file:$_src?mode=ro&immutable=1" "VACUUM INTO '$_tmp'" 2>/dev/null; then
            _dumped=1
        fi
    fi
    if [ "$_dumped" = 1 ] \
       && [ "$(sqlite3 "file:$_tmp?mode=ro" 'PRAGMA integrity_check;' 2>/dev/null)" = "ok" ]; then
        gzip -c "$_tmp" > "$OUT/$_l-$STAMP.db.gz" && rm -f "$_tmp"
        echo "ok  $(du -h "$OUT/$_l-$STAMP.db.gz" | cut -f1)"
    else
        rm -f "$_tmp"; fail "$_l (sqlite)"
    fi
}

echo "=== dumping databases -> $OUT ==="

dump_postgres healthlog-postgres healthlog healthlog healthlog
# HedgeDoc. Note this dump is the notes themselves; images pasted into notes
# live in docs/uploads/ and are covered by the Kopia source instead, not here.
dump_postgres docs-postgres     hedgedoc  hedgedoc  docs

dump_mysql blog-db      mysqldump     ghost
dump_mysql bookstack-db mariadb-dump  bookstack

dump_sqlite "$REPO_ROOT/owl/data/memos_prod.db"                    owl
dump_sqlite "$REPO_ROOT/memos-prospect-ukri-tus/data/memos_prod.db" memos-prospect
dump_sqlite "$REPO_ROOT/vikunja/db/vikunja.db"                     vikunja
dump_sqlite "$REPO_ROOT/forgejo/data/gitea/gitea.db"               forgejo
dump_sqlite "$REPO_ROOT/karakeep/data/db.db"                       karakeep
dump_sqlite "$REPO_ROOT/wanderer/data/pb_data/data.db"             wanderer
# Paperless runs SQLite in WAL mode (db.sqlite3 + -wal + -shm all present on
# a live instance), which is exactly the torn-pages case this file's header
# describes. The document blobs are NOT here — they live on Eddie's
# Paperless share and are covered separately — so this dump plus the
# paperless/data snapshot is what makes the metadata restorable.
dump_sqlite "$REPO_ROOT/paperless/data/db.sqlite3"                 paperless

# Marque and TimeTagger were decommissioned 2026-08-04 (see SETUP.md), so
# neither is dumped here any more. Their final dumps and cold archives live
# permanently in db-dumps/decommissioned/, which the rotation below cannot
# touch — it only globs "$OUT/<label>-*.gz" at the top level, never into a
# subdirectory.

# ── Rotation: keep the most recent $KEEP of each label ────────────────────
# Kopia keeps its own history, so this only bounds local disk.
for _label in $(ls "$OUT" 2>/dev/null | sed -E 's/-[0-9]{8}T[0-9]{6}\.(sql|db)\.gz$//' | sort -u); do
    ls -t "$OUT/$_label"-*.gz 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r _old; do rm -f "$_old"; done
done

# ── Post-dump health check ────────────────────────────────────────────────
# WHY THIS EXISTS: on 2026-07-30 an earlier version of this script opened
# live SQLite databases read-write, which corrupted the *connection state*
# of every SQLite-backed app (see the mode=ro note above). The data was
# fine, but Forgejo, Owl and Marque all began returning HTTP 500. The
# script itself reported complete success throughout, because it only ever
# checked that ITS OWN work succeeded — nothing verified that the
# applications it had just touched were still alive. Mathew found the
# outage, roughly an hour later, by hitting an error page.
#
# So: after dumping, confirm every app whose database we touched still
# serves. Checked through the public hostname rather than a raw port,
# because that's the path that actually matters and there's no port list
# to drift out of date.
#
# Rule: 2xx/3xx/4xx all mean the app is serving (401/403 are auth gates
# working correctly, 30x are normal redirects). Only 5xx — or no response
# at all — counts as broken, which is exactly how that incident presented.
UNHEALTHY=""
echo "=== post-dump health check ==="
for _host in owl prospect-ukri-tus vikunja karakeep wanderer fj healthlog blog author docs; do
    _code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://$_host.mathewcsims.uk/" 2>/dev/null || true)
    [ -z "$_code" ] && _code=000
    case "$_code" in
        5*|000) printf '  %-20s %s  <-- UNHEALTHY\n' "$_host" "$_code"
                UNHEALTHY="$UNHEALTHY
  - $_host (HTTP $_code)" ;;
        *)      printf '  %-20s %s\n' "$_host" "$_code" ;;
    esac
done

if [ -n "$UNHEALTHY" ]; then
    echo "=== APPS UNHEALTHY AFTER DUMP:$UNHEALTHY ==="
    curl -fsS --max-time 10 \
        --data-urlencode "title=🚨 Apps unhealthy immediately after database dump" \
        --data-urlencode "type=failure" \
        --data-urlencode "format=markdown" \
        --data-urlencode "body=These apps stopped serving right after the nightly database dump ran:
$UNHEALTHY

This is the signature of the 2026-07-30 incident: the dump corrupting a
running app's DB *connection* (data intact, integrity_check fine). The fix
then was simply restarting the affected containers.

Host: the Mac. Script: scripts/dump-databases.sh" \
        "$APPRISE_URL" >/dev/null 2>&1 || true
    # Deliberately not exiting here — fall through so a dump failure is
    # also reported, and so backup.sh still takes its file snapshots.
    FAILED="$FAILED
  - POST-DUMP HEALTH: apps unhealthy:$UNHEALTHY"
fi

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
