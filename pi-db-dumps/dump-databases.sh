#!/bin/sh
# Dump every Pi-hosted database to a consistent, restorable file, then hand
# the results to Kopia. The Mac equivalent is scripts/dump-databases.sh —
# see that file's header for WHY this exists (short version: every database
# in this repo used to be "backed up" by copying its live data directory,
# which is not a backup).
#
# Driven by db-dumps.timer at 01:30 — deliberately BEFORE kopia-server's own
# daily snapshot cycle, so each snapshot picks up that night's fresh dumps.
#
# ── WHY THIS ISN'T JUST THE MAC SCRIPT ────────────────────────────────────
# Two Pi-specific constraints:
#   1. `sqlite3` is NOT installed here and installing it needs sudo. Python
#      3.11 is present, and its stdlib sqlite3 module exposes the CANONICAL
#      online-backup API (`Connection.backup()`), which is safe against a
#      live WAL database. Verified against uptime-kuma's 9.7 MB kuma.db
#      while it was actively being written: the copy passed
#      `PRAGMA integrity_check`. So no new packages, images, or root.
#   2. The Pi's Kopia is a SERVER with its own internal scheduler, so there
#      is no host-side "before snapshot" hook like the Mac's backup.sh. This
#      script therefore triggers the snapshot itself at the end, rather than
#      relying on kopia-server's bootstrap loop — which (confirmed by
#      reading entrypoint.sh) only ever configures sources on the very
#      first run against an empty repository, so a newly-added mount would
#      otherwise be silently ignored forever.
#
# Runs as a systemd --user unit (linger enabled), so no root anywhere.
set -eu

OUT="$HOME/db-dumps"
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

# ── Postgres, dumped inside the container (no password needed there) ──────
dump_postgres() {
    _c=$1; _l=$2
    printf '  %-20s ' "$_l"
    if docker exec "$_c" sh -c 'exec pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' 2>/dev/null \
        | gzip > "$OUT/$_l-$STAMP.sql.gz"; then
        if [ "$(wc -c < "$OUT/$_l-$STAMP.sql.gz")" -lt 500 ]; then
            rm -f "$OUT/$_l-$STAMP.sql.gz"; fail "$_l (postgres) — dump suspiciously small"
        else
            echo "ok  $(du -h "$OUT/$_l-$STAMP.sql.gz" | cut -f1)"
        fi
    else
        rm -f "$OUT/$_l-$STAMP.sql.gz"; fail "$_l (postgres)"
    fi
}

# ── SQLite via Python's online backup API ─────────────────────────────────
# Opens the source read-only and uses Connection.backup(), which is the
# supported way to copy a database that is being written to. A plain `cp`
# of a WAL-mode database can capture a .db and -wal that disagree.
dump_sqlite() {
    _src=$1; _l=$2
    printf '  %-20s ' "$_l"
    if [ ! -f "$_src" ]; then echo "skip (not present)"; return; fi
    _tmp="$OUT/.$_l-$STAMP.tmp.db"
    rm -f "$_tmp"
    if python3 -c "
import sqlite3, sys
src = sqlite3.connect('file:' + sys.argv[1] + '?mode=ro', uri=True)
dst = sqlite3.connect(sys.argv[2])
src.backup(dst)
dst.close()
chk = sqlite3.connect(sys.argv[2]).execute('PRAGMA integrity_check').fetchone()[0]
sys.exit(0 if chk == 'ok' else 1)
" "$_src" "$_tmp" 2>/dev/null; then
        gzip -c "$_tmp" > "$OUT/$_l-$STAMP.db.gz" && rm -f "$_tmp"
        echo "ok  $(du -h "$OUT/$_l-$STAMP.db.gz" | cut -f1)"
    else
        rm -f "$_tmp"; fail "$_l (sqlite)"
    fi
}

echo "=== dumping Pi databases -> $OUT ==="

# No nimbus-db here: Nimbus was decommissioned 2026-08-04 (see SETUP.md).
# Its final pg_dump and a cold archive of its whole data directory live
# permanently in db-dumps/decommissioned/.

dump_sqlite "$HOME/uptime-kuma/data/kuma.db"                uptime-kuma
dump_sqlite "$HOME/speedtest-tracker/config/database.sqlite" speedtest-tracker
dump_sqlite "$HOME/msims-link/data/urls.sqlite"             msims-link
dump_sqlite "$HOME/ntfy/data/user.db"                       ntfy-user
dump_sqlite "$HOME/ntfy/data/cache.db"                      ntfy-cache

# NOT dumped, deliberately: msims-link/data/backups/* — those are
# chhoto-url's OWN rotating backups, i.e. backups of the thing we just
# dumped properly. Snapshotting them too would just cost B2 space.

# ── Rotation: keep the most recent $KEEP per label (Kopia keeps history) ──
for _label in $(ls "$OUT" 2>/dev/null | sed -E 's/-[0-9]{8}T[0-9]{6}\.(sql|db)\.gz$//' | sort -u); do
    ls -t "$OUT/$_label"-*.gz 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r _old; do rm -f "$_old"; done
done

# ── Hand the dumps to Kopia ───────────────────────────────────────────────
# Triggered explicitly rather than left to kopia-server's schedule: see the
# header for why a newly-added source wouldn't otherwise be picked up.
# /data/db-dumps is this directory, mounted read-only into kopia-server
# (see kopia-server/compose.yaml).
printf '  %-20s ' "kopia snapshot"
if docker exec kopia-server kopia snapshot create /data/db-dumps >/dev/null 2>&1; then
    echo "ok"
else
    fail "kopia snapshot of /data/db-dumps"
fi

# ── Post-dump health check ────────────────────────────────────────────────
# See scripts/dump-databases.sh's equivalent block for the full reasoning.
# Short version: on 2026-07-30 the Mac script corrupted the DB *connection
# state* of every SQLite-backed app while reporting complete success,
# because nothing checked the apps afterwards. This Pi script always used a
# read-only handle and so wasn't implicated — but it dumps the same class of
# live SQLite databases, so it gets the same safety net.
#
# 2xx/3xx/4xx = serving (auth gates and redirects are fine); 5xx or no
# response = broken.
UNHEALTHY=""
echo "=== post-dump health check ==="
for _host in status speedtest msims.link; do
    case "$_host" in
        msims.link) _url="https://msims.link/" ;;
        *)          _url="https://$_host.mathewcsims.uk/" ;;
    esac
    _code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$_url" 2>/dev/null || true)
    [ -z "$_code" ] && _code=000
    case "$_code" in
        5*|000) printf '  %-14s %s  <-- UNHEALTHY\n' "$_host" "$_code"
                UNHEALTHY="$UNHEALTHY
  - $_host (HTTP $_code)" ;;
        *)      printf '  %-14s %s\n' "$_host" "$_code" ;;
    esac
done

if [ -n "$UNHEALTHY" ]; then
    echo "=== APPS UNHEALTHY AFTER DUMP:$UNHEALTHY ==="
    curl -fsS --max-time 10 \
        --data-urlencode "title=🚨 Pi apps unhealthy immediately after database dump" \
        --data-urlencode "type=failure" \
        --data-urlencode "format=markdown" \
        --data-urlencode "body=These Pi apps stopped serving right after the nightly dump ran:
$UNHEALTHY

Signature of the 2026-07-30 incident (dump corrupting a running app's DB
connection; data intact). Fix then was restarting the affected containers.

Host: babel. Script: pi-db-dumps/dump-databases.sh" \
        "$APPRISE_URL" >/dev/null 2>&1 || true
    FAILED="$FAILED
  - POST-DUMP HEALTH: apps unhealthy:$UNHEALTHY"
fi

if [ -n "$FAILED" ]; then
    echo "=== Pi database dumps FAILED for:$FAILED ==="
    curl -fsS --max-time 10 \
        --data-urlencode "title=⚠️ Pi database dumps failed" \
        --data-urlencode "type=failure" \
        --data-urlencode "format=markdown" \
        --data-urlencode "body=These Pi databases have NO consistent dump this cycle:
$FAILED

Host: babel (the Pi). Script: pi-db-dumps/dump-databases.sh" \
        "$APPRISE_URL" >/dev/null 2>&1 || true
    exit 1
fi

echo "=== all Pi database dumps completed ==="
