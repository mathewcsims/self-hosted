#!/bin/sh
# One-time (idempotent) setup: registers the notification targets, fetched
# from Proton Pass, into Apprise's persistent config store. Run this once
# after `docker compose up -d` in ../apprise/, and again any time the Discord
# webhook or the ntfy publisher token is rotated in Pass.
#
# Two config keys get registered:
#   self-hosted — Discord + ntfy topic "alerts". The general firehose that
#                 every notifier in this repo posts to.
#   fail2ban    — ntfy topic "fail2ban" at priority=low, Discord deliberately
#                 excluded. The caddy-abuse jail bans dozens of IPs a day
#                 (119 lifetime bans by 2026-08-08, 54 concurrently banned),
#                 which buried every other alert on the shared key.
#
# Secrets only ever travel over stdin: this script's own fetch -> ssh stdin ->
# a `read` loop in the remote shell -> a pipe into `docker exec`'s stdin,
# landing in apprise/scripts/seed.py. They never appear in a Bash command
# line, an env var, a file, or shell history anywhere.
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

echo "Fetching Discord webhook + ntfy publisher token from Proton Pass and registering with Apprise on the Pi..."

{
    PROTON_PASS_AGENT_REASON="Seeding Apprise's Discord notification target" \
        pass-cli item view --vault-name "Self-Hosted Secrets" --item-title "Apprise" --output json
    # Ntfy runs alongside Discord on the "self-hosted" key — both registered
    # untagged, so every /notify fans out to both. It is no longer optional:
    # the "fail2ban" key is ntfy-only, so a missing item is a hard error
    # rather than a silent Discord-only fallback that would drop fail2ban
    # notifications on the floor.
    PROTON_PASS_AGENT_REASON="Seeding Apprise's ntfy notification target" \
        pass-cli item view --vault-name "Self-Hosted Secrets" --item-title "Ntfy" --output json
} | python3 -c '
import json, sys, re

def fields_of(d):
    c = d["item"]["content"]
    fs = [f for s in c["content"]["Custom"]["sections"] for f in s["section_fields"]]
    fs += c.get("extra_fields", [])
    return {f["name"]: list(f["content"].values())[0] for f in fs}

decoder = json.JSONDecoder()
raw = sys.stdin.read().strip()
docs, idx = [], 0
while idx < len(raw):
    d, end = decoder.raw_decode(raw, idx)
    docs.append(d)
    idx = end
    while idx < len(raw) and raw[idx] in " \n\r\t":
        idx += 1

apprise_item = fields_of(docs[0])
webhook = apprise_item.get("DISCORD_WEBHOOK")
if webhook is None:
    sys.exit("No DISCORD_WEBHOOK field found on the Apprise Pass item")

# Apprise uses its own discord://<id>/<token>/ scheme, not the raw Discord
# API URL — https://github.com/caronc/apprise/wiki/Notify_discord
m = re.match(r"https://discord(?:app)?\.com/api/webhooks/(\d+)/(.+)", webhook)
if not m:
    sys.exit("DISCORD_WEBHOOK is not a recognizable Discord webhook URL")
webhook_id, webhook_token = m.groups()
# format=markdown: lets notifiers use **bold**/lists in the body instead of
# flat text. image=yes: shows a small type icon (info/warning/error/
# success) in the embed. Neither is a secret - safe to hardcode here rather
# than store as a Pass field.
urls = [f"discord://{webhook_id}/{webhook_token}/?format=markdown&image=yes"]

if len(docs) < 2 or not docs[1].get("item"):
    sys.exit("Could not read the Ntfy Pass item — needed for the fail2ban key")
ntfy_token = fields_of(docs[1]).get("PUBLISHER_TOKEN")
if not ntfy_token:
    sys.exit("No PUBLISHER_TOKEN field found on the Ntfy Pass item")

# auth=token: the publisher access token (write-only, all topics — verified
# live via `ntfy access`, so a new topic needs no ACL change; the admin user
# "mathew" reads every topic). Topic "alerts" is the general firehose
# mirroring Discord.
urls.append(f"ntfys://ntfy.mathewcsims.uk/alerts?token={ntfy_token}&auth=token&format=markdown")

# fail2ban gets its own topic at priority=low, and no Discord target at all.
# priority= is an Apprise ntfy arg (choice of max/high/default/low/min,
# confirmed from NotifyNtfy.template_args in the running container). It maps
# straight to the X-Priority header ntfy reads, and is NOT derived from the
# POSTed `type`, so `type=failure` no longer forces a loud notification.
fail2ban_url = f"ntfys://ntfy.mathewcsims.uk/fail2ban?token={ntfy_token}&auth=token&format=markdown&priority=low"

print("self-hosted\t" + ",".join(urls))
print("fail2ban\t" + fail2ban_url)
' \
    | ssh mathew@babel 'while IFS= read -r LINE; do printf "%s\n" "$LINE" | docker exec -i apprise python3 /scripts/seed.py; done'

echo "Done. Test from a LAN machine with:"
echo "  curl -X POST https://apprise.mathewcsims.uk/notify/self-hosted -d 'body=test'"
echo "  curl -X POST https://apprise.mathewcsims.uk/notify/fail2ban -d 'body=test'"
