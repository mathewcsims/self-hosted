#!/bin/sh
# Like pass-deploy-remote.sh, but for kopia-server specifically — it needs
# secrets merged from TWO Pass items ("Kopia" and "Backblaze B2"), not the
# one-item-per-app convention every other deploy script assumes.
#
# Usage:
#   ./scripts/pass-deploy-kopia-server.sh <ssh-host> <remote-path>
#
# Example:
#   ./scripts/pass-deploy-kopia-server.sh mathew@babel '~/kopia-server'
set -eu

SSH_HOST="${1:?Usage: $0 <ssh-host> <remote-path>}"
REMOTE_PATH="${2:?Usage: $0 <ssh-host> <remote-path>}"

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
        exit 1
    fi
fi

echo "Fetching secrets for kopia-server (\"Kopia\" + \"Backblaze B2\") from Proton Pass..."

fetch_exports() {
    PROTON_PASS_AGENT_REASON="Fetching secrets to deploy kopia-server on $SSH_HOST" \
        pass-cli item view --vault-name "Self-Hosted Secrets" --item-title "$1" --output json \
        | python3 -c '
import json, sys, shlex

d = json.load(sys.stdin)
sections = d["item"]["content"]["content"]["Custom"]["sections"]
for section in sections:
    for f in section["section_fields"]:
        name = f["name"]
        value = list(f["content"].values())[0]
        print(f"export {name}={shlex.quote(value)}")
'
}

EXPORTS="$(fetch_exports "Kopia")
$(fetch_exports "Backblaze B2")"

echo "Deploying on $SSH_HOST:$REMOTE_PATH..."

{
    echo "$EXPORTS"
    echo "cd $(printf '%q' "$REMOTE_PATH")"
    echo "docker compose up -d"
} | ssh "$SSH_HOST" 'bash -s'
