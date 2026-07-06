#!/bin/sh
# One-time setup: generates the three Kopia-related secrets and stores them
# in a single new Proton Pass item, "Kopia". No values are typed or passed
# as arguments — everything here is generated inside this script, under
# your own personal pass-cli session (agent tokens are read-only, can't
# create items).
#
# Fields created:
#   REPOSITORY_PASSWORD  — the actual encryption key for every snapshot in
#                           the shared B2 repository. Losing this makes the
#                           whole backup unrecoverable; leaking it exposes
#                           every backed-up file. Never displayed again
#                           after this run — Pass is the only copy.
#   SERVER_CONTROL_PASSWORD — used for `kopia server refresh`/admin control
#                           commands against the Pi's kopia server.
#   WEBUI_PASSWORD        — your login password for the Kopia web UI
#                           (paired with a username you'll set when adding
#                           the server user, e.g. `kopia server user add
#                           mat@webui`).
#
# Usage:
#   ./scripts/pass-create-kopia-secrets.sh
set -eu

REPOSITORY_PASSWORD=$(openssl rand -base64 32)
SERVER_CONTROL_PASSWORD=$(openssl rand -base64 24)
WEBUI_PASSWORD=$(openssl rand -base64 18)

python3 -c '
import json, sys

repo_pw, control_pw, webui_pw = sys.argv[1], sys.argv[2], sys.argv[3]

template = {
    "title": "Kopia",
    "note": "self-hosted repo backup system — see ~/self-hosted/kopia-server/ and ~/self-hosted/kopia-mac/",
    "sections": [{
        "section_name": "Secrets",
        "fields": [
            {"field_name": "REPOSITORY_PASSWORD", "field_type": "hidden", "value": repo_pw},
            {"field_name": "SERVER_CONTROL_PASSWORD", "field_type": "hidden", "value": control_pw},
            {"field_name": "WEBUI_PASSWORD", "field_type": "hidden", "value": webui_pw},
        ],
    }],
}
json.dump(template, sys.stdout)
' "$REPOSITORY_PASSWORD" "$SERVER_CONTROL_PASSWORD" "$WEBUI_PASSWORD" \
    | pass-cli item create custom --vault-name "Self-Hosted Secrets" --from-template - >/dev/null
# Output suppressed: `item create` echoes the created item back, including
# the secret values just generated above. Never let this command's stdout
# reach a terminal/log unredirected.

echo "Done. Verify with:"
echo "  pass-cli item view --vault-name \"Self-Hosted Secrets\" --item-title \"Kopia\""
