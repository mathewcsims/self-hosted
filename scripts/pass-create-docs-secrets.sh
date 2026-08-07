#!/bin/sh
# One-time setup: generates the Postgres password for the HedgeDoc instance at
# docs.mathewcsims.uk (see ../docs/) and stores it as a new Proton Pass item,
# "Docs", for docs/ to read at deploy time via scripts/pass-deploy.sh — same
# pattern as every other app in this repo.
#
# Deliberately NOT run by the agent — pass-cli agent PATs are read-only by
# design, so item creation has to happen under your own personal pass-cli
# session, not the agent one used elsewhere in this repo's tooling.
#
# The secret is generated INSIDE this script and goes straight into Pass —
# never typed, never printed, never touches argv or a file on disk.
#
# Hex rather than mixed alphanumeric: it travels through compose's ${VAR}
# interpolation into both POSTGRES_PASSWORD and a postgres:// connection
# string, and hex avoids both the shell-quoting and the URL-encoding classes
# of bug in one go.
#
# Usage:
#   ./scripts/pass-create-docs-secrets.sh
set -eu

POSTGRES_PASSWORD=$(openssl rand -hex 32)

printf '{"title":"Docs","note":"HedgeDoc — personal Markdown authoring, see ~/self-hosted/docs/. LAN/tailnet-only at https://docs.mathewcsims.uk. User accounts are created with scripts/docs-add-user.sh and are NOT stored here.","sections":[{"section_name":"Secrets","fields":[{"field_name":"POSTGRES_PASSWORD","field_type":"hidden","value":"%s"}]}]}' \
    "$POSTGRES_PASSWORD" \
    | pass-cli item create custom --vault-name "Self-Hosted Secrets" --from-template - >/dev/null
# Output suppressed: `item create` echoes the created item back, including the
# secret just generated above — the same trap the BookStack script documents.
# Never let this command's stdout reach a terminal or log.

echo "Done. \"Docs\" item created in Proton Pass with POSTGRES_PASSWORD —"
echo "nothing printed here, the value went straight from openssl into Pass."
echo
echo "Verify with:"
echo "  pass-cli item view --vault-name \"Self-Hosted Secrets\" --item-title \"Docs\""
echo
echo "Then deploy:  ./scripts/pass-deploy.sh docs"
