#!/bin/sh
# One-time setup: creates the "TimeTagger" Proton Pass item. Only
# OAUTH2_PROXY_COOKIE_SECRET is actually generated here — OIDC_CLIENT_ID and
# OIDC_CLIENT_SECRET can't be, since those come from registering a new OIDC
# application in Infomaniak's IK-AUTH (manager.infomaniak.com), a step only
# you can do (it's your Infomaniak account). Register it with redirect URI
# https://time.mathewcsims.uk/oauth2/callback, then edit the two placeholder
# fields this creates via:
#   pass-cli item update --vault-name "Self-Hosted Secrets" --item-title "TimeTagger" \
#       --field OIDC_CLIENT_ID=... --field OIDC_CLIENT_SECRET=...
#
# Usage:
#   ./scripts/pass-create-timetagger-secrets.sh
set -eu

COOKIE_SECRET=$(python3 -c 'import os,base64; print(base64.urlsafe_b64encode(os.urandom(32)).decode())')

python3 -c '
import json, sys

cookie_secret = sys.argv[1]

template = {
    "title": "TimeTagger",
    "note": "self-hosted time tracker — see ~/self-hosted/timetagger/. OIDC_CLIENT_ID/SECRET need setting after IK-AUTH registration.",
    "sections": [{
        "section_name": "Secrets",
        "fields": [
            {"field_name": "OIDC_CLIENT_ID", "field_type": "hidden", "value": "SET_ME_AFTER_IK_AUTH_REGISTRATION"},
            {"field_name": "OIDC_CLIENT_SECRET", "field_type": "hidden", "value": "SET_ME_AFTER_IK_AUTH_REGISTRATION"},
            {"field_name": "OAUTH2_PROXY_COOKIE_SECRET", "field_type": "hidden", "value": cookie_secret},
            {"field_name": "ALLOWED_EMAIL", "field_type": "text", "value": "mat@mathewcsims.uk"},
        ],
    }],
}
json.dump(template, sys.stdout)
' "$COOKIE_SECRET" \
    | pass-cli item create custom --vault-name "Self-Hosted Secrets" --from-template - >/dev/null
# Output suppressed: `item create` echoes the created item back, including
# the secret value just generated above — confirmed the hard way, then
# rotated. Never let this command's stdout reach a terminal/log unredirected.

echo "Done. Verify with:"
echo "  pass-cli item view --vault-name \"Self-Hosted Secrets\" --item-title \"TimeTagger\""
echo
echo "Next: register an OIDC app in Infomaniak's IK-AUTH, then set OIDC_CLIENT_ID"
echo "and OIDC_CLIENT_SECRET on this item (and correct ALLOWED_EMAIL if needed)."
