#!/bin/sh
# One-time setup: creates the "Paperless" Proton Pass item for the personal
# document store (see ~/self-hosted/paperless/).
#
# Two kinds of field, handled two different ways:
#
#   GENERATED — PAPERLESS_SECRET_KEY (Django's signing key) and the admin
#   password. Never typed, never seen, never in shell history.
#
#   PROMPTED — the admin username/email, and the NAS SMB credentials. These
#   describe accounts that already exist elsewhere, so they have to be
#   entered. Read interactively, exactly like
#   pass-import-nas-credentials.sh: nothing is passed as a script argument,
#   so no value ever reaches a Bash command line, a file, or a chat message.
#
# On the NAS credentials specifically: use a DEDICATED NAS account scoped to
# the `paperless` share only. Not `hog-user`, which can also reach
# magrathea/Archive/Public/ProtonDriveBackup, and not `admin`. This password
# ends up as an environment variable on a CIFS mount inside the podman VM —
# it should be able to do as little as possible if it ever leaks.
#
# Run this under your own personal pass-cli session (agent tokens are
# read-only, can't create items).
#
# Usage:
#   ./scripts/pass-create-paperless-secrets.sh
set -eu

PAPERLESS_SECRET_KEY=$(openssl rand -base64 48 | tr -d '\n')
# Alphanumeric-only, same reasoning as the BookStack script: this value goes
# through podman-compose's ${VAR} interpolation, and punctuation in an
# interpolated password is a whole class of escaping bug not worth inviting.
PAPERLESS_ADMIN_PASSWORD=$(python3 -c 'import secrets,string; print("".join(secrets.choice(string.ascii_letters+string.digits) for _ in range(32)))')

printf 'Paperless admin username: '
read -r PAPERLESS_ADMIN_USER

printf 'Paperless admin email: '
read -r PAPERLESS_ADMIN_MAIL

printf 'NAS username (dedicated paperless-share account, NOT hog-user/admin): '
read -r NAS_USER

printf 'NAS password (hidden): '
stty -echo
read -r NAS_PASSWORD
stty echo
printf '\n'

{
    printf '%s\n' "$PAPERLESS_SECRET_KEY"
    printf '%s\n' "$PAPERLESS_ADMIN_USER"
    printf '%s\n' "$PAPERLESS_ADMIN_PASSWORD"
    printf '%s\n' "$PAPERLESS_ADMIN_MAIL"
    printf '%s\n' "$NAS_USER"
    printf '%s\n' "$NAS_PASSWORD"
} | python3 -c '
import json, sys

secret_key = sys.stdin.readline().rstrip("\n")
admin_user = sys.stdin.readline().rstrip("\n")
admin_password = sys.stdin.readline().rstrip("\n")
admin_mail = sys.stdin.readline().rstrip("\n")
nas_user = sys.stdin.readline().rstrip("\n")
nas_password = sys.stdin.readline().rstrip("\n")

template = {
    "title": "Paperless",
    "note": (
        "personal document store (letters, medical, certificates) — see "
        "~/self-hosted/paperless/. LAN-only at https://paperless.mathewcsims.uk. "
        "NAS_USER/NAS_PASSWORD are here rather than only in the Mac Keychain "
        "because the CIFS mount is done by the kernel of the podman VM, "
        "which cannot reach the Keychain — see compose.yaml."
    ),
    "sections": [{
        "section_name": "Secrets",
        "fields": [
            {"field_name": "PAPERLESS_SECRET_KEY", "field_type": "hidden", "value": secret_key},
            {"field_name": "PAPERLESS_ADMIN_USER", "field_type": "text", "value": admin_user},
            {"field_name": "PAPERLESS_ADMIN_PASSWORD", "field_type": "hidden", "value": admin_password},
            {"field_name": "PAPERLESS_ADMIN_MAIL", "field_type": "text", "value": admin_mail},
            {"field_name": "NAS_USER", "field_type": "text", "value": nas_user},
            {"field_name": "NAS_PASSWORD", "field_type": "hidden", "value": nas_password},
        ],
    }],
}
json.dump(template, sys.stdout)
' | pass-cli item create custom --vault-name "Self-Hosted Secrets" --from-template - >/dev/null
# Output suppressed: `item create` echoes the created item back, including
# the secrets just generated above — the same lesson the BookStack script
# records, learned the hard way and then rotated. Never let this command's
# stdout reach a terminal or log unredirected.

echo "Done. Verify with:"
echo "  pass-cli item view --vault-name \"Self-Hosted Secrets\" --item-title \"Paperless\""
echo
echo "The generated admin password is in that item — read it from there to log in."
