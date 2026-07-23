#!/bin/sh
# One-time setup: creates the "Ntfy" Proton Pass item. The two accounts are
# created inside the ntfy container first (`ntfy user add`) — this script
# just records what was chosen there, so it takes the values as env vars
# rather than generating them:
#
#   NTFY_ADMIN_PASSWORD=... NTFY_PUBLISHER_PASSWORD=... NTFY_PUBLISHER_TOKEN=... \
#     ./scripts/pass-create-ntfy-secrets.sh
#
# The publisher account is write-only across all topics — it's what Apprise
# and any script embeds; a leak of it can spam but never read.
set -eu

: "${NTFY_ADMIN_PASSWORD:?set NTFY_ADMIN_PASSWORD}"
: "${NTFY_PUBLISHER_PASSWORD:?set NTFY_PUBLISHER_PASSWORD}"
: "${NTFY_PUBLISHER_TOKEN:?set NTFY_PUBLISHER_TOKEN}"

python3 -c '
import json, os, sys

template = {
    "title": "Ntfy",
    "note": "self-hosted push notification server — see ~/self-hosted/ntfy/. https://ntfy.mathewcsims.uk. admin = mathew (web/app login); publisher = write-only account for Apprise + scripts.",
    "sections": [{
        "section_name": "Secrets",
        "fields": [
            {"field_name": "ADMIN_USERNAME", "field_type": "text", "value": "mathew"},
            {"field_name": "ADMIN_PASSWORD", "field_type": "hidden", "value": os.environ["NTFY_ADMIN_PASSWORD"]},
            {"field_name": "PUBLISHER_USERNAME", "field_type": "text", "value": "publisher"},
            {"field_name": "PUBLISHER_PASSWORD", "field_type": "hidden", "value": os.environ["NTFY_PUBLISHER_PASSWORD"]},
            {"field_name": "PUBLISHER_TOKEN", "field_type": "hidden", "value": os.environ["NTFY_PUBLISHER_TOKEN"]},
        ],
    }],
}
json.dump(template, sys.stdout)
' | pass-cli item create custom --vault-name "Self-Hosted Secrets" --from-template - >/dev/null
# Output suppressed: `item create` echoes the created item back, secrets included.

echo "Done. Verify with:"
echo "  pass-cli item view --vault-name \"Self-Hosted Secrets\" --item-title \"Ntfy\""
