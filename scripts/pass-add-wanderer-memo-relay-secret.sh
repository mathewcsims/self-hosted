#!/bin/sh
# One-time setup: adds three fields to the existing "Wanderer" Proton Pass
# item, for wanderer/memo-relay/ to read at deploy time via
# scripts/pass-deploy.sh, alongside Wanderer's own secrets:
#   - WANDERER_SUPERUSER_EMAIL / WANDERER_SUPERUSER_PASSWORD — the
#     PocketBase superuser account created during Wanderer's own setup
#     (the relay uses it to authenticate the realtime subscription; you
#     were given this password once, when it was created — this re-saves
#     it if you didn't already).
#   - MEMOS_TOKEN — an Owl Memos Personal Access Token. Create it yourself
#     first in Owl's own UI (Settings -> Access Tokens -> create), then
#     paste it here when prompted.
#
# Deliberately NOT run by the agent, and deliberately not agent-visible
# even transiently — this script only ever handles values you paste into
# your own terminal.
#
# Usage:
#   ./scripts/pass-add-wanderer-memo-relay-secret.sh
set -eu

printf 'PocketBase superuser email [admin@wanderer.local]: '
read -r WANDERER_SUPERUSER_EMAIL
WANDERER_SUPERUSER_EMAIL="${WANDERER_SUPERUSER_EMAIL:-admin@wanderer.local}"

printf 'PocketBase superuser password: '
stty -echo
read -r WANDERER_SUPERUSER_PASSWORD
stty echo
echo

printf 'Owl Memos Personal Access Token (memos_pat_...): '
stty -echo
read -r MEMOS_TOKEN
stty echo
echo

if [ -z "$WANDERER_SUPERUSER_PASSWORD" ] || [ -z "$MEMOS_TOKEN" ]; then
    echo "Missing a required value — aborting." >&2
    exit 1
fi

pass-cli item update --vault-name "Self-Hosted Secrets" --item-title "Wanderer" \
    --field "WANDERER_SUPERUSER_EMAIL=$WANDERER_SUPERUSER_EMAIL" \
    --field "WANDERER_SUPERUSER_PASSWORD=$WANDERER_SUPERUSER_PASSWORD" \
    --field "MEMOS_TOKEN=$MEMOS_TOKEN"

echo "Done. WANDERER_SUPERUSER_EMAIL, WANDERER_SUPERUSER_PASSWORD, and"
echo "MEMOS_TOKEN added to the \"Wanderer\" Proton Pass item."
