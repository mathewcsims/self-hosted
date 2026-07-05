#!/bin/sh
# One-time setup: generates a random HMAC secret and stores it as a new
# Proton Pass item, "VikunjaWebhookRelay", for vikunja-webhook-relay/ to
# read at deploy time (via pass-deploy-remote.sh, same as every other app).
#
# Deliberately NOT run by the agent — pass-cli agent PATs are read-only by
# design, so item creation has to happen under your own personal pass-cli
# session, not the agent one used elsewhere in this repo's tooling.
#
# The secret is generated INSIDE this script rather than passed in, so it
# never has to be typed or seen anywhere except: here, once, printed at the
# end so you can paste it into Vikunja's own "Secret" field.
#
# Usage:
#   ./scripts/pass-create-vikunja-relay-secret.sh
set -eu

SECRET=$(openssl rand -hex 32)

printf '{"title":"VikunjaWebhookRelay","note":"self-hosted repo secrets — see ~/self-hosted/vikunja-webhook-relay/","sections":[{"section_name":"Secrets","fields":[{"field_name":"WEBHOOK_SECRET","field_type":"hidden","value":"%s"}]}]}' "$SECRET" \
    | pass-cli item create custom --vault-name "Self-Hosted Secrets" --from-template -

echo
echo "Done. Paste this into Vikunja's Settings > Webhook Notifications > Secret field"
echo "(shown once here, stored nowhere else but Proton Pass):"
echo
echo "$SECRET"
