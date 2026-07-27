#!/bin/sh
# One-time setup: generates msims.link's admin password and API key,
# Argon2-hashes both (chhoto-url verifies against a stored hash when
# CHHOTO_HASH_ALGORITHM=Argon2 — the plaintext is never stored server-
# side), and creates a new "MsimsLink" Proton Pass item holding all four
# values: the two HASHES (what compose.yaml's CHHOTO_PASSWORD/
# CHHOTO_API_KEY env vars actually need) and the two PLAINTEXT values
# (what you actually need to log in / call the API with — Pass is your
# password manager, so these belong there too, not just printed once to
# a terminal you might not have captured).
#
# Deliberately NOT run by the agent — pass-cli agent PATs are read-only
# by design, so item creation has to happen under your own personal
# pass-cli session, not the agent one used elsewhere in this repo's
# tooling.
#
# Requires the `argon2` CLI (installed via `brew install argon2` for
# this setup) — the exact hashing invocation chhoto-url's own docs
# recommend (docs/INSTALLATION.md#chhoto_hash_algorithm).
#
# Usage:
#   ./scripts/pass-create-msims-link-secrets.sh
set -eu

if ! command -v argon2 >/dev/null 2>&1; then
    echo "argon2 CLI not found — install with: brew install argon2" >&2
    exit 1
fi

ADMIN_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=')
# 64 chars, not the 128 upstream's own docs suggest — the `argon2` CLI
# itself refuses anything longer ("Provided password longer than
# supported in command line utility"), confirmed live. Still ~380 bits
# of entropy, far more than enough for a bearer token.
API_KEY=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 64)

hash_value() {
    salt=$(openssl rand -hex 16)
    printf '%s' "$1" | argon2 "$salt" -id -t 3 -m 16 -l 32 -e
}

PASSWORD_HASH=$(hash_value "$ADMIN_PASSWORD")
API_KEY_HASH=$(hash_value "$API_KEY")

printf '{"title":"MsimsLink","note":"self-hosted repo secrets — see ~/self-hosted/msims-link/","sections":[{"section_name":"Secrets","fields":[{"field_name":"CHHOTO_PASSWORD","field_type":"hidden","value":"%s"},{"field_name":"CHHOTO_API_KEY","field_type":"hidden","value":"%s"},{"field_name":"ADMIN_PASSWORD_PLAINTEXT","field_type":"hidden","value":"%s"},{"field_name":"API_KEY_PLAINTEXT","field_type":"hidden","value":"%s"}]}]}' \
    "$PASSWORD_HASH" "$API_KEY_HASH" "$ADMIN_PASSWORD" "$API_KEY" \
    | pass-cli item create custom --vault-name "Self-Hosted Secrets" --from-template -

echo
echo "Done. \"MsimsLink\" item created in Proton Pass with:"
echo "  CHHOTO_PASSWORD / CHHOTO_API_KEY       — Argon2 hashes, for compose.yaml"
echo "  ADMIN_PASSWORD_PLAINTEXT / API_KEY_PLAINTEXT — what you actually use to log in"
echo "Nothing printed here — values went straight from openssl/argon2 into Pass."
