#!/bin/sh
# One-time setup: creates the "Pads" Proton Pass item for the Etherpad
# instance at pads.mathewcsims.uk (see ../pads/).
#
# Generates the admin password and its bcrypt hash. Both are stored: the hash
# is what settings.json needs (substituted in as ${PADS_ADMIN_HASH} at deploy
# time), and the plaintext is what you actually type at the login prompt, so
# it has to live somewhere you can get it back from.
#
# ── The bcrypt prefix gotcha, verified the hard way ───────────────────────
# ep_hash_auth verifies with node's `bcrypt`, which does NOT understand the
# `$2y$` prefix that htpasswd emits — it returns false for every password,
# with no error and no log line, so the account simply never authenticates.
# `$2y$` and `$2a$` are the same algorithm (the prefix is a historical PHP
# compatibility marker), so rewriting it is safe and is what the sed below
# does. Confirmed against the bcrypt build inside the pads image:
#   $2y$ -> false, $2a$ -> true for the same password and cost.
#
# Alphanumeric-only password, deliberately: it travels through compose's
# ${VAR} interpolation into Etherpad's settings.json, and punctuation in that
# path is a known class of bug across this repo (see the BookStack script).
#
# Usage:
#   ./scripts/pass-create-pads-secrets.sh
set -eu

command -v htpasswd >/dev/null || { echo "htpasswd not found (expected at /usr/sbin/htpasswd)" >&2; exit 1; }

ADMIN_PASSWORD=$(python3 -c 'import secrets,string; print("".join(secrets.choice(string.ascii_letters+string.digits) for _ in range(32)))')
# -B bcrypt, -C 12 cost, -n write to stdout, then strip the "user:" prefix and
# rewrite $2y$ -> $2a$ (see the note above).
ADMIN_HASH=$(htpasswd -bnBC 12 x "$ADMIN_PASSWORD" | cut -d: -f2 | sed 's/^\$2y\$/\$2a\$/')

case "$ADMIN_HASH" in
    '$2a$'*) ;;
    *) echo "unexpected hash format: ${ADMIN_HASH%%\$*}... aborting" >&2; exit 1 ;;
esac

python3 -c '
import json, sys

admin_password, admin_hash = sys.argv[1], sys.argv[2]

template = {
    "title": "Pads",
    "note": "personal Etherpad — see ~/self-hosted/pads/. LAN/tailnet-only at https://pads.mathewcsims.uk. Username: mathew. PADS_ADMIN_HASH is the bcrypt hash settings.json substitutes in; PADS_ADMIN_PASSWORD is what you type at the login prompt.",
    "sections": [{
        "section_name": "Secrets",
        "fields": [
            {"field_name": "PADS_ADMIN_HASH", "field_type": "hidden", "value": admin_hash},
            {"field_name": "PADS_ADMIN_PASSWORD", "field_type": "hidden", "value": admin_password},
        ],
    }],
}
json.dump(template, sys.stdout)
' "$ADMIN_PASSWORD" "$ADMIN_HASH" \
    | pass-cli item create custom --vault-name "Self-Hosted Secrets" --from-template - >/dev/null
# Output suppressed: `item create` echoes the created item back, including the
# secret values just generated above — the same trap the BookStack script
# documents. Never let this command's stdout reach a terminal or log.

echo "Done. Verify with:"
echo "  pass-cli item view --vault-name \"Self-Hosted Secrets\" --item-title \"Pads\""
echo
echo "Then deploy:  ./scripts/pass-deploy.sh pads"
