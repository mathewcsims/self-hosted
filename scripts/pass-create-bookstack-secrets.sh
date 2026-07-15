#!/bin/sh
# One-time setup: creates the "BookStack" Proton Pass item. Generates
# APP_KEY (Laravel's session/cookie encryption key — same base64: format
# BookStack's own `artisan key:generate` produces) and two DB passwords.
# Alphanumeric-only passwords deliberately: BookStack/MariaDB's own docs
# warn that non-alphanumeric characters in DB_PASSWORD need careful
# escaping through docker-compose's env-var interpolation, so this avoids
# that whole class of bug rather than working around it.
#
# No admin credentials here — BookStack ships a fixed, publicly-documented
# default (admin@admin.com/password) with no supported env-var override,
# so that has to be changed once, manually, through the app's own Edit
# Profile screen (see SETUP.md) rather than pre-seeded.
#
# Usage:
#   ./scripts/pass-create-bookstack-secrets.sh
set -eu

APP_KEY="base64:$(openssl rand -base64 32)"
DB_ROOT_PASSWORD=$(python3 -c 'import secrets,string; print("".join(secrets.choice(string.ascii_letters+string.digits) for _ in range(32)))')
DB_PASSWORD=$(python3 -c 'import secrets,string; print("".join(secrets.choice(string.ascii_letters+string.digits) for _ in range(32)))')

python3 -c '
import json, sys

app_key, db_root_password, db_password = sys.argv[1], sys.argv[2], sys.argv[3]

template = {
    "title": "BookStack",
    "note": "self-hosted project wiki — see ~/self-hosted/bookstack/. LAN-only at https://author.mathewcsims.uk.",
    "sections": [{
        "section_name": "Secrets",
        "fields": [
            {"field_name": "APP_KEY", "field_type": "hidden", "value": app_key},
            {"field_name": "DB_ROOT_PASSWORD", "field_type": "hidden", "value": db_root_password},
            {"field_name": "DB_PASSWORD", "field_type": "hidden", "value": db_password},
        ],
    }],
}
json.dump(template, sys.stdout)
' "$APP_KEY" "$DB_ROOT_PASSWORD" "$DB_PASSWORD" \
    | pass-cli item create custom --vault-name "Self-Hosted Secrets" --from-template - >/dev/null
# Output suppressed: `item create` echoes the created item back, including
# the secret values just generated above — see pass-create-timetagger-
# secrets.sh for how this was found out the hard way.

echo "Done. Verify with:"
echo "  pass-cli item view --vault-name \"Self-Hosted Secrets\" --item-title \"BookStack\""
