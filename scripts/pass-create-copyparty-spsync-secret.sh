#!/bin/sh
# One-time setup: creates the "Copyparty SP Sync" Proton Pass item — the
# scoped copyparty account Super Productivity syncs to over WebDAV.
#
#   ./scripts/pass-create-copyparty-spsync-secret.sh
#
# WHY A SEPARATE ITEM RATHER THAN A NEW LINE IN THE EXISTING "Copyparty"
# ONE. The agent's Pass token is create-and-read only by design (see
# SETUP.md's agent access model) — it cannot UPDATE an item, and
# scripts/pass-import-file.sh CREATES rather than updates, so re-importing
# the existing Copyparty item to add a line would produce a second active
# item with the same title and make scripts/pass-render-file.sh fail closed.
#
# copyparty auto-loads every *.conf in /cfg, and a second [accounts] block in
# a second file MERGES with the first — verified empirically before relying
# on it (throwaway container, two config files, two accounts, each usable
# only on its own volume and 403 on the other). So this account lives in its
# own file, rendered from its own item, and the existing Copyparty item is
# never touched.
#
# The account is scoped to the /sp-sync volume only (see
# copyparty/cfg/copyparty.conf) and holds nothing but Super Productivity's
# sync blob. It is NOT the admin account and must never be given more.
set -eu

# Alphanumeric only: copyparty's config is whitespace-and-colon delimited, so
# a password containing ':' or a leading/trailing space would be misparsed
# into a broken account rather than rejected loudly.
SPSYNC_PASSWORD=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 40)
export SPSYNC_PASSWORD

python3 -c '
import json, os, sys

pw = os.environ["SPSYNC_PASSWORD"]

# The whole-file secret: rendered to copyparty/cfg/accounts-spsync.conf at
# deploy time. Only the account lives here — the volume definition itself is
# not secret and stays in the tracked copyparty.conf where it can be reviewed.
accounts_conf = "\n".join([
    "# RENDERED FROM PROTON PASS — do not edit, do not commit.",
    "# Item \"Copyparty SP Sync\", field ACCOUNTS_CONF.",
    "# Regenerate with scripts/pass-render-file.sh; see copyparty/cfg/copyparty.conf",
    "# for the /sp-sync volume this account is scoped to.",
    "",
    "[accounts]",
    "  spsync: " + pw,
    "",
])

template = {
    "title": "Copyparty SP Sync",
    "note": "scoped copyparty account for Super Productivity WebDAV sync — see ~/self-hosted/copyparty/. Access: /sp-sync volume ONLY. Username spsync. Enter USERNAME/PASSWORD into Super Productivity > Sync > WebDAV at https://sp.mathewcsims.uk/sp-sync/",
    "sections": [{
        "section_name": "Secrets",
        "fields": [
            {"field_name": "USERNAME", "field_type": "text", "value": "spsync"},
            {"field_name": "PASSWORD", "field_type": "hidden", "value": pw},
            {"field_name": "ACCOUNTS_CONF", "field_type": "hidden", "value": accounts_conf},
        ],
    }],
}
json.dump(template, sys.stdout)
' | pass-cli item create custom --vault-name "Self-Hosted Secrets" --from-template - >/dev/null
# Output suppressed: `item create` echoes the created item back, secrets included.

unset SPSYNC_PASSWORD

echo "Done. Verify with:"
echo "  pass-cli item view --vault-name \"Self-Hosted Secrets\" --item-title \"Copyparty SP Sync\""
