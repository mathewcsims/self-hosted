#!/bin/sh
# Scheduled entrypoint for contact-sync — run daily by
# uk.mathewcsims.contact-sync (LaunchAgent), same pattern as
# kopia-mac/backup.sh. Fetches every spoke's secrets from Proton Pass
# into environment variables (never argv, never files), then runs the
# engine. Auto-authenticates pass-cli with SECRET_ACCESS_TOKEN from the
# repo-root .env if no session is active.
set -eu

REPO_ROOT="/Users/mathewcsims/self-hosted"
LOG="$HOME/contact-sync/sync.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"
}

log "=== sync run starting ==="

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

# Reads BOTH Custom.sections and extra_fields — which one a field lands in
# depends on how it was added (create --from-template vs update --field);
# see the forgejo-api skill for where that was learned the hard way.
pass_field() {
    PROTON_PASS_AGENT_REASON="contact-sync scheduled run" \
        pass-cli item view --vault-name "Self-Hosted Secrets" --item-title "$1" --output json \
        | python3 -c '
import json, sys
d = json.load(sys.stdin)
content = d["item"]["content"]["content"]
fields = [f for s in content["Custom"]["sections"] for f in s["section_fields"]]
fields += d["item"]["content"].get("extra_fields", [])
for f in fields:
    if f["name"] == sys.argv[1]:
        print(list(f["content"].values())[0])
' "$2"
}

GOOGLE_CLIENT_ID=$(pass_field "Contact Sync Google" GOOGLE_CLIENT_ID)
GOOGLE_CLIENT_SECRET=$(pass_field "Contact Sync Google" GOOGLE_CLIENT_SECRET)
GOOGLE_REFRESH_TOKEN=$(pass_field "Contact Sync Google" GOOGLE_REFRESH_TOKEN)
MS_CLIENT_ID=$(pass_field "Contact Sync Microsoft" MS_CLIENT_ID)
MS_REFRESH_TOKEN=$(pass_field "Contact Sync Microsoft" MS_REFRESH_TOKEN)
FORGEJO_BOT_TOKEN=$(pass_field "Forgejo Claude Agent" BOT_TOKEN)
export GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET GOOGLE_REFRESH_TOKEN
export MS_CLIENT_ID MS_REFRESH_TOKEN FORGEJO_BOT_TOKEN
# Proton needs no env: proton-cli reuses its own session file (encrypted
# key blob; see SETUP.md's Phase 0 audit notes).

# Graph rotates refresh tokens: capture fd 3 and store the new one.
ROTATED=$(mktemp)
python3 "$REPO_ROOT/contact-sync/sync.py" >> "$LOG" 2>&1 3> "$ROTATED" || log "SYNC FAILED (see above)"
if [ -s "$ROTATED" ]; then
    PROTON_PASS_AGENT_REASON="Storing rotated MS refresh token from scheduled sync" \
        pass-cli item update --vault-name "Self-Hosted Secrets" \
        --item-title "Contact Sync Microsoft" \
        --field MS_REFRESH_TOKEN="$(cat "$ROTATED")" >/dev/null 2>>"$LOG" \
        && log "rotated MS refresh token stored"
fi
rm -f "$ROTATED"

log "=== sync run finished ==="
