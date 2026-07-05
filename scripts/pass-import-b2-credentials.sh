#!/bin/sh
# One-time setup: interactively prompts for your Backblaze B2 bucket name,
# key ID, and application key, then stores them as a new Proton Pass item,
# "Backblaze B2". Nothing is passed as a script argument or typed anywhere
# except directly into this prompt, in your own terminal — the value never
# touches a Bash command line, a file, or a chat message.
#
# Run this under your own personal pass-cli session (agent tokens are
# read-only, can't create items).
#
# Usage:
#   ./scripts/pass-import-b2-credentials.sh
set -eu

printf 'B2 bucket name: '
read -r B2_BUCKET

printf 'B2 application key ID: '
read -r B2_KEY_ID

printf 'B2 application key (hidden): '
stty -echo
read -r B2_APPLICATION_KEY
stty echo
printf '\n'

{
    printf '%s\n' "$B2_BUCKET"
    printf '%s\n' "$B2_KEY_ID"
    printf '%s\n' "$B2_APPLICATION_KEY"
} | python3 -c '
import json, sys

bucket = sys.stdin.readline().rstrip("\n")
key_id = sys.stdin.readline().rstrip("\n")
app_key = sys.stdin.readline().rstrip("\n")

template = {
    "title": "Backblaze B2",
    "note": "self-hosted repo backup system — see ~/self-hosted/kopia-server/ and ~/self-hosted/kopia-mac/",
    "sections": [{
        "section_name": "Secrets",
        "fields": [
            {"field_name": "B2_BUCKET", "field_type": "text", "value": bucket},
            {"field_name": "B2_KEY_ID", "field_type": "hidden", "value": key_id},
            {"field_name": "B2_APPLICATION_KEY", "field_type": "hidden", "value": app_key},
        ],
    }],
}
json.dump(template, sys.stdout)
' | pass-cli item create custom --vault-name "Self-Hosted Secrets" --from-template -

echo "Done. Verify with:"
echo "  pass-cli item view --vault-name \"Self-Hosted Secrets\" --item-title \"Backblaze B2\""
