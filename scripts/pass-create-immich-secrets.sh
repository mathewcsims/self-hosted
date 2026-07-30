#!/bin/sh
# One-time setup: generates Immich's DB password and stores it as a new
# Proton Pass item, "Immich", for immich/ to read at deploy time via
# scripts/pass-deploy-remote.sh.
#
# The item title must be exactly "Immich" — pass-deploy-remote.sh derives
# the item title from the app-dir name (kebab -> PascalCase), so `immich`
# resolves to `Immich`. Renaming either side breaks the lookup silently.
#
# Deliberately NOT run by the agent — pass-cli agent PATs are read-only by
# design, so item creation has to happen under your own personal pass-cli
# session, same as every other pass-create-*-secrets.sh here.
#
# The password is generated INSIDE this script and goes straight into Pass —
# never typed, never printed, never touches argv or a file on disk.
#
# Alphanumeric only (/+= stripped): Postgres passwords containing those
# characters have a habit of breaking whichever layer decides to treat the
# credential as part of a URL, and nothing here needs the extra entropy
# that punctuation would buy.
#
# IMPORTANT: this password is baked into the Postgres data directory on
# first `up` (it's what POSTGRES_PASSWORD initialises the cluster with).
# Changing it in Pass later will NOT change the database's actual password —
# the app will simply fail to authenticate. Rotating it properly means
# ALTER USER inside the running database as well.
#
# Usage:
#   ./scripts/pass-create-immich-secrets.sh
set -eu

DB_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-32)

printf '{"title":"Immich","note":"self-hosted repo secrets — see ~/self-hosted/immich/ (runs on slartibartfast)","sections":[{"section_name":"Secrets","fields":[{"field_name":"DB_PASSWORD","field_type":"hidden","value":"%s"}]}]}' \
    "$DB_PASSWORD" \
    | pass-cli item create custom --vault-name "Self-Hosted Secrets" --from-template -

echo
echo "Done. \"Immich\" item created in Proton Pass with DB_PASSWORD —"
echo "nothing printed here, the value went straight from openssl into Pass."
