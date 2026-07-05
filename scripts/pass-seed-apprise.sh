#!/bin/sh
# One-time (idempotent) setup: registers the Discord webhook URL, fetched
# from Proton Pass, into Apprise's persistent config store under the key
# "self-hosted". Run this once after `docker compose up -d` in ../apprise/,
# and again any time the webhook is rotated in Pass.
#
# The webhook value only ever travels over stdin: this script's own fetch ->
# ssh stdin -> a `read` in the remote shell -> a here-string into `docker
# exec`'s stdin, landing in apprise/scripts/seed.py. It never appears in a
# Bash command line, an env var, a file, or shell history anywhere.
#
# Auto-authenticates using SECRET_ACCESS_TOKEN from the repo-root .env (a
# durable, read-only, vault-scoped Personal Access Token) if no pass-cli
# session is already active — see SETUP.md.
#
# Usage:
#   ./scripts/pass-seed-apprise.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

export PROTON_PASS_SESSION_DIR="${PROTON_PASS_SESSION_DIR:-/tmp/pass-agent-selfhosted}"
mkdir -p "$PROTON_PASS_SESSION_DIR"

if ! pass-cli info >/dev/null 2>&1; then
    if [ ! -f "$REPO_ROOT/.env" ]; then
        echo "No active pass-cli session, and no $REPO_ROOT/.env to auto-login with." >&2
        exit 1
    fi
    echo "No active pass-cli session — logging in with SECRET_ACCESS_TOKEN from .env..."
    set -a
    . "$REPO_ROOT/.env"
    set +a
    export PROTON_PASS_PERSONAL_ACCESS_TOKEN="$SECRET_ACCESS_TOKEN"
    pass-cli login >/dev/null
    unset PROTON_PASS_PERSONAL_ACCESS_TOKEN SECRET_ACCESS_TOKEN
    if ! pass-cli info >/dev/null 2>&1; then
        echo "Login failed — SECRET_ACCESS_TOKEN in .env may be revoked or expired." >&2
        echo "Update self-hosted/.env with a fresh token and retry." >&2
        exit 1
    fi
fi

echo "Fetching Discord webhook from Proton Pass and registering it with Apprise on the Pi..."

PROTON_PASS_AGENT_REASON="Seeding Apprise's Discord notification target" \
    pass-cli item view --vault-name "Self-Hosted Secrets" --item-title "Apprise" --output json \
    | python3 -c '
import json, sys, re

d = json.load(sys.stdin)
sections = d["item"]["content"]["content"]["Custom"]["sections"]
webhook = None
for section in sections:
    for f in section["section_fields"]:
        if f["name"] == "DISCORD_WEBHOOK":
            webhook = list(f["content"].values())[0]

if webhook is None:
    sys.exit("No DISCORD_WEBHOOK field found on the Apprise Pass item")

# Apprise uses its own discord://<id>/<token>/ scheme, not the raw Discord
# API URL — https://github.com/caronc/apprise/wiki/Notify_discord
m = re.match(r"https://discord(?:app)?\.com/api/webhooks/(\d+)/(.+)", webhook)
if not m:
    sys.exit("DISCORD_WEBHOOK is not a recognizable Discord webhook URL")
webhook_id, webhook_token = m.groups()
print(f"discord://{webhook_id}/{webhook_token}/")
' \
    | ssh mathew@babel 'read -r APPRISE_URL && docker exec -i apprise python3 /scripts/seed.py <<<"$APPRISE_URL"'

echo "Done. Test from a LAN machine with:"
echo "  curl -X POST https://apprise.mathewcsims.uk/notify/self-hosted -d 'body=test'"
