#!/bin/sh
# Run daily by uk.mathewcsims.kopia-mac-backup (LaunchAgent) via launchd's
# StartCalendarInterval — see kopia-mac/uk.mathewcsims.kopia-mac-backup.plist.
#
# Kopia itself needs no secrets here: `kopia repository connect` (done once,
# interactively, when this was set up) persists locally, so subsequent
# `kopia snapshot create` calls just work.
#
# ── WHY THERE IS NO NAS SOURCE HERE ANY MORE (removed 2026-08-04) ─────────
# This used to mount the NAS's AppleBackups share and snapshot it. That
# share contains exactly one thing: heartofgold.sparsebundle — this Mac's
# LIVE Time Machine destination. Backing it up this way could never work,
# and it was actively harmful:
#
#   * It is a 16 TB sparsebundle in 1.35 GiB bands (its own Info.plist),
#     held under a `lock` file, with Time Machine writing into it roughly
#     20 hours a day. Copying bands file-by-file over SMB while they mutate
#     cannot produce a consistent image — a restored bundle would not
#     mount. It was never a usable backup, only an expensive one.
#   * It hung. The run started 2026-08-03 02:00 was still stuck in
#     `kopia snapshot create` on this source 40 hours later, in
#     uninterruptible I/O (state U, frozen CPU time). Because launchd will
#     not start a second instance of a job while the first is alive, THE
#     NEXT NIGHT'S BACKUP NEVER RAN AT ALL. A source that cannot succeed
#     was silently costing whole nights of backups of sources that can.
#   * Even the runs that "succeeded" mostly hadn't: the last one
#     (2026-08-01) reported errors:30 and captured 44 MB across 989 files.
#
# Time Machine still protects this Mac locally, and Kopia already backs up
# the real data from its source directories below — so this is not a
# coverage gap, it is the removal of a backup-of-a-backup that never
# restored. If an offsite copy of Time Machine history is ever wanted, it
# belongs on the NAS itself (replicating that share on its own schedule,
# where the bundle can be quiesced), not here.
#
# Removing it also removed the only use of Proton Pass in this script (the
# "NAS Eddie" item held the SMB password). Kopia needs no secrets — see
# above — and scripts/dump-databases.sh reads database credentials from
# each container's own environment, so no Pass session is needed anywhere
# in this job now.
set -eu

REPO_ROOT="/Users/mathewcsims/self-hosted"
LOG="$REPO_ROOT/kopia-mac/backup.log"
APPRISE_URL="https://apprise.mathewcsims.uk/notify/self-hosted"
# No single source may wedge the whole job again — see the header. 90
# minutes is ~9x the slowest healthy source observed here (copyparty/data),
# so it cannot fire on a merely slow night, only on a genuine hang.
SOURCE_TIMEOUT_SECS=5400

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"
}

log "=== backup run starting ==="

# ── SINGLE-INSTANCE GUARD ────────────────────────────────────────────────
# launchd will not start this job while a previous instance is still alive,
# so a run that wedges silently cancels every subsequent night — exactly
# what the NAS source did for 40 hours (see the header). Kopia itself also
# refuses to run two snapshots against one source concurrently. So: take a
# lock, and if it is already held by a LIVE process, alert instead of
# exiting quietly. A skipped backup that nobody hears about is the failure
# mode this whole file exists to prevent.
#
# mkdir is the atomic primitive here — macOS has no flock(1), and a plain
# `[ -f lockfile ]` test is a race. A stale lock (holder died without
# cleaning up, e.g. the SIGKILL used to clear that 40-hour hang) is
# detected by checking whether the recorded PID is still alive, and then
# reclaimed rather than blocking backups forever.
LOCK_DIR="$REPO_ROOT/kopia-mac/.backup.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    _holder=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
    if [ -n "$_holder" ] && kill -0 "$_holder" 2>/dev/null; then
        log "ABORT: another backup (pid $_holder) is still running"
        curl -fsS --max-time 10 \
            --data-urlencode "title=⚠️ Mac backup skipped — previous run still active" \
            --data-urlencode "type=warning" \
            --data-urlencode "format=markdown" \
            --data-urlencode "body=A previous \`kopia-mac/backup.sh\` (pid $_holder) was still running, so tonight's run was skipped.

While that process lives, launchd will not start this job again — so backups stay stopped until it is cleared. Check what it is stuck on:

    ps -o pid,etime,state,command -p $_holder

Host: mathews-mac" \
            "$APPRISE_URL" >/dev/null 2>&1 || true
        exit 1
    fi
    log "reclaiming stale lock (pid ${_holder:-unknown} is gone)"
    rm -f "$LOCK_DIR/pid"
fi
echo $$ > "$LOCK_DIR/pid"
# Release on any exit path, including failure — otherwise one crash locks
# out every future run, which is the same outage in a different costume.
trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM

# Dump every database to a consistent, restorable file BEFORE snapshotting
# anything. Without this, the datadir paths below (healthlog/pgdata,
# blog/db, bookstack/db, and every SQLite file) are copied while their
# services are running, which can capture torn pages or a .db and -wal that
# disagree — a backup that looks valid until you try to restore it. See
# scripts/dump-databases.sh for the per-engine reasoning.
#
# Deliberately non-fatal: if dumping fails, it alerts via Apprise on its own
# and we still take the file-level snapshots rather than skipping the whole
# backup. A partial backup beats none.
log "dumping databases before snapshot"
if "$REPO_ROOT/scripts/dump-databases.sh" >> "$LOG" 2>&1; then
    log "database dumps completed"
else
    log "WARNING: database dumps reported failures (see Apprise alert) — continuing with file snapshots"
fi

# No MedTimer source here, on purpose. Medications moved off HealthLog to
# MedTimer (an Android app) on 2026-08-04 — its automatic backup writes a
# timestamped JSON to a directory picked through Android's Storage Access
# Framework, so an SMB or WebDAV DocumentsProvider on the phone could drop
# it into copyparty/data or the NAS mount below and it would be swept up
# here with no change to this file. That was considered and declined:
# backup is Syncthing -> Proton Drive, off this repo's infrastructure
# entirely. Don't wire it in. See SETUP.md's HealthLog section for the
# full reasoning (incl. why the copyparty route would cost vague-403).
#
# No marque/data or timetagger/data either — both decommissioned 2026-08-04
# along with Nimbus (see SETUP.md). Their existing snapshots stay in the
# repository, and a final cold archive of each lives permanently in
# db-dumps/decommissioned/ (which IS snapshotted below, so the archives ride
# along with every future backup rather than ageing out of a dormant
# source's retention). Their Kopia policies were set to manual so nothing
# keeps trying to snapshot a path that no longer exists.
SOURCES="
$REPO_ROOT/db-dumps
$REPO_ROOT/karakeep/data
$REPO_ROOT/karakeep/meilisearch-data
$REPO_ROOT/healthlog/data
$REPO_ROOT/healthlog/pgdata
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
$REPO_ROOT/owl/data
$REPO_ROOT/bookstack/config
$REPO_ROOT/bookstack/db
$REPO_ROOT/forgejo/data
$REPO_ROOT/wanderer/data
/Users/mathewcsims/contact-sync
"
# Extra, deliberately-untracked sources (one absolute path per line) — for
# folders whose existence shouldn't be documented in the public repo. The
# file itself is gitignored; missing file = no extra sources.
LOCAL_SOURCES="$REPO_ROOT/kopia-mac/local-sources.txt"
if [ -f "$LOCAL_SOURCES" ]; then
    SOURCES="$SOURCES
$(cat "$LOCAL_SOURCES")"
fi
# Iterate per-LINE, not per-word: paths from local-sources.txt can contain
# spaces, and `for x in $SOURCES` would split them into bogus fragments.
# Each source gets a hard deadline. macOS ships no timeout(1) (that is GNU
# coreutils), so this backgrounds kopia, arms a killer, and waits — the
# portable equivalent. A hung source is killed and RECORDED as a failure
# rather than silently blocking every source after it, and every future
# night's run along with it.
#
# HONEST LIMITATION: a process stuck in uninterruptible I/O (state U, as the
# NAS source was) does not die on SIGKILL until the I/O returns, so `wait`
# here could still block. That is why this is defence in depth, not a single
# fix: the source that could do that is gone (header), this timeout catches
# ordinary hangs, and the single-instance guard above means that if anything
# ever does wedge unkillably you are TOLD the next night instead of quietly
# losing backups for weeks.
FAILED_FILE="$REPO_ROOT/kopia-mac/.backup-failures"
: > "$FAILED_FILE"

printf '%s\n' "$SOURCES" | while IFS= read -r source; do
    [ -n "$source" ] || continue
    log "snapshotting $source"
    _timeout_marker="$REPO_ROOT/kopia-mac/.timed-out.$$"
    rm -f "$_timeout_marker"
    kopia snapshot create "$source" >> "$LOG" 2>&1 &
    _kpid=$!
    # The killer leaves a marker BEFORE killing. Checking `kill -0` after
    # `wait` cannot work — wait reaps the child, so a killed process and a
    # merely-failed one are indistinguishable by then. The marker is what
    # tells a hang apart from an error, and they need different remedies.
    ( sleep "$SOURCE_TIMEOUT_SECS"; touch "$_timeout_marker"; kill -9 "$_kpid" 2>/dev/null ) &
    _killer=$!
    if wait "$_kpid" 2>/dev/null; then
        kill "$_killer" 2>/dev/null || true
    else
        kill "$_killer" 2>/dev/null || true
        if [ -f "$_timeout_marker" ]; then
            log "FAILED (timeout ${SOURCE_TIMEOUT_SECS}s): $source"
            echo "$source (timed out after ${SOURCE_TIMEOUT_SECS}s)" >> "$FAILED_FILE"
        else
            log "FAILED: $source"
            echo "$source" >> "$FAILED_FILE"
        fi
    fi
    rm -f "$_timeout_marker"
done

if [ -s "$FAILED_FILE" ]; then
    log "=== backup run finished WITH FAILURES ==="
    curl -fsS --max-time 10 \
        --data-urlencode "title=🚨 Mac Kopia backup had failing sources" \
        --data-urlencode "type=failure" \
        --data-urlencode "format=markdown" \
        --data-urlencode "body=These sources did not snapshot cleanly on mathews-mac:

$(sed 's/^/  - /' "$FAILED_FILE")

Log: $LOG

The nightly verification (kopia-mac/verify-backups.sh) will also flag these
as stale until they succeed." \
        "$APPRISE_URL" >/dev/null 2>&1 || true
else
    log "=== backup run finished ==="
fi

# Deliberately exit 0 even with failures: the notification above already
# raised them, and a non-zero exit would only add a second, less
# informative launchd error. Verification is the real gate — see
# verify-backups.sh, which runs afterwards and is what actually confirms
# the night succeeded.
