#!/bin/sh
# Like pass-deploy.sh, but for apps that run on the Pi (nimbus,
# speedtest-tracker), not the Mac. Fetches secrets from Proton Pass here
# (where pass-cli/the agent session live), then pipes the export statements
# and the remote `docker compose up -d` invocation over SSH via stdin — the
# secret values never appear in the SSH command line/argv, only inside the
# piped script body, same reasoning as never passing secrets as Bash
# command-line arguments locally.
#
# Auto-authenticates using SECRET_ACCESS_TOKEN from the repo-root .env (a
# durable, read-only, vault-scoped Personal Access Token) if no pass-cli
# session is already active — see SETUP.md.
#
# Usage:
#   ./scripts/pass-deploy-remote.sh <app-dir> <ssh-host> <remote-path> [item-title]
#
# Example:
#   ./scripts/pass-deploy-remote.sh nimbus mathew@babel ~/nimbus

set -eu

APP_DIR="${1:?Usage: $0 <app-dir> <ssh-host> <remote-path> [item-title]}"
SSH_HOST="${2:?Usage: $0 <app-dir> <ssh-host> <remote-path> [item-title]}"
REMOTE_PATH="${3:?Usage: $0 <app-dir> <ssh-host> <remote-path> [item-title]}"
ITEM_TITLE="${4:-$(echo "$APP_DIR" | python3 -c 'import sys; print("".join(w.capitalize() for w in sys.stdin.read().strip().split("-")))')}"

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

EXPORTS=$(PROTON_PASS_AGENT_REASON="Fetching secrets to deploy $APP_DIR on $SSH_HOST" \
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

echo "Deploying on $SSH_HOST:$REMOTE_PATH..."

{
    echo "$EXPORTS"
    echo "cd $(printf '%q' "$REMOTE_PATH")"
    echo "docker compose up -d"
} | ssh "$SSH_HOST" 'bash -s'
