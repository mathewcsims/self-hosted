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

# Resolve the title to exactly one ACTIVE item id, then fetch by id — do NOT
# fetch by title directly.
#
# WHY (learned the hard way, 2026-08-07): `item view --item-title` matches
# TRASHED items too, and when two items share a title it silently returns the
# older one. That combination is nastier than it sounds:
#
#   * scripts/pass-import-file.sh runs `item create`, not an update, so
#     re-importing an existing whole-file secret produces a SECOND item with
#     the same title rather than updating the first;
#   * the render then keeps returning the stale original with no error;
#   * moving the stale one to the trash does NOT help — a trashed item is
#     still readable and still wins title resolution (verified, including
#     after a fresh login). Only permanent deletion removes it from the
#     match set;
#   * and for copyparty the failure is not a silent downgrade. An account
#     present in copyparty.conf but missing from the rendered accounts.conf
#     makes it exit 1 with "CRIT: you must -a the following users" — a hard
#     outage of the file server, on the next deploy, from a vault tidy-up.
#
# Resolving through the ACTIVE list makes the ambiguity loud and immediate
# instead. Fails closed: zero matches or more than one, and nothing is
# written.
ITEM_LIST=$(PROTON_PASS_AGENT_REASON="Resolving $ITEM_TITLE for deploy" \
    pass-cli item list --vault-name "Self-Hosted Secrets" 2>/dev/null)

ITEM_IDS=$(printf '%s\n' "$ITEM_LIST" \
    | grep -F "]: $ITEM_TITLE (state=Active)" \
    | sed -E 's/^- \[([^]]*)\].*/\1/')

ID_COUNT=$(printf '%s' "$ITEM_IDS" | grep -c . || true)

if [ "$ID_COUNT" -eq 0 ]; then
    echo "No ACTIVE item titled \"$ITEM_TITLE\" in vault \"Self-Hosted Secrets\"." >&2
    echo "(A trashed item of that name does not count — restore it or create one.)" >&2
    exit 1
fi
if [ "$ID_COUNT" -gt 1 ]; then
    echo "Ambiguous: $ID_COUNT ACTIVE items titled \"$ITEM_TITLE\"." >&2
    echo "Refusing to guess — permanently delete the stale one(s) in the Proton Pass UI." >&2
    echo "Note that pass-import-file.sh CREATES items; it does not update them." >&2
    exit 1
fi

PROTON_PASS_AGENT_REASON="Rendering $ITEM_TITLE/$FIELD to $OUTPUT for deploy" \
    pass-cli item view --vault-name "Self-Hosted Secrets" --item-id "$ITEM_IDS" --field "$FIELD" > "$OUTPUT"
chmod 600 "$OUTPUT"

echo "Done."
