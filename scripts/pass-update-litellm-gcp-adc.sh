#!/bin/sh
# Refresh the GCP ADC credential stored in the "LiteLLM" Pass item — for
# when the org's session policy revokes the refresh token inside it and
# GEAP transcription starts failing with auth errors. Run under your own
# pass-cli session (agent PATs are read-only and can't update items):
#
#   gcloud auth application-default login
#   gcloud auth application-default set-quota-project prj-d-ada-vtxai-svpc-13kf
#   ./scripts/pass-update-litellm-gcp-adc.sh
#   ./scripts/pass-deploy-litellm.sh    # rewrites the mounted file + restarts
#
# NOTE: `pass-cli item update --field` writes into the item's top-level
# `extra_fields` array rather than updating the sectioned field in place
# (confirmed live during earlier Pass work — see pass-deploy.sh). That's
# fine here: pass-deploy-litellm.sh reads extra_fields AFTER sections, so
# the newest value wins.
#
# Usage:
#   ./scripts/pass-update-litellm-gcp-adc.sh [path-to-adc-json]
set -eu

ADC_DEFAULT="$HOME/.config/gcloud/application_default_credentials.json"
ADC_FILE="${1:-$ADC_DEFAULT}"

if [ ! -f "$ADC_FILE" ]; then
    echo "Not found: $ADC_FILE" >&2
    echo "Run 'gcloud auth application-default login' first." >&2
    exit 1
fi
if ! grep -Eq '"type": *"(authorized_user|service_account)"' "$ADC_FILE"; then
    echo "$ADC_FILE doesn't look like a Google credential file" >&2
    exit 1
fi

GCP_CREDENTIALS_B64=$(base64 -i "$ADC_FILE" | tr -d '\n')

pass-cli item update --vault-name "Self-Hosted Secrets" --item-title "LiteLLM" \
    --field "GCP_CREDENTIALS_B64=$GCP_CREDENTIALS_B64"

echo "Stored ADC credential refreshed. Now run ./scripts/pass-deploy-litellm.sh"
echo "to rewrite the mounted file and restart the gateway."
