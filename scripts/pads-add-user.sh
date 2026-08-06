#!/bin/sh
# Adds (or updates) a non-admin account on the Etherpad instance at
# pads.mathewcsims.uk — for friends and family on the tailnet.
#
# ep_hash_auth reads its filesystem user store at AUTHENTICATION time, so this
# takes effect immediately: no redeploy, no restart, no settings.json edit.
# That is why family accounts live here rather than in the `users` block, which
# is reserved for the admin account (settings.json is the only place is_admin
# can be set for a named user).
#
# The account created here is deliberately NOT an admin: settings.json sets
# `hash_adm: false`, so a file-based user is non-admin unless it also has a
# `.adm` file. Do not add one without meaning to — this is a shared space and
# an admin can delete pads and reach /admin.
#
# ── The bcrypt prefix gotcha ──────────────────────────────────────────────
# htpasswd emits `$2y$`, which node's bcrypt does not understand: it returns
# false for every password with no error and no log line, so the account just
# never works. `$2y$` and `$2a$` are the same algorithm, so the prefix is
# rewritten below. Same reasoning as scripts/pass-create-pads-secrets.sh.
#
# Usage:
#   ./scripts/pads-add-user.sh <username> ["Display Name"]
#
# Prints the generated password once. Put it in Proton Pass or give it to the
# person directly — it is not stored anywhere by this script.
set -eu

USERNAME=${1:-}
DISPLAYNAME=${2:-}

[ -n "$USERNAME" ] || { echo "usage: $0 <username> [\"Display Name\"]" >&2; exit 1; }
# Keep usernames to a safe set — they become a directory name.
echo "$USERNAME" | grep -qE '^[a-zA-Z0-9._-]+$' || {
    echo "username must match [a-zA-Z0-9._-]+ (it becomes a directory name)" >&2; exit 1; }
command -v htpasswd >/dev/null || { echo "htpasswd not found" >&2; exit 1; }

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
USER_DIR="$REPO_ROOT/pads/users/$USERNAME"

PASSWORD=$(python3 -c 'import secrets,string; print("".join(secrets.choice(string.ascii_letters+string.digits) for _ in range(24)))')
HASH=$(htpasswd -bnBC 12 x "$PASSWORD" | cut -d: -f2 | sed 's/^\$2y\$/\$2a\$/')

case "$HASH" in
    '$2a$'*) ;;
    *) echo "unexpected hash format, aborting" >&2; exit 1 ;;
esac

mkdir -p "$USER_DIR"
# Hash file is readable only by the owner; the directory is bind-mounted into
# the container, which runs as a user mapped to you under podman-machine.
umask 077
printf '%s' "$HASH" > "$USER_DIR/.hash"
[ -n "$DISPLAYNAME" ] && printf '%s' "$DISPLAYNAME" > "$USER_DIR/.displayname"

echo "Created $USERNAME (non-admin) at pads/users/$USERNAME"
echo
echo "  username: $USERNAME"
echo "  password: $PASSWORD"
echo
echo "Shown once and not stored — record it now."
echo "Effective immediately; no restart needed."
echo
echo "Note: pads/users/ is gitignored and exists only on this Mac. Kopia backs"
echo "it up (see kopia-mac/backup.sh) — that is the only copy."
