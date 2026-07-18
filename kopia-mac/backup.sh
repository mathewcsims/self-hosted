#!/bin/sh
# Run daily by uk.mathewcsims.kopia-mac-backup (LaunchAgent) via launchd's
# StartCalendarInterval — see kopia-mac/uk.mathewcsims.kopia-mac-backup.plist.
#
# Kopia itself needs no secrets here: `kopia repository connect` (done once,
# interactively, when this was set up) persists locally, so subsequent
# `kopia snapshot create` calls just work.
#
# The NAS mount originally used the macOS Keychain (no password ever on a
# command line) — but that turned out to be unreliable specifically for
# launchd: the exact same `mount_smbfs` call that succeeded with no prompt
# when run interactively in Terminal failed with "Authentication error"
# every time launchd triggered it, confirmed directly from the first two
# real overnight runs. macOS's Keychain access control apparently treats a
# launchd-spawned process differently from a Terminal-attached one, and
# there's no reliable way to grant a headless launchd job the same access.
#
# So this now fetches the NAS password from Proton Pass ("NAS Eddie" item)
# instead. Accepted trade-off, not an oversight: mount_smbfs only ever takes
# credentials via its URL argument — there's no piped-input alternative —
# so the password is briefly visible in `ps` output once a day during this
# run. On this single-user Mac, holding that NAS password is a much smaller
# blast radius than anything else a real compromise would already expose.
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

export PROTON_PASS_SESSION_DIR="${PROTON_PASS_SESSION_DIR:-/tmp/pass-agent-selfhosted}"
mkdir -p "$PROTON_PASS_SESSION_DIR"

if ! pass-cli info >/dev/null 2>&1; then
    if [ -f "$REPO_ROOT/.env" ]; then
        set -a
        . "$REPO_ROOT/.env"
        set +a
        export PROTON_PASS_PERSONAL_ACCESS_TOKEN="$SECRET_ACCESS_TOKEN"
        pass-cli login >> "$LOG" 2>&1 || true
        unset PROTON_PASS_PERSONAL_ACCESS_TOKEN SECRET_ACCESS_TOKEN
    fi
fi

mkdir -p "$NAS_MOUNT"
if ! mount | grep -q "$NAS_MOUNT"; then
    MOUNT_URL="$(PROTON_PASS_AGENT_REASON="Mounting NAS share for scheduled Kopia backup" \
        pass-cli item view --vault-name "Self-Hosted Secrets" --item-title "NAS Eddie" --output json 2>>"$LOG" \
        | python3 -c '
import json, sys, urllib.parse

d = json.load(sys.stdin)
fields = {}
for s in d["item"]["content"]["content"]["Custom"]["sections"]:
    for f in s["section_fields"]:
        fields[f["name"]] = list(f["content"].values())[0]

user = urllib.parse.quote(fields["NAS_USER"], safe="")
password = urllib.parse.quote(fields["NAS_PASSWORD"], safe="")
host = fields["NAS_HOST"]
share = fields["NAS_SHARE"]
print(f"//{user}:{password}@{host}/{share}")
' 2>>"$LOG")"

    if [ -n "$MOUNT_URL" ] && mount_smbfs "$MOUNT_URL" "$NAS_MOUNT" >> "$LOG" 2>&1; then
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
$REPO_ROOT/timetagger/data
$REPO_ROOT/owl/data
$REPO_ROOT/marque/data
$REPO_ROOT/bookstack/config
$REPO_ROOT/bookstack/db
$REPO_ROOT/forgejo/data
/Users/mathewcsims/contact-sync
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
