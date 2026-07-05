#!/bin/sh
# Like pass-deploy.sh, but for apps that run on the Pi (nimbus,
# speedtest-tracker), not the Mac. Fetches secrets from Proton Pass here
# (where pass-cli/the agent session live), then pipes the export statements
# and the remote `docker compose up -d` invocation over SSH via stdin — the
# secret values never appear in the SSH command line/argv, only inside the
# piped script body, same reasoning as never passing secrets as Bash
# command-line arguments locally.
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

export PROTON_PASS_SESSION_DIR="${PROTON_PASS_SESSION_DIR:-/tmp/pass-agent-selfhosted}"

if ! pass-cli info >/dev/null 2>&1; then
    echo "pass-cli agent session is not active or has expired (PATs last 24h)." >&2
    echo "Ask for a fresh Personal Access Token, then run:" >&2
    echo "  export PROTON_PASS_SESSION_DIR=\"$PROTON_PASS_SESSION_DIR\"" >&2
    echo "  PROTON_PASS_PERSONAL_ACCESS_TOKEN=\"...\" pass-cli login" >&2
    exit 1
fi

echo "Fetching secrets for \"$ITEM_TITLE\" from Proton Pass..."

EXPORTS=$(PROTON_PASS_AGENT_REASON="Fetching secrets to deploy $APP_DIR on $SSH_HOST" \
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

echo "Deploying on $SSH_HOST:$REMOTE_PATH..."

{
    echo "$EXPORTS"
    echo "cd $(printf '%q' "$REMOTE_PATH")"
    echo "docker compose up -d"
} | ssh "$SSH_HOST" 'bash -s'
