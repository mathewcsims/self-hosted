#!/bin/sh
# One-time setup: generates the shared secret that authenticates Donetick's
# webhooks to donetick-webhook-relay, and stores it as a new Proton Pass
# item, "DonetickWebhookRelay".
#
# The item title must be exactly "DonetickWebhookRelay" — the deploy scripts
# derive it from the app-dir name (kebab -> PascalCase), so
# `donetick-webhook-relay` resolves to `DonetickWebhookRelay`. Renaming
# either side breaks the lookup silently.
#
# Deliberately NOT run by the agent — pass-cli agent PATs are read-only by
# design, so item creation happens under your own personal pass-cli session.
#
# ── WHY THIS SECRET CARRIES MORE WEIGHT THAN THE VIKUNJA ONE ──────────────
# The Vikunja relay's WEBHOOK_SECRET keys an HMAC: Vikunja signs each
# request body and the relay verifies the signature, so the secret never
# travels. DONETICK DOES NOT SIGN ANYTHING — it sends a bare JSON POST. The
# only way to authenticate it is to put the secret IN THE URL
# (/hook/<secret>), which means it travels on every request and lands in
# logs far more readily.
#
# Hence: 64 hex characters, and the Caddy site in front is LAN/tailnet-gated
# as a genuine second control rather than a formality. Rotating it means
# updating BOTH this item and Donetick's circle webhook_url.
#
# Usage:
#   ./scripts/pass-create-donetick-relay-secret.sh
set -eu

WEBHOOK_SECRET=$(openssl rand -hex 32)

printf '{"title":"DonetickWebhookRelay","note":"self-hosted repo secrets — see ~/self-hosted/donetick-webhook-relay/ (runs on the Pi). This value also forms part of Donetick'"'"'s circle webhook_url.","sections":[{"section_name":"Secrets","fields":[{"field_name":"WEBHOOK_SECRET","field_type":"hidden","value":"%s"}]}]}' \
    "$WEBHOOK_SECRET" \
    | pass-cli item create custom --vault-name "Self-Hosted Secrets" --from-template -

echo
echo "Done. \"DonetickWebhookRelay\" item created in Proton Pass with"
echo "WEBHOOK_SECRET (64 hex characters) — nothing printed here, the value"
echo "went straight from openssl into Pass."
