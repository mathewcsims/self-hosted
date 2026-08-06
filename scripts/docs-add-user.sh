#!/bin/sh
# Creates an account on the HedgeDoc instance at docs.mathewcsims.uk.
#
# Self-registration is deliberately disabled (CMD_ALLOW_EMAIL_REGISTER=false in
# docs/compose.yaml), so this is the only way accounts come into existence —
# which is what keeps the instance from growing accounts you didn't intend.
# It wraps HedgeDoc's own `bin/manage_users`; nothing here is bespoke.
#
# ── What the new account can and cannot see ──────────────────────────────
# Notes default to PRIVATE (CMD_DEFAULT_PERMISSION=private), so a new account
# sees nothing of yours: verified that a private note returns 403 to a
# different signed-in account and does not appear in its History. A note only
# becomes visible to other accounts when you deliberately change its
# permission to Editable, Limited, Locked or Protected from the note itself.
#
# Note the limit of HedgeDoc's model: permissions are owner / all-signed-in /
# guests. There is no per-person sharing — you cannot share one note with just
# one family member. Sharing a note shares it with everyone who has an account.
#
# Usage:
#   ./scripts/docs-add-user.sh <email>
#   ./scripts/docs-add-user.sh --delete <email>
#
# Prints the generated password ONCE. It is not stored anywhere by this
# script — put it into Proton Pass or hand it over directly.
set -eu

CONTAINER=docs

usage() { echo "usage: $0 [--delete] <email>" >&2; exit 1; }

DELETE=0
if [ "${1:-}" = "--delete" ]; then DELETE=1; shift; fi
EMAIL=${1:-}
[ -n "$EMAIL" ] || usage
# Keep it to something that is plausibly an email and safe to pass onward.
echo "$EMAIL" | grep -qE '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' || {
    echo "'$EMAIL' does not look like an email address" >&2; exit 1; }

podman ps --format '{{.Names}}' | grep -qx "$CONTAINER" || {
    echo "container '$CONTAINER' is not running — deploy first with ./scripts/pass-deploy.sh docs" >&2
    exit 1; }

if [ "$DELETE" = 1 ]; then
    podman exec "$CONTAINER" bin/manage_users --del "$EMAIL"
    echo "Deleted $EMAIL."
    echo "Their notes are NOT deleted with the account — reassign or remove them separately."
    exit 0
fi

PASSWORD=$(python3 -c 'import secrets,string; print("".join(secrets.choice(string.ascii_letters+string.digits) for _ in range(24)))')

# --pass keeps manage_users from prompting interactively. The password does
# appear in this container exec's argv, which is acceptable here because the
# alternative (an interactive prompt) can't be scripted, and it is a value you
# are about to read on screen anyway. It is not written to any file.
podman exec "$CONTAINER" bin/manage_users --pass "$PASSWORD" --add "$EMAIL" >/dev/null

echo "Created HedgeDoc account:"
echo
echo "  email:    $EMAIL"
echo "  password: $PASSWORD"
echo
echo "Shown once and not stored — record it now."
echo "They sign in at https://docs.mathewcsims.uk (LAN or tailnet only)."
