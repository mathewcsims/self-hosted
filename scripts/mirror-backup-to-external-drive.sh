#!/bin/sh
# Manually-triggered: mirrors the entire Backblaze B2 bucket (Kopia's
# repository storage — already encrypted client-side before any of it ever
# reached B2, so no extra encryption is needed here) onto an external drive.
# Run this yourself whenever the drive is plugged in — there's no automatic
# schedule, since the drive isn't always connected.
#
# Uses rclone's B2 backend purely via environment variables
# (RCLONE_B2_ACCOUNT/RCLONE_B2_KEY, with RCLONE_CONFIG=/dev/null so no
# rclone.conf is ever read or written) — confirmed working directly against
# the live bucket. The token only ever exists inside this one Python
# process's memory, passed to rclone as env vars for its own subprocess,
# never printed or written to disk.
#
# `rclone sync` (not `copy`) makes the destination an exact mirror,
# including deleting anything removed from B2 since the last run — this is
# what you want for a periodic full mirror, not an ever-growing pile of
# old copies.
#
# The resulting directory is a complete, independently-restorable Kopia
# repository on its own: if you ever needed to restore with nothing but
# this external drive (no B2 access at all), point `kopia repository
# connect filesystem --path=<drive>/kopia-mirror` at it with the same
# repository password from the "Kopia" Pass item, and browse/restore
# exactly as you would against B2.
#
# Usage:
#   ./scripts/mirror-backup-to-external-drive.sh /Volumes/YourDriveName
set -eu

TARGET_PARENT="${1:?Usage: $0 <path-to-external-drive>}"
TARGET="$TARGET_PARENT/kopia-mirror"

if [ ! -d "$TARGET_PARENT" ]; then
    echo "Not found: $TARGET_PARENT — is the drive plugged in and mounted?" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

export PROTON_PASS_SESSION_DIR="${PROTON_PASS_SESSION_DIR:-/tmp/pass-agent-selfhosted}"
mkdir -p "$PROTON_PASS_SESSION_DIR"

if ! pass-cli info >/dev/null 2>&1; then
    if [ ! -f "$REPO_ROOT/.env" ]; then
        echo "No active pass-cli session, and no $REPO_ROOT/.env to auto-login with." >&2
        exit 1
    fi
    set -a
    . "$REPO_ROOT/.env"
    set +a
    export PROTON_PASS_PERSONAL_ACCESS_TOKEN="$SECRET_ACCESS_TOKEN"
    pass-cli login >/dev/null
    unset PROTON_PASS_PERSONAL_ACCESS_TOKEN SECRET_ACCESS_TOKEN
fi

echo "Mirroring B2 bucket to $TARGET ..."

PROTON_PASS_AGENT_REASON="Fetching B2 credentials to mirror the backup bucket to an external drive" \
    pass-cli item view --vault-name "Self-Hosted Secrets" --item-title "Backblaze B2" --output json \
    | TARGET="$TARGET" python3 -c '
import json, os, sys, subprocess

d = json.load(sys.stdin)
fields = {}
for s in d["item"]["content"]["content"]["Custom"]["sections"]:
    for f in s["section_fields"]:
        fields[f["name"]] = list(f["content"].values())[0]

env = os.environ.copy()
env["RCLONE_B2_ACCOUNT"] = fields["B2_KEY_ID"]
env["RCLONE_B2_KEY"] = fields["B2_APPLICATION_KEY"]
env["RCLONE_CONFIG"] = "/dev/null"

bucket = fields["B2_BUCKET"]
target = os.environ["TARGET"]
source = f":b2:{bucket}"

result = subprocess.run(["rclone", "sync", source, target, "--progress"], env=env)
sys.exit(result.returncode)
'

echo "Done. $TARGET is now a complete mirror of the B2 backup bucket."
