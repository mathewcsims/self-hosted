#!/bin/sh
# One-time setup: generates Wanderer's four required secrets
# (MEILI_MASTER_KEY, POCKETBASE_ENCRYPTION_KEY — must stay fixed forever
# once real data exists, UPLOAD_USER, UPLOAD_PASSWORD) and stores them as
# a new Proton Pass item, "Wanderer", for wanderer/ to read at deploy time
# via scripts/pass-deploy.sh, same as every other app in this repo.
#
# Deliberately NOT run by the agent — pass-cli agent PATs are read-only by
# design, so item creation has to happen under your own personal pass-cli
# session, not the agent one used elsewhere in this repo's tooling.
#
# Secrets are generated INSIDE this script and go straight into Pass —
# never typed, never printed, never touch argv or a file on disk.
#
# Usage:
#   ./scripts/pass-create-wanderer-secrets.sh
set -eu

MEILI_MASTER_KEY=$(openssl rand -hex 32)
# Must be exactly 32 hex chars per Wanderer's own docs — do not change this
# generation method once the db has real data; rotating it breaks
# decryption of existing records.
POCKETBASE_ENCRYPTION_KEY=$(openssl rand -hex 16)
UPLOAD_USER="wanderer-uploads"
UPLOAD_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=')

printf '{"title":"Wanderer","note":"self-hosted repo secrets — see ~/self-hosted/wanderer/","sections":[{"section_name":"Secrets","fields":[{"field_name":"MEILI_MASTER_KEY","field_type":"hidden","value":"%s"},{"field_name":"POCKETBASE_ENCRYPTION_KEY","field_type":"hidden","value":"%s"},{"field_name":"UPLOAD_USER","field_type":"text","value":"%s"},{"field_name":"UPLOAD_PASSWORD","field_type":"hidden","value":"%s"}]}]}' \
    "$MEILI_MASTER_KEY" "$POCKETBASE_ENCRYPTION_KEY" "$UPLOAD_USER" "$UPLOAD_PASSWORD" \
    | pass-cli item create custom --vault-name "Self-Hosted Secrets" --from-template -

echo
echo "Done. \"Wanderer\" item created in Proton Pass with MEILI_MASTER_KEY,"
echo "POCKETBASE_ENCRYPTION_KEY, UPLOAD_USER, and UPLOAD_PASSWORD — nothing"
echo "printed here, values went straight from openssl into Pass."
