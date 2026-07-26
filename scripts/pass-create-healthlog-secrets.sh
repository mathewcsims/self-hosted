#!/bin/sh
# One-time setup: generates HealthLog's three required secrets
# (POSTGRES_PASSWORD, ENCRYPTION_KEY, API_TOKEN_HMAC_KEY — all 32-byte hex,
# per HealthLog's own .env.example) and stores them as a new Proton Pass
# item, "HealthLog", for healthlog/ to read at deploy time via
# scripts/pass-deploy.sh, same as every other app in this repo.
#
# Deliberately NOT run by the agent — pass-cli agent PATs are read-only by
# design, so item creation has to happen under your own personal pass-cli
# session, not the agent one used elsewhere in this repo's tooling.
#
# Secrets are generated INSIDE this script and go straight into Pass —
# never typed, never printed, never touch argv or a file on disk.
#
# Usage:
#   ./scripts/pass-create-healthlog-secrets.sh
set -eu

POSTGRES_PASSWORD=$(openssl rand -hex 32)
ENCRYPTION_KEY=$(openssl rand -hex 32)
API_TOKEN_HMAC_KEY=$(openssl rand -hex 32)

printf '{"title":"HealthLog","note":"self-hosted repo secrets — see ~/self-hosted/healthlog/","sections":[{"section_name":"Secrets","fields":[{"field_name":"POSTGRES_PASSWORD","field_type":"hidden","value":"%s"},{"field_name":"ENCRYPTION_KEY","field_type":"hidden","value":"%s"},{"field_name":"API_TOKEN_HMAC_KEY","field_type":"hidden","value":"%s"}]}]}' \
    "$POSTGRES_PASSWORD" "$ENCRYPTION_KEY" "$API_TOKEN_HMAC_KEY" \
    | pass-cli item create custom --vault-name "Self-Hosted Secrets" --from-template -

echo
echo "Done. \"HealthLog\" item created in Proton Pass with POSTGRES_PASSWORD,"
echo "ENCRYPTION_KEY, and API_TOKEN_HMAC_KEY — nothing printed here, values"
echo "went straight from openssl into Pass."
