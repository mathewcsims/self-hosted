#!/bin/sh
# One-time setup: generates Tududi's session secret and admin password and
# stores them as a new Proton Pass item, "Tududi", for tududi/ to read at
# deploy time via scripts/pass-deploy-remote.sh.
#
# The item title must be exactly "Tududi" — pass-deploy-remote.sh derives
# the item title from the app-dir name (kebab -> PascalCase), so `tududi`
# resolves to `Tududi`. Renaming either side breaks the lookup silently.
#
# Deliberately NOT run by the agent — pass-cli agent PATs are read-only by
# design, so item creation has to happen under your own personal pass-cli
# session, same as every other pass-create-*-secrets.sh here.
#
# Both secrets are generated INSIDE this script and go straight into Pass —
# never typed, never printed, never touching argv or a file on disk.
#
# TUDUDI_SESSION_SECRET is 64 random bytes hex-encoded, which is what
# upstream's own docs generate (`openssl rand -hex 64`). It signs session
# cookies, so rotating it later logs everyone out but is otherwise safe —
# unlike the Immich DB password, nothing is baked into a data directory.
#
# TUDUDI_USER_PASSWORD creates the FIRST user at first boot, and Tududi
# makes the first user an admin automatically. Since self-registration is
# disabled by default, this is the only account that will exist. Changing
# it in Pass later will NOT change the stored password — the account
# already exists by then, so rotate it in the app's own UI instead.
#
# Alphanumeric only (/+= stripped): this password gets typed into a login
# form by hand on a phone often enough that punctuation is a real cost, and
# 32 alphanumeric characters is ample.
#
# Usage:
#   ./scripts/pass-create-tududi-secrets.sh
set -eu

SESSION_SECRET=$(openssl rand -hex 64)
USER_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-32)
# The estate's own domain, NOT a personal gmail address — every other app
# here uses an @mathewcsims.uk identity (Nimbus, Vikunja, Kopia's web UI).
# Set wrongly on the first run of this script, which created an admin
# account under the wrong address and needed the database recreating to
# fix, because the account is only ever created at FIRST BOOT.
USER_EMAIL="mat@mathewcsims.uk"

printf '{"title":"Tududi","note":"self-hosted repo secrets — see ~/self-hosted/tududi/ (runs on slartibartfast)","sections":[{"section_name":"Secrets","fields":[{"field_name":"TUDUDI_SESSION_SECRET","field_type":"hidden","value":"%s"},{"field_name":"TUDUDI_USER_EMAIL","field_type":"text","value":"%s"},{"field_name":"TUDUDI_USER_PASSWORD","field_type":"hidden","value":"%s"}]}]}' \
    "$SESSION_SECRET" \
    "$USER_EMAIL" \
    "$USER_PASSWORD" \
    | pass-cli item create custom --vault-name "Self-Hosted Secrets" --from-template -

echo
echo "Done. \"Tududi\" item created in Proton Pass with:"
echo "  TUDUDI_SESSION_SECRET  (64 random bytes, hex)"
echo "  TUDUDI_USER_EMAIL      ($USER_EMAIL)"
echo "  TUDUDI_USER_PASSWORD   (32 alphanumeric characters)"
echo
echo "Nothing was printed here — the values went straight from openssl into"
echo "Pass. Read the password out of Pass when you first log in."
