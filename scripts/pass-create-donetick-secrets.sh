#!/bin/sh
# One-time setup: generates Donetick's JWT signing secret and its single
# account's password, and stores them as a new Proton Pass item, "Donetick",
# for donetick/ to read at deploy time via scripts/pass-deploy-remote.sh.
#
# The item title must be exactly "Donetick" — pass-deploy-remote.sh derives
# the item title from the app-dir name (kebab -> PascalCase), so `donetick`
# resolves to `Donetick`. Renaming either side breaks the lookup silently.
#
# Deliberately NOT run by the agent — pass-cli agent PATs are read-only by
# design, so item creation has to happen under your own personal pass-cli
# session, same as every other pass-create-*-secrets.sh here.
#
# Both values are generated INSIDE this script and go straight into Pass —
# never typed, never printed, never touching argv or a file on disk.
#
# ── WHY THE JWT SECRET MATTERS MORE THAN USUAL HERE ───────────────────────
# Donetick's one published advisory is CVE-2025-47945 (CVSS 9.1, critical):
# the shipped config template contained a PREDICTABLE DEFAULT JWT signing
# secret, and anyone who knew it could forge a token for any account. Fixed
# upstream in v0.1.44 and we run far newer, but the lesson is that this
# value is the whole authentication system. 64 random bytes, hex-encoded.
#
# Rotating it later is safe and simply logs you out — unlike a database
# password, nothing is baked into stored data.
#
# DONETICK_PASSWORD creates the single account via
# scripts/bootstrap-donetick-account.sh. Alphanumeric only (/+= stripped):
# it gets typed into a login form on a phone, where punctuation is a real
# cost, and 32 alphanumeric characters is ample.
#
# Usage:
#   ./scripts/pass-create-donetick-secrets.sh
set -eu

JWT_SECRET=$(openssl rand -hex 64)
PASSWORD=$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-32)
# MINIMUM 4 CHARACTERS — Donetick binds the signup request with
# `min=4,max=20` on username (internal/user/handler.go). "mat", the handle
# used elsewhere in this estate, is three characters and is rejected with a
# bare 400 {"error":"Invalid request"} that names no field. Learned the hard
# way on 2026-08-01.
USERNAME="mathew"
EMAIL="mat@mathewcsims.uk"

printf '{"title":"Donetick","note":"self-hosted repo secrets — see ~/self-hosted/donetick/ (runs on slartibartfast)","sections":[{"section_name":"Secrets","fields":[{"field_name":"DT_JWT_SECRET","field_type":"hidden","value":"%s"},{"field_name":"DONETICK_USERNAME","field_type":"text","value":"%s"},{"field_name":"DONETICK_EMAIL","field_type":"text","value":"%s"},{"field_name":"DONETICK_PASSWORD","field_type":"hidden","value":"%s"}]}]}' \
    "$JWT_SECRET" \
    "$USERNAME" \
    "$EMAIL" \
    "$PASSWORD" \
    | pass-cli item create custom --vault-name "Self-Hosted Secrets" --from-template -

echo
echo "Done. \"Donetick\" item created in Proton Pass with:"
echo "  DT_JWT_SECRET      (64 random bytes, hex)"
echo "  DONETICK_USERNAME  ($USERNAME)"
echo "  DONETICK_EMAIL     ($EMAIL)"
echo "  DONETICK_PASSWORD  (32 alphanumeric characters)"
echo
echo "Nothing was printed here — the values went straight from openssl into"
echo "Pass. Read the password out of Pass when you first log in."
