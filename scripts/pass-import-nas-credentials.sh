#!/bin/sh
# One-time setup: interactively prompts for the NAS's SMB connection
# details (host, share, username, password), then stores them as a new
# Proton Pass item, "NAS Eddie". Nothing is passed as a script argument —
# values only ever exist in your own terminal session and inside this
# script's own piped stdin, never a Bash command line, a file, or a chat
# message.
#
# Run this under your own personal pass-cli session (agent tokens are
# read-only, can't create items).
#
# Usage:
#   ./scripts/pass-import-nas-credentials.sh
set -eu

printf 'NAS host (e.g. eddie.nas): '
read -r NAS_HOST

printf 'NAS share name (e.g. AppleBackups): '
read -r NAS_SHARE

printf 'NAS username: '
read -r NAS_USER

printf 'NAS password (hidden): '
stty -echo
read -r NAS_PASSWORD
stty echo
printf '\n'

{
    printf '%s\n' "$NAS_HOST"
    printf '%s\n' "$NAS_SHARE"
    printf '%s\n' "$NAS_USER"
    printf '%s\n' "$NAS_PASSWORD"
} | python3 -c '
import json, sys

host = sys.stdin.readline().rstrip("\n")
share = sys.stdin.readline().rstrip("\n")
user = sys.stdin.readline().rstrip("\n")
password = sys.stdin.readline().rstrip("\n")

template = {
    "title": "NAS Eddie",
    "note": "self-hosted repo backup system — see ~/self-hosted/kopia-mac/",
    "sections": [{
        "section_name": "Secrets",
        "fields": [
            {"field_name": "NAS_HOST", "field_type": "text", "value": host},
            {"field_name": "NAS_SHARE", "field_type": "text", "value": share},
            {"field_name": "NAS_USER", "field_type": "text", "value": user},
            {"field_name": "NAS_PASSWORD", "field_type": "hidden", "value": password},
        ],
    }],
}
json.dump(template, sys.stdout)
' | pass-cli item create custom --vault-name "Self-Hosted Secrets" --from-template -

echo "Done. Verify with:"
echo "  pass-cli item view --vault-name \"Self-Hosted Secrets\" --item-title \"NAS Eddie\""
