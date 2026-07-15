#!/bin/sh
# One-time setup: creates the "Forgejo" Proton Pass item, holding just the
# generated admin password. Everything else Forgejo needs (SQLite, no
# separate DB) has no secrets of its own — the admin account itself is
# created via the `forgejo admin user create` CLI (see SETUP.md), not a
# web-form/default-credential step, so this is the only value worth
# storing.
#
# Usage:
#   ./scripts/pass-create-forgejo-secrets.sh
set -eu

ADMIN_PASSWORD=$(python3 -c 'import secrets,string; print("".join(secrets.choice(string.ascii_letters+string.digits) for _ in range(32)))')

python3 -c '
import json, sys

password = sys.argv[1]

template = {
    "title": "Forgejo",
    "note": "self-hosted git remote + web UI — see ~/self-hosted/forgejo/. LAN-only at https://fj.mathewcsims.uk. Username: mathew.",
    "sections": [{
        "section_name": "Secrets",
        "fields": [
            {"field_name": "ADMIN_USERNAME", "field_type": "text", "value": "mathew"},
            {"field_name": "ADMIN_PASSWORD", "field_type": "hidden", "value": password},
        ],
    }],
}
json.dump(template, sys.stdout)
' "$ADMIN_PASSWORD" \
    | pass-cli item create custom --vault-name "Self-Hosted Secrets" --from-template - >/dev/null
# Output suppressed: `item create` echoes the created item back, including
# the password just generated above.

echo "Done. Verify with:"
echo "  pass-cli item view --vault-name \"Self-Hosted Secrets\" --item-title \"Forgejo\""
