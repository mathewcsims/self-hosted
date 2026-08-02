#!/bin/sh
# One-time setup: generates LiteLLM's secrets and stores them as a new Proton
# Pass item, "Litellm", for litellm/ to read at deploy time via
# scripts/pass-deploy-remote.sh.
#
# The item title must be exactly "Litellm" — pass-deploy-remote.sh derives it
# from the app-dir name (kebab -> PascalCase), so `litellm` resolves to
# `Litellm`, NOT `LiteLLM`. Deliberately not "prettified": renaming either
# side breaks the lookup silently.
#
# Deliberately NOT run by the agent — pass-cli agent PATs are read-only by
# design, so item creation has to happen under your own personal pass-cli
# session, same as every other pass-create-*-secrets.sh here.
#
# All three generated values are created INSIDE this script and go straight
# into Pass — never typed, never printed, never in argv or a file on disk.
#
# WHAT EACH FIELD IS:
#
#   POSTGRES_PASSWORD   Database password. Alphanumeric only (/+= stripped) —
#                       it ends up inside DATABASE_URL, and punctuation in a
#                       credential that becomes part of a URL reliably breaks
#                       whichever layer parses it.
#                       IMPORTANT: baked into the Postgres data directory on
#                       first `up`. Changing it in Pass later will NOT change
#                       the database's real password — the app will simply
#                       fail to authenticate. Rotating properly means an
#                       ALTER USER inside the running database too.
#
#   LITELLM_MASTER_KEY  Admin key for the proxy. This is what mints the
#                       per-device virtual keys — it is NOT the key you put
#                       on a phone. Treat it like a root password. Prefixed
#                       `sk-` because LiteLLM and most OpenAI-compatible
#                       clients expect that shape.
#
#   LITELLM_SALT_KEY    Encrypts provider credentials at rest in Postgres.
#                       Upstream is explicit that this is set ONCE and NEVER
#                       rotated — changing it after models are stored makes
#                       every stored credential undecryptable. There is no
#                       recovery path short of wiping the database.
#
# NOT generated here, because they are not secrets and not generatable:
#   VERTEXAI_PROJECT / VERTEXAI_LOCATION — your GCP project ID and region.
#   Add them to the same Pass item by hand after running this; the deploy
#   script exports every field in the item, so they are picked up the same
#   way. See SETUP.md for how to find them.
#
# Usage:
#   ./scripts/pass-create-litellm-secrets.sh
set -eu

POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-32)
LITELLM_MASTER_KEY="sk-$(openssl rand -base64 36 | tr -d '/+=' | cut -c1-40)"
LITELLM_SALT_KEY=$(openssl rand -base64 36 | tr -d '/+=' | cut -c1-40)

printf '{"title":"Litellm","note":"self-hosted repo secrets — see ~/self-hosted/litellm/ (runs on slartibartfast, tailnet-only). Add VERTEXAI_PROJECT and VERTEXAI_LOCATION to this item by hand — see SETUP.md. LITELLM_SALT_KEY must never be changed once models are stored.","sections":[{"section_name":"Secrets","fields":[{"field_name":"POSTGRES_PASSWORD","field_type":"hidden","value":"%s"},{"field_name":"LITELLM_MASTER_KEY","field_type":"hidden","value":"%s"},{"field_name":"LITELLM_SALT_KEY","field_type":"hidden","value":"%s"}]}]}' \
    "$POSTGRES_PASSWORD" "$LITELLM_MASTER_KEY" "$LITELLM_SALT_KEY" \
    | pass-cli item create custom --vault-name "Self-Hosted Secrets" --from-template -

echo
echo "Done. \"Litellm\" item created in Proton Pass with POSTGRES_PASSWORD,"
echo "LITELLM_MASTER_KEY and LITELLM_SALT_KEY — nothing printed here, the"
echo "values went straight from openssl into Pass."
echo
echo "STILL TO DO, by hand, in the same item:"
echo "  VERTEXAI_PROJECT   your GCP project ID   (gcloud config get-value project)"
echo "  VERTEXAI_LOCATION  the region, e.g. europe-west2 or us-central1"
