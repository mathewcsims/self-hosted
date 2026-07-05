#!/bin/sh
# Deploy an app with its secrets fetched live from Proton Pass — nothing is
# ever written to a .env file on disk. Reads the app's "one item per app"
# custom item from the Agent Secrets vault, exports each field as an
# environment variable for this shell only, then runs `podman compose up
# -d` in that process — so podman-compose's own ${VAR} interpolation picks
# the values up directly, matching every app's compose.yaml except
# karakeep (which needed converting from `env_file: .env` to explicit
# ${VAR} references, since env_file requires an actual file to read).
#
# Requires an active pass-cli agent session (see SETUP.md) — the
# Personal Access Token expires after 24h, so this will periodically need
# re-login with a fresh PAT; there's no way to auto-refresh that without
# the token itself, which only you can generate.
#
# Usage:
#   ./scripts/pass-deploy.sh <app-dir> [item-title]
#
# Example:
#   ./scripts/pass-deploy.sh vikunja

set -eu

APP_DIR="${1:?Usage: $0 <app-dir> [item-title]}"
ITEM_TITLE="${2:-$(echo "$APP_DIR" | python3 -c 'import sys; print("".join(w.capitalize() for w in sys.stdin.read().strip().split("-")))')}"

export PROTON_PASS_SESSION_DIR="${PROTON_PASS_SESSION_DIR:-/tmp/pass-agent-selfhosted}"

if ! pass-cli info >/dev/null 2>&1; then
    echo "pass-cli agent session is not active or has expired (PATs last 24h)." >&2
    echo "Ask for a fresh Personal Access Token, then run:" >&2
    echo "  export PROTON_PASS_SESSION_DIR=\"$PROTON_PASS_SESSION_DIR\"" >&2
    echo "  PROTON_PASS_PERSONAL_ACCESS_TOKEN=\"...\" pass-cli login" >&2
    exit 1
fi

echo "Fetching secrets for \"$ITEM_TITLE\" from Proton Pass..."

EXPORTS=$(PROTON_PASS_AGENT_REASON="Fetching secrets to deploy $APP_DIR" \
    pass-cli item view --vault-name "Agent Secrets" --item-title "$ITEM_TITLE" --output json \
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
