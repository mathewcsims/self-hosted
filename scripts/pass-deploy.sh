#!/bin/sh
# Deploy an app with its secrets fetched live from Proton Pass — nothing is
# ever written to a .env file on disk. Reads the app's "one item per app"
# custom item from the Self-Hosted Secrets vault, exports each field as an
# environment variable for this shell only, then runs `podman compose up
# -d` in that process — so podman-compose's own ${VAR} interpolation picks
# the values up directly, matching every app's compose.yaml except
# karakeep (which needed converting from `env_file: .env` to explicit
# ${VAR} references, since env_file requires an actual file to read).
#
# Auto-authenticates using SECRET_ACCESS_TOKEN from the repo-root .env (a
# durable, read-only, vault-scoped Personal Access Token) if no pass-cli
# session is already active — see SETUP.md.
#
# Usage:
#   ./scripts/pass-deploy.sh <app-dir> [item-title]
#
# Example:
#   ./scripts/pass-deploy.sh vikunja

set -eu

APP_DIR="${1:?Usage: $0 <app-dir> [item-title]}"
ITEM_TITLE="${2:-$(echo "$APP_DIR" | python3 -c 'import sys; print("".join(w.capitalize() for w in sys.stdin.read().strip().split("-")))')}"

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

echo "Fetching secrets for \"$ITEM_TITLE\" from Proton Pass..."

EXPORTS=$(PROTON_PASS_AGENT_REASON="Fetching secrets to deploy $APP_DIR" \
    pass-cli item view --vault-name "Self-Hosted Secrets" --item-title "$ITEM_TITLE" --output json \
    | python3 -c '
import json, sys, shlex

d = json.load(sys.stdin)
sections = d["item"]["content"]["content"]["Custom"]["sections"]
for section in sections:
    for f in section["section_fields"]:
        name = f["name"]
        value = list(f["content"].values())[0]
        print(f"export {name}={shlex.quote(value)}")
')

eval "$EXPORTS"

cd "$APP_DIR"
podman compose up -d
