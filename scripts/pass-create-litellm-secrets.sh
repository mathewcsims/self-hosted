#!/bin/sh
# One-time setup: generates LiteLLM's secrets and stores them as a new
# Proton Pass item, "LiteLLM", for litellm/ to read at deploy time via
# scripts/pass-deploy-litellm.sh.
#
# Deliberately NOT run by the agent — pass-cli agent PATs are read-only by
# design, so item creation has to happen under your own personal pass-cli
# session, same as every other pass-create-*-secrets.sh here.
#
# The GCP credential: the org blocks service-account key creation
# (constraints/iam.disableServiceAccountKeyCreation — confirmed live in
# the console, greyed-out "create new key"), so this uses your user-level
# Application Default Credentials instead. Run these first:
#
#   gcloud auth application-default login
#   gcloud auth application-default set-quota-project prj-d-ada-vtxai-svpc-13kf
#
# then run this script with no argument — it reads gcloud's ADC file from
# its standard path and base64-encodes it into the Pass item. The source
# file is left in place (it's gcloud's own state, not a downloaded
# artifact). If your org's session policy later revokes the refresh token
# inside it, re-run the two gcloud commands then
# scripts/pass-update-litellm-gcp-adc.sh to refresh the stored copy.
#
# LITELLM_SALT_KEY encrypts provider credentials stored in LiteLLM's DB
# and MUST NEVER change once set — rotating it orphans everything already
# encrypted with it (same class as Wanderer's POCKETBASE_ENCRYPTION_KEY).
#
# Usage:
#   ./scripts/pass-create-litellm-secrets.sh [path-to-adc-json]
set -eu

ADC_DEFAULT="$HOME/.config/gcloud/application_default_credentials.json"
ADC_FILE="${1:-$ADC_DEFAULT}"

if [ ! -f "$ADC_FILE" ]; then
    echo "Not found: $ADC_FILE" >&2
    echo "Run 'gcloud auth application-default login' first (see header)." >&2
    exit 1
fi
# Accept either credential shape Google's client libraries understand —
# authorized_user (the gcloud ADC flow, what the org policy leaves us) or
# service_account (in case a key ever becomes possible).
if ! grep -Eq '"type": *"(authorized_user|service_account)"' "$ADC_FILE"; then
    echo "$ADC_FILE doesn't look like a Google credential file" >&2
    echo '(expected "type": "authorized_user" or "service_account")' >&2
    exit 1
fi
if ! grep -q '"quota_project_id"' "$ADC_FILE"; then
    echo "WARNING: no quota_project_id in $ADC_FILE — GEAP calls may be" >&2
    echo "rejected. Run: gcloud auth application-default set-quota-project" >&2
    echo "prj-d-ada-vtxai-svpc-13kf and re-run this script." >&2
fi

# sk- prefix: LiteLLM requires the master key to start with "sk-".
LITELLM_MASTER_KEY="sk-$(openssl rand -hex 24)"
LITELLM_SALT_KEY="sk-$(openssl rand -hex 24)"
LITELLM_PG_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=')
UI_USERNAME="mat"
UI_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=')
GCP_CREDENTIALS_B64=$(base64 -i "$ADC_FILE" | tr -d '\n')

printf '{"title":"LiteLLM","note":"self-hosted repo secrets — see ~/self-hosted/litellm/","sections":[{"section_name":"Secrets","fields":[{"field_name":"LITELLM_MASTER_KEY","field_type":"hidden","value":"%s"},{"field_name":"LITELLM_SALT_KEY","field_type":"hidden","value":"%s"},{"field_name":"LITELLM_PG_PASSWORD","field_type":"hidden","value":"%s"},{"field_name":"UI_USERNAME","field_type":"text","value":"%s"},{"field_name":"UI_PASSWORD","field_type":"hidden","value":"%s"},{"field_name":"GCP_CREDENTIALS_B64","field_type":"hidden","value":"%s"}]}]}' \
    "$LITELLM_MASTER_KEY" "$LITELLM_SALT_KEY" "$LITELLM_PG_PASSWORD" "$UI_USERNAME" "$UI_PASSWORD" "$GCP_CREDENTIALS_B64" \
    | pass-cli item create custom --vault-name "Self-Hosted Secrets" --from-template -

echo
echo "Done. \"LiteLLM\" item created in Proton Pass (master key, salt key,"
echo "Postgres password, UI credentials, base64'd ADC credential). Nothing"
echo "was printed here; generated values went straight into Pass."
