#!/bin/sh
# Nightly proof that the backups actually happened AND are readable, then
# one notification saying so. Run by uk.mathewcsims.kopia-verify (LaunchAgent)
# at 06:00 — after all three hosts have finished:
#
#   babel (Pi)        01:00 kopia-server's own scheduler; 01:30 db-dumps.timer
#   mathews-mac       02:00 kopia-mac/backup.sh (may run to 05:00 worst case:
#                           the home directory is a ~12.7 GB source and any
#                           one source is allowed 3 hours before being killed)
#   slartibartfast    03:00 kopia-immich.timer
#
# ── WHY THIS EXISTS ───────────────────────────────────────────────────────
# Until now the only signal was failure: each job alerted when IT thought it
# had broken. That misses the failures that matter most, because they are
# silent by construction:
#
#   * On 2026-08-03 the Mac's run wedged on the NAS source and never exited.
#     launchd will not start a job whose previous instance is alive, so the
#     next night's backup never ran. Nothing alerted — the job had not
#     failed, it had simply never been allowed to start. It was found by
#     hand, 40 hours later.
#   * The NAS snapshots that DID complete were reporting errors:30 and
#     capturing 44 MB of a 16 TB source. `kopia snapshot create` exited 0
#     throughout: partial success looks exactly like success to the caller.
#
# So this checks the repository itself rather than trusting any job's own
# report — three hosts write into one B2 repository, so one verifier here
# can see all of them.
#
# ── WHAT "VERIFIED" MEANS HERE ────────────────────────────────────────────
#   1. FRESHNESS  — every active source has a snapshot inside the window.
#                   Catches the silent-skip case above.
#   2. CLEANLINESS— that snapshot reports zero errors and zero failed
#                   entries. Catches the partial-success case above.
#   3. STRUCTURE  — `kopia snapshot verify` walks each latest snapshot's
#                   objects and index entries, confirming everything it
#                   references is actually present in the repository.
#   4. CONTENT    — weekly (Sundays), additionally re-download and hash a
#                   sample of real file blobs out of B2. Structure being
#                   intact proves the manifest is coherent; only this proves
#                   the bytes come back. Sampled and weekly because it costs
#                   B2 egress.
#
# Only if all of those pass does the success notification go out. A green
# message here means the data was verified tonight, not that a script
# finished.
#
# ── WHICH SOURCES ARE "ACTIVE" ────────────────────────────────────────────
# Derived from the repository, never hardcoded — a hardcoded list silently
# rots the moment an app is added or removed. A source counts as active
# unless its Kopia policy sets `scheduling.manual`. That is exactly the flag
# set when an app is decommissioned (see SETUP.md), so retired apps drop out
# of these checks automatically while keeping their snapshots, and newly
# added sources are picked up with no change here.
set -eu

REPO_ROOT="/Users/mathewcsims/self-hosted"
LOG="$REPO_ROOT/kopia-mac/verify.log"
APPRISE_URL="https://apprise.mathewcsims.uk/notify/self-hosted"

# Sources are daily. 30h tolerates a late or slow run without crying wolf,
# while still catching a genuinely skipped night at the next check.
# Overridable purely so the failure path can be exercised on demand:
#   MAX_AGE_HOURS=0.001 ./verify-backups.sh   # everything reads as stale
MAX_AGE_HOURS="${MAX_AGE_HOURS:-30}"

# How stale the offline drive mirror may get before the nightly report
# warns. That mirror is the SECOND copy for the Pi's and slartibartfast's
# data — everything else about those hosts lives only in B2 — so letting it
# rot silently turns "two copies of everything" back into one without
# anything saying so. 14 days is loose enough for a drive that is plugged in
# occasionally, tight enough to notice it has stopped being plugged in.
MIRROR_MAX_AGE_DAYS="${MIRROR_MAX_AGE_DAYS:-14}"

# Percentage of files re-downloaded from B2 on the weekly deep pass.
# Overridable so the deep path can be exercised on demand rather than only
# discovering it is broken on some unattended Sunday:
#   DEEP_VERIFY_DOW=$(date +%u) VERIFY_FILES_PERCENT=1 ./verify-backups.sh
VERIFY_FILES_PERCENT="${VERIFY_FILES_PERCENT:-2}"
DEEP_VERIFY_DOW="${DEEP_VERIFY_DOW:-7}"   # 7 = Sunday, per `date +%u`

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"
}

notify() {
    # $1=title  $2=type (success|failure|warning)  $3=body
    curl -fsS --max-time 15 \
        --data-urlencode "title=$1" \
        --data-urlencode "type=$2" \
        --data-urlencode "format=markdown" \
        --data-urlencode "body=$3" \
        "$APPRISE_URL" >/dev/null 2>&1 || log "WARNING: Apprise notification failed to send"
}

log "=== verification starting ==="

# ── Repository reachable at all? ─────────────────────────────────────────
# Distinguished from "a source is stale": if the repo is unreachable we know
# nothing about any source, and reporting 30 stale sources would be a
# misleading way to say "B2 is down".
if ! kopia repository status >/dev/null 2>&1; then
    log "FATAL: repository unreachable"
    notify "🚨 Backup verification FAILED — repository unreachable" failure \
"\`kopia repository status\` failed on mathews-mac, so tonight's backups could not be verified at all.

This says nothing about whether the backups ran — only that the repository could not be reached to check. Look at B2 credentials/connectivity first.

Log: $LOG"
    exit 1
fi

# ── Freshness + cleanliness, straight from the repository ────────────────
REPORT="$REPO_ROOT/kopia-mac/.verify-report"
kopia snapshot list --all --json 2>/dev/null > "$REPO_ROOT/kopia-mac/.snapshots.json"
kopia policy list --json 2>/dev/null > "$REPO_ROOT/kopia-mac/.policies.json"

MAX_AGE_HOURS="$MAX_AGE_HOURS" python3 - \
    "$REPO_ROOT/kopia-mac/.snapshots.json" \
    "$REPO_ROOT/kopia-mac/.policies.json" \
    "$REPORT" <<'PY'
import json, os, sys, datetime

snaps_path, pols_path, report_path = sys.argv[1], sys.argv[2], sys.argv[3]
max_age = float(os.environ["MAX_AGE_HOURS"])

snaps = json.load(open(snaps_path))
pols = json.load(open(pols_path))

# Sources deliberately retired: policy sets scheduling.manual.
dormant = set()
for p in pols:
    if p.get("scheduling", {}).get("manual"):
        t = p.get("target", {})
        dormant.add((t.get("host", ""), t.get("userName", ""), t.get("path", "")))

def parse(ts):
    # Kopia emits RFC3339 with a Z suffix; fromisoformat wants +00:00.
    return datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))

latest = {}
for s in snaps:
    # INCOMPLETE SNAPSHOTS MUST NOT COUNT. Kopia checkpoints a long-running
    # snapshot periodically, and marks an interrupted one, via an
    # `incomplete` field ("checkpoint", "canceled"). These are real manifest
    # entries with recent timestamps and errorCount 0, so treating them as
    # the latest snapshot makes a source that has not completed since
    # 2026-08-01 look backed up as of tonight.
    #
    # Found by testing this script against the real repository rather than
    # assuming: the NAS source's 40-hour hang had left checkpoints, and the
    # first version of this check reported it OK — the exact
    # partial-success-looks-like-success failure the file header says this
    # exists to catch.
    if s.get("incomplete"):
        continue
    src = s["source"]
    key = (src.get("host", ""), src.get("userName", ""), src.get("path", ""))
    st = parse(s["startTime"])
    cur = latest.get(key)
    if cur is None or st > cur["start"]:
        stats = s.get("stats", {}) or {}
        summ = (s.get("rootEntry", {}) or {}).get("summ", {}) or {}
        latest[key] = {
            "start": st,
            "errors": int(stats.get("errorCount") or 0),
            "failed": int(summ.get("numFailed") or 0),
            "size": int(stats.get("totalSize") or 0),
            "id": s["id"],
        }

now = datetime.datetime.now(datetime.timezone.utc)
stale, dirty, ok, skipped, ids = [], [], [], [], []

for key, v in sorted(latest.items()):
    host, user, path = key
    label = f"{user}@{host}:{path}"
    if key in dormant:
        skipped.append(label)
        continue
    age = (now - v["start"]).total_seconds() / 3600.0
    if age > max_age:
        stale.append(f"{label} — last snapshot {age:.1f}h ago")
    elif v["errors"] or v["failed"]:
        dirty.append(f"{label} — {v['errors']} errors, {v['failed']} failed entries")
    else:
        ok.append(label)
        ids.append(v["id"])

with open(report_path, "w") as f:
    json.dump({"stale": stale, "dirty": dirty, "ok": ok,
               "skipped": skipped, "ids": ids}, f)

print(f"active={len(ok) + len(stale) + len(dirty)} ok={len(ok)} "
      f"stale={len(stale)} dirty={len(dirty)} dormant={len(skipped)}")
PY

OK_COUNT=$(python3 -c "import json;print(len(json.load(open('$REPORT'))['ok']))")
STALE=$(python3 -c "import json;print(chr(10).join('  - '+x for x in json.load(open('$REPORT'))['stale']))")
DIRTY=$(python3 -c "import json;print(chr(10).join('  - '+x for x in json.load(open('$REPORT'))['dirty']))")
DORMANT_COUNT=$(python3 -c "import json;print(len(json.load(open('$REPORT'))['skipped']))")
OK_LIST=$(python3 -c "import json;print(chr(10).join('  - '+x for x in json.load(open('$REPORT'))['ok']))")

log "freshness: ok=$OK_COUNT dormant=$DORMANT_COUNT"

if [ -n "$STALE" ] || [ -n "$DIRTY" ]; then
    log "FAILED freshness/cleanliness"
    notify "🚨 Backup verification FAILED" failure \
"Tonight's backups did not verify on one or more sources.

**Stale (no snapshot in the last ${MAX_AGE_HOURS}h):**
${STALE:-  (none)}

**Completed but not clean (errors or failed entries):**
${DIRTY:-  (none)}

$OK_COUNT other source(s) verified fine; $DORMANT_COUNT decommissioned source(s) skipped by design.

A stale source usually means its host's job did not run — check that host's timer/agent, not just the repository.

Log: $LOG"
    exit 1
fi

# ── Structural verification of tonight's snapshots ───────────────────────
# Scoped to the latest snapshot per source rather than the whole repository:
# it is the set this run is actually vouching for, and it keeps the nightly
# check to seconds. --max-errors=0 so the first problem is fatal rather than
# being counted and shrugged off.
IDS=$(python3 -c "import json;print(' '.join(json.load(open('$REPORT'))['ids']))")
log "structural verify over $(echo "$IDS" | wc -w | tr -d ' ') snapshots"

# shellcheck disable=SC2086
if ! kopia snapshot verify --max-errors=0 $IDS >> "$LOG" 2>&1; then
    log "FAILED structural verification"
    notify "🚨 Backup verification FAILED — repository integrity" failure \
"Every source had a fresh, error-free snapshot, but \`kopia snapshot verify\` could not resolve their contents in the repository.

That points at the repository itself (missing or corrupt blobs/index) rather than at any one backup job — the snapshots exist but do not fully resolve, which is precisely the state that looks healthy until a restore is attempted.

Log: $LOG"
    exit 1
fi

# ── Weekly content verification ──────────────────────────────────────────
DEEP_NOTE=""
if [ "$(date +%u)" = "$DEEP_VERIFY_DOW" ]; then
    log "weekly deep verify (${VERIFY_FILES_PERCENT}% of files re-downloaded)"
    # shellcheck disable=SC2086
    if kopia snapshot verify --max-errors=0 \
        --verify-files-percent="$VERIFY_FILES_PERCENT" $IDS >> "$LOG" 2>&1; then
        DEEP_NOTE="

**Weekly deep check:** passed — ${VERIFY_FILES_PERCENT}% of files re-downloaded from Backblaze B2 and hashed, so the bytes genuinely come back, not just the metadata."
        log "deep verify passed"
    else
        log "FAILED deep verification"
        notify "🚨 Backup verification FAILED — content unreadable" failure \
"Structure verified, but the weekly sampled content check could not read files back out of Backblaze B2.

This is the serious one: the snapshots are coherent but the underlying data did not survive a real read. Do not assume a restore would work.

Log: $LOG"
        exit 1
    fi
fi

# ── Second-copy (offline mirror) freshness ───────────────────────────────
# Deliberately NOT a hard failure: a stale mirror does not mean tonight's
# backups are bad, and conflating the two would make the nightly result
# useless for its main job. It is surfaced in the same message instead, so
# it cannot be missed but also cannot cry wolf.
MIRROR_STATE="$REPO_ROOT/kopia-mac/.mirror-state"
MIRROR_NOTE=""
_m_epoch=""
if [ -f "$MIRROR_STATE" ]; then
    _m_epoch=$(awk -F= '/^last_success_epoch=/{print $2}' "$MIRROR_STATE" 2>/dev/null || echo "")
    _m_human=$(awk -F= '/^last_success_human=/{print $2}' "$MIRROR_STATE" 2>/dev/null || echo "unknown")
    _m_size=$(awk -F= '/^size=/{print $2}' "$MIRROR_STATE" 2>/dev/null || echo "?")
fi

# VALIDATE BEFORE DOING ARITHMETIC ON IT. Caught in review: a state file
# with a non-numeric epoch (truncated write, manual edit) made $(( ))
# fail, and `set -eu` then killed the whole script — so a corrupt
# second-copy marker suppressed the ENTIRE nightly verification, with no
# notification at all. The least important input in this file was able to
# silence its most important output. An unparseable marker now reads as
# "never completed", which is both true and safe.
case "$_m_epoch" in
    ''|*[!0-9]*) _m_epoch="" ;;
esac

if [ -n "$_m_epoch" ]; then
    _m_days=$(( ( $(date +%s) - _m_epoch ) / 86400 ))
    if [ "$_m_days" -le "$MIRROR_MAX_AGE_DAYS" ]; then
        MIRROR_NOTE="

**Offline mirror:** last updated $_m_human ($_m_days days ago, $_m_size) — the Pi's and slartibartfast's second copy is current."
    else
        MIRROR_NOTE="

⚠️ **Offline mirror is $_m_days days old** (last $_m_human). Until the external drive is connected again, the Pi's and slartibartfast's data has only ONE copy, in Backblaze B2. Plugging the drive in updates it automatically."
        log "WARNING: offline mirror is $_m_days days old"
    fi
else
    MIRROR_NOTE="

⚠️ **Offline mirror has never completed** (or its state marker is unreadable). The Pi's and slartibartfast's data has only one copy, in Backblaze B2, until the external drive is connected."
    log "WARNING: no usable offline mirror state recorded"
fi

log "=== verification passed ==="
notify "✅ Backups verified — $OK_COUNT sources" success \
"All backups completed and were verified against the repository tonight.

**$OK_COUNT active sources**, every one with a snapshot in the last ${MAX_AGE_HOURS}h, zero errors, and contents resolved in Backblaze B2:

$OK_LIST

Hosts: mathews-mac, babel, slartibartfast — one shared Kopia repository.
$DORMANT_COUNT decommissioned source(s) skipped by design (retained, not snapshotted).$DEEP_NOTE$MIRROR_NOTE"
