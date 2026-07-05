#!/bin/sh
# Fetches a single whole-file-secret field from Proton Pass and writes it to
# disk at the given path — for apps that need an actual config file mounted
# into the container (e.g. copyparty's accounts.conf), which can't use the
# zero-disk-write env-export approach pass-deploy.sh uses for everything
# else. The file is regenerated fresh from Pass on every run, so Pass stays
# the source of truth even though a local copy has to exist for the mount.
#
# Usage:
#   ./scripts/pass-render-file.sh <item-title> <field-name> <output-path>
#
# Example:
#   ./scripts/pass-render-file.sh Copyparty ACCOUNTS_CONF copyparty/cfg/accounts.conf

set -eu

ITEM_TITLE="${1:?Usage: $0 <item-title> <field-name> <output-path>}"
FIELD="${2:?Usage: $0 <item-title> <field-name> <output-path>}"
OUTPUT="${3:?Usage: $0 <item-title> <field-name> <output-path>}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

export PROTON_PASS_SESSION_DIR="${PROTON_PASS_SESSION_DIR:-/tmp/pass-agent-selfhosted}"
mkdir -p "$PROTON_PASS_SESSION_DIR"

if ! pass-cli info >/dev/null 2>&1; then
    if [ ! -f "$REPO_ROOT/.env" ]; then
        echo "No active pass-cli session, and no $REPO_ROOT/.env to auto-login with." >&2
        exit 1
    fi
    echo "No active pass-cli session — logging in with SECRET_ACCESS_TOKEN from .env..."
    set -a
    . "$REPO_ROOT/.env"
    set +a
    export PROTON_PASS_PERSONAL_ACCESS_TOKEN="$SECRET_ACCESS_TOKEN"
    pass-cli login >/dev/null
    unset PROTON_PASS_PERSONAL_ACCESS_TOKEN SECRET_ACCESS_TOKEN
    if ! pass-cli info >/dev/null 2>&1; then
        echo "Login failed — SECRET_ACCESS_TOKEN in .env may be revoked or expired." >&2
        echo "Update self-hosted/.env with a fresh token and retry." >&2
        exit 1
    fi
fi

echo "Rendering \"$ITEM_TITLE\" field \"$FIELD\" to $OUTPUT..."

PROTON_PASS_AGENT_REASON="Rendering $ITEM_TITLE/$FIELD to $OUTPUT for deploy" \
    pass-cli item view --vault-name "Self-Hosted Secrets" --item-title "$ITEM_TITLE" --field "$FIELD" > "$OUTPUT"
chmod 600 "$OUTPUT"

echo "Done."
