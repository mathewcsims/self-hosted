#!/bin/sh
# One-time setup: records the Tailscale webhook signing secret. Tailscale
# generates this itself when the webhook is created (POST
# /tailnet/-/webhooks) and shows it exactly once in the API response — it
# can't be retrieved again afterward, only rotated (delete + recreate the
# webhook). This script just takes that value as an env var and stores it.
#
# Usage:
#   TS_WEBHOOK_SECRET=tskey-webhook-... ./scripts/pass-create-tailscale-webhook-secret.sh
set -eu

: "${TS_WEBHOOK_SECRET:?set TS_WEBHOOK_SECRET}"

python3 -c '
import json, os, sys

template = {
    "title": "Tailscale Webhook Relay",
    "note": "Signing secret for the Tailscale -> Apprise webhook relay — see ~/self-hosted/tailscale-webhook-relay/. Endpoint: https://tailscale-relay.mathewcsims.uk/webhook. Rotate by deleting + recreating the webhook via the Tailscale API (the secret cannot be re-fetched, only regenerated).",
    "sections": [{
        "section_name": "Secrets",
        "fields": [
            {"field_name": "WEBHOOK_SECRET", "field_type": "hidden", "value": os.environ["TS_WEBHOOK_SECRET"]},
        ],
    }],
}
json.dump(template, sys.stdout)
' | pass-cli item create custom --vault-name "Self-Hosted Secrets" --from-template - >/dev/null

echo "Done. Verify with:"
echo "  pass-cli item view --vault-name \"Self-Hosted Secrets\" --item-title \"Tailscale Webhook Relay\""
