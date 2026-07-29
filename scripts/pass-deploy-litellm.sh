#!/bin/sh
# Deploy LiteLLM with its secrets fetched live from Proton Pass — mostly
# the same shape as the generic pass-deploy.sh, plus one extra step the
# generic script can't do: the GCP service-account credential is a whole
# JSON *file*, not an env var, so it's stored base64-encoded in the Pass
# item (GCP_CREDENTIALS_B64) and decoded to litellm/gcp-credentials.json
# (0600, gitignored) before compose runs. Written every deploy, so a
# rotated key in Pass takes effect on the next run with no extra step.
#
# Why not a Pass file attachment: pass-cli's agent surface is
# download-only for attachments (no upload subcommand exists — checked,
# not assumed), so a field the tooling can both read AND write end-to-end
# beats an attachment only a human can create. Same base64-in-a-field
# recipe as the Memos logo data-URIs.
#
# Usage:
#   ./scripts/pass-deploy-litellm.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
LITELLM_DIR="$REPO_ROOT/litellm"

export PROTON_PASS_SESSION_DIR="${PROTON_PASS_SESSION_DIR:-/tmp/pass-agent-selfhosted}"
mkdir -p "$PROTON_PASS_SESSION_DIR"

if ! pass-cli info >/dev/null 2>&1; then
    if [ ! -f "$REPO_ROOT/.env" ]; then
        echo "No active pass-cli session, and no $REPO_ROOT/.env to auto-login with." >&2
        exit 1
    fi
    echo "No active pass-cli session — logging in with SECRET_ACCESS_TOKEN from .env..."
    set -a
    . "$REPO_ROOT/.env"
    set +a
    export PROTON_PASS_PERSONAL_ACCESS_TOKEN="$SECRET_ACCESS_TOKEN"
    pass-cli login >/dev/null
    unset PROTON_PASS_PERSONAL_ACCESS_TOKEN SECRET_ACCESS_TOKEN
fi

echo "Fetching secrets for \"LiteLLM\" from Proton Pass..."

EXPORTS=$(PROTON_PASS_AGENT_REASON="Fetching secrets to deploy litellm" \
    pass-cli item view --vault-name "Self-Hosted Secrets" --item-title "LiteLLM" --output json \
    | python3 -c '
import json, sys, shlex

d = json.load(sys.stdin)
content = d["item"]["content"]
sections = content["content"]["Custom"]["sections"]
fields = [f for section in sections for f in section["section_fields"]]
# `pass-cli item update --field x=y` writes into a separate top-level
# `extra_fields` array, not into any section — confirmed live. See
# pass-deploy.sh for the same fix and full explanation.
fields += content.get("extra_fields", [])
for f in fields:
    name = f["name"]
    value = list(f["content"].values())[0]
    print(f"export {name}={shlex.quote(value)}")
')

eval "$EXPORTS"

# Decode the GCP service-account key to the (gitignored) path compose.yaml
# mounts. umask first so the file is never world-readable, even briefly.
umask 077
printf '%s' "$GCP_CREDENTIALS_B64" | base64 -d > "$LITELLM_DIR/gcp-credentials.json"
unset GCP_CREDENTIALS_B64

cd "$LITELLM_DIR"
podman compose up -d
# Google's client libraries cache credentials in memory after first use,
# so a refreshed ADC file isn't picked up by a running container. The
# gateway is stateless (all state is in Postgres) — always restart it so
# a credential refresh via pass-update-litellm-gcp-adc.sh actually lands.
podman compose restart litellm
