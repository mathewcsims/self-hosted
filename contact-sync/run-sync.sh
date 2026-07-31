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
# A MISSING FIELD MUST BE LOUD. This used to print nothing and exit 0 when
# a field name didn't match, so the caller got an empty string and the
# failure only surfaced later, disguised as whatever the provider said
# about an empty credential.
#
# That is exactly how 2026-07-31 went wrong: the Pass item held
# GOGOLE_REFRESH_TOKEN (typo) alongside the real GOOGLE_REFRESH_TOKEN, two
# freshly-minted tokens were pasted into the typo'd one, and Google kept
# reporting "Token has been expired or revoked" — a true statement about
# the stale value being read, and a completely misleading one about the
# cause. Near-miss names are now reported explicitly, because a typo'd
# field is invisible until something names it.
pass_field() {
    PROTON_PASS_AGENT_REASON="contact-sync scheduled run" \
        pass-cli item view --vault-name "Self-Hosted Secrets" --item-title "$1" --output json \
        | python3 -c '
import difflib, json, sys
d = json.load(sys.stdin)
content = d["item"]["content"]["content"]
fields = [f for s in content["Custom"]["sections"] for f in s["section_fields"]]
fields += d["item"]["content"].get("extra_fields", [])
want = sys.argv[1]
names = [f["name"] for f in fields]

for f in fields:
    if f["name"] == want:
        value = list(f["content"].values())[0]
        if not value.strip():
            sys.exit(f"pass_field: {want!r} exists but is EMPTY in this item")
        print(value)
        break
else:
    # cutoff=0.6 is difflib default territory: catches transpositions and
    # single-character slips (GOGOLE/GOOGLE) without matching unrelated names.
    close = difflib.get_close_matches(want, names, n=3, cutoff=0.6)
    hint = ""
    if close:
        hint = ("\n  Did you mean one of these fields that DO exist? "
                + ", ".join(repr(c) for c in close)
                + "\n  A near-miss usually means a value was pasted into a "
                  "misnamed field — rename it rather than duplicating it.")
    sys.exit(f"pass_field: no field named {want!r}. "
             f"Fields present: {names}{hint}")
' "$2"
}

GOOGLE_CLIENT_ID=$(pass_field "Contact Sync Google" GOOGLE_CLIENT_ID)
GOOGLE_CLIENT_SECRET=$(pass_field "Contact Sync Google" GOOGLE_CLIENT_SECRET)
GOOGLE_REFRESH_TOKEN=$(pass_field "Contact Sync Google" GOOGLE_REFRESH_TOKEN)
MS_CLIENT_ID=$(pass_field "Contact Sync Microsoft" MS_CLIENT_ID)
# Pass's own copy is only the bootstrap value. The agent PAT used for
# unattended runs is read-only by design (see SETUP.md's "agent access
# model") — it can never write the rotated token back to Pass, so that's
# not attempted here. Instead the rotated token is cached locally
# (outside the repo, 0600, same as every other on-disk secret in this
# stack) and preferred over Pass's copy on every subsequent run, keeping
# the chain of rotations self-sufficient without needing write access.
MS_TOKEN_CACHE="$HOME/contact-sync/.ms-refresh-token"
if [ -s "$MS_TOKEN_CACHE" ]; then
    MS_REFRESH_TOKEN=$(cat "$MS_TOKEN_CACHE")
else
    MS_REFRESH_TOKEN=$(pass_field "Contact Sync Microsoft" MS_REFRESH_TOKEN)
fi
FORGEJO_BOT_TOKEN=$(pass_field "Forgejo Claude Agent" BOT_TOKEN)
export GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET GOOGLE_REFRESH_TOKEN
export MS_CLIENT_ID MS_REFRESH_TOKEN FORGEJO_BOT_TOKEN
# Proton needs no env: proton-cli reuses its own session file (encrypted
# key blob; see SETUP.md's Phase 0 audit notes).

# Graph rotates refresh tokens: capture fd 3 and cache the new one locally
# (see MS_TOKEN_CACHE note above — Pass itself is never written here).
ROTATED=$(mktemp)
python3 "$REPO_ROOT/contact-sync/sync.py" >> "$LOG" 2>&1 3> "$ROTATED" || log "SYNC FAILED (see above)"
if [ -s "$ROTATED" ]; then
    install -m 600 /dev/null "$MS_TOKEN_CACHE" 2>/dev/null || true
    cat "$ROTATED" > "$MS_TOKEN_CACHE"
    chmod 600 "$MS_TOKEN_CACHE"
    log "rotated MS refresh token cached locally"
fi
rm -f "$ROTATED"

log "=== sync run finished ==="
